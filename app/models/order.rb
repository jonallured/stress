class Order < ApplicationRecord
  include OrderHelper
  has_paper_trail versions: { class_name: 'PaperTrail::OrderVersion' }

  SUPPORTED_CURRENCIES = %w[USD GBP EUR].freeze

  DEFAULT_EXPIRATION_REMINDER = 5.hours

  MODES = [
    BUY = 'buy'.freeze,
    OFFER = 'offer'.freeze
  ].freeze

  PARTICIPANTS = [
    BUYER = 'buyer'.freeze,
    SELLER = 'seller'.freeze
  ].freeze

  PAYMENT_METHODS = [
    CREDIT_CARD = 'credit card'.freeze,
    WIRE_TRANSFER = 'wire transfer'.freeze,
    OTHER = 'other'.freeze
  ].freeze

  # For more docs about states go to:
  # https://www.notion.so/artsy/37c311363ef046c3aa546047e60cc58a?v=de68d5bbc30748f88b0d92a059bc0ba8
  STATES = [
    PENDING = 'pending'.freeze,
    # Buyer starts checkout flow but never submits
    ABANDONED = 'abandoned'.freeze,
    # Check-out complete; payment authorized.
    # Buyer credit card has been authorized and hold has been placed.
    # At this point, availability must be confirmed manually.
    # Holds expire 7 days after being placed.
    SUBMITTED = 'submitted'.freeze,
    # Availability has been manually confirmed and hold has been "captured" (debited).
    APPROVED = 'approved'.freeze,
    # Items have been deemed unavailable and hold is voided.
    CANCELED = 'canceled'.freeze,
    # Order is completely fulfilled by the seller
    FULFILLED = 'fulfilled'.freeze,
    # Order was refunded after approval/fulfillment
    REFUNDED = 'refunded'.freeze
  ].freeze

  REASONS = {
    CANCELED => {
      seller_lapsed: 'seller_lapsed'.freeze,
      seller_rejected_offer_too_low: 'seller_rejected_offer_too_low'.freeze,
      seller_rejected_shipping_unavailable: 'seller_rejected_shipping_unavailable'.freeze,
      seller_rejected_artwork_unavailable: 'seller_rejected_artwork_unavailable'.freeze,
      seller_rejected_other: 'seller_rejected_other'.freeze,
      seller_rejected: 'seller_rejected'.freeze,
      buyer_rejected: 'buyer_rejected'.freeze,
      buyer_lapsed: 'buyer_lapsed'.freeze,
      admin_canceled: 'admin_canceled'.freeze
    }
  }.freeze

  STATE_EXPIRATIONS = {
    'pending' => 2.days,
    'submitted' => 3.days,
    'approved' => 7.days
  }.freeze

  FULFILLMENT_TYPES = [
    PICKUP = 'pickup'.freeze,
    SHIP = 'ship'.freeze,
    SHIP_ARTA = 'ship_arta'.freeze
  ].freeze

  ACTIONS = %i[abandon revert submit approve reject fulfill seller_lapse buyer_lapse refund].freeze
  ACTION_REASONS = {
    seller_lapse: REASONS[CANCELED][:seller_lapsed],
    buyer_lapse: REASONS[CANCELED][:buyer_lapsed],
    reject: REASONS[CANCELED][:seller_rejected_other]
  }.freeze

  PARTY_TYPES = [
    USER = 'user'.freeze,
    PARTNER = 'partner'.freeze
  ].freeze

  REMINDER_EVENT_VERB = {
    pending_approval: 'pending_approval'.freeze,
    pending_fulfillment: 'pending_fulfillment'.freeze
  }.freeze

  AUCTION_SELLER_TYPE = 'auction'.freeze

  has_many :line_items, dependent: :destroy, class_name: 'LineItem'
  has_many :transactions, dependent: :destroy
  has_many :state_histories, dependent: :destroy
  has_many :admin_notes, dependent: :destroy
  has_many :fraud_reviews, dependent: :destroy
  has_many :offers, dependent: :destroy
  belongs_to :last_offer, class_name: 'Offer', optional: true

  before_validation { self.currency_code = currency_code.upcase if currency_code.present? }

  validates :state, presence: true, inclusion: STATES
  validate :state_reason_inclusion
  validates :currency_code, inclusion: SUPPORTED_CURRENCIES
  validates :payment_method, presence: true, inclusion: PAYMENT_METHODS

  after_create :update_code
  after_create :create_state_history
  before_save :update_state_timestamps, if: :state_changed?
  before_save :set_currency_code

  scope :pending, -> { where(state: PENDING) }
  scope :active, -> { where(state: [Order::APPROVED, Order::SUBMITTED]) }
  scope :approved, -> { where(state: APPROVED) }
  scope :by_last_admin_note, ->(note_types) { where('(SELECT note_type FROM admin_notes WHERE order_id = orders.id ORDER BY created_at DESC limit 1) in (?)', note_types) }
  scope :is_inquiry_order, -> { where.not(impulse_conversation_id: nil) }

  ACTIONS.each do |action|
    define_method "#{action}!" do |state_reason = nil, &block|
      with_lock do
        state_machine.trigger!(action)
        self.state_reason = state_reason || ACTION_REASONS[action]
        save!
        create_state_history
        block.call if block.present?
      end
    rescue MicroMachine::InvalidState
      raise Errors::ValidationError.new(:invalid_state, state: state)
    end
  end

  def competing_orders
    artwork_ids = line_items.select(:artwork_id)
    edition_set_ids = line_items.select(:edition_set_id)

    Order
      .joins(:line_items)
      .where.not(id: id)
      .where(state: SUBMITTED)
      .where('(line_items.artwork_id IN (?) OR line_items.edition_set_id IN (?))', artwork_ids, edition_set_ids)
      .order(created_at: :asc)
  end

  def offerable?
    [PENDING, SUBMITTED].include? state
  end

  def shipping_info?
    fulfillment_type == PICKUP ||
      (Order.shipping_requested?(fulfillment_type) && complete_shipping_details?)
  end

  def payment_info?
    credit_card_id.present?
  end

  def auction_seller?
    seller_type == AUCTION_SELLER_TYPE
  end

  def inquiry_order?
    impulse_conversation_id.present?
  end

  def require_inventory?
    !inquiry_order?
  end

  def to_s
    "Order #{id}"
  end

  def last_submitted_at
    get_last_state_timestamp(Order::SUBMITTED)
  end

  def last_approved_at
    get_last_state_timestamp(Order::APPROVED)
  end

  def order_history
    OrderHistoryService.events_for(order_id: id)
  end

  def self.shipping_requested?(fulfillment_type)
    [Order::SHIP, Order::SHIP_ARTA].include?(fulfillment_type)
  end

  def shipping_address
    return unless Order.shipping_requested?(fulfillment_type)

    Address.new(
      country: shipping_country,
      postal_code: shipping_postal_code,
      region: shipping_region,
      city: shipping_city,
      address_line1: shipping_address_line1,
      address_line2: shipping_address_line2
    )
  end

  def last_admin_note
    admin_notes.order(:created_at).last
  end

  def total_list_price_cents
    line_items.map(&:total_list_price_cents).sum
  end

  def update_total_list_price_cents(price)
    raise Errors::ValidationError, :more_than_one_line_item unless line_items.count == 1 && line_items.first.quantity == 1

    line_items.first.update!(list_price_cents: price)
  end

  def can_commit?
    shipping_info? && payment_info?
  end

  def awaiting_response_from
    return unless mode == Order::OFFER && state == Order::SUBMITTED

    last_offer&.awaiting_response_from
  end

  def state_expiration_reminder_time(time_to_expiration = DEFAULT_EXPIRATION_REMINDER)
    state_expires_at - time_to_expiration
  end

  def last_transaction_failed?
    return false if transactions.blank?

    last_transaction = transactions.order(created_at: :desc).first
    last_transaction.failed? || last_transaction.requires_action?
  end

  private

  def state_reason_inclusion
    errors.add(:state_reason, "Current state not expecting reason: #{state}") if state_reason.present? && !REASONS.key?(state)
    errors.add(:state_reason, 'Invalid state reason') if REASONS[state] && !REASONS[state].value?(state_reason)
  end

  def update_code(attempts = 10)
    while attempts.positive?
      code = format('%09d', SecureRandom.rand(999999999))
      unless Order.where(code: code).exists?
        update!(code: code)
        break
      end
      attempts -= 1
    end
    raise Errors::ValidationError, :failed_order_code_generation if attempts.zero?
  end

  def update_state_timestamps
    self.state_updated_at = Time.now.utc
    self.state_expires_at = STATE_EXPIRATIONS.key?(state) ? state_updated_at + STATE_EXPIRATIONS[state] : nil
  end

  def get_last_state_timestamp(state)
    state_histories.where(state: state).order(:updated_at).last&.updated_at
  end

  def create_state_history
    state_histories.create!(state: state, reason: state_reason, updated_at: state_updated_at)
  end

  def set_currency_code
    self.currency_code ||= 'USD'
  end

  def state_machine
    @state_machine ||= build_machine
  end

  def build_machine
    machine = MicroMachine.new(state)
    machine.when(:abandon, PENDING => ABANDONED)
    machine.when(:submit, PENDING => SUBMITTED)
    machine.when(:revert, APPROVED => SUBMITTED, SUBMITTED => PENDING)
    machine.when(:approve, SUBMITTED => APPROVED)
    machine.when(:reject, SUBMITTED => CANCELED)
    machine.when(:seller_lapse, SUBMITTED => CANCELED)
    machine.when(:buyer_lapse, SUBMITTED => CANCELED)
    machine.when(:cancel, SUBMITTED => CANCELED)
    machine.when(:fulfill, APPROVED => FULFILLED, CANCELED => FULFILLED, ABANDONED => FULFILLED)
    machine.when(:refund, APPROVED => REFUNDED, FULFILLED => REFUNDED)
    machine.on(:any) do
      self.state = machine.state
    end
    machine
  end

  def complete_shipping_details?
    [shipping_name, shipping_address_line1, shipping_city, shipping_country, buyer_phone_number].all?(&:present?)
  end

  ransacker :has_offer_note do
    Arel.sql('(select exists (select 1 from offers where offers.order_id = orders.id and offers.note <> \'\' and offers.submitted_at is not null))')
  end
end
