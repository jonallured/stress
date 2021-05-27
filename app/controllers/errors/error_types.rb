module Errors
  ERROR_TYPES = {
    validation: %i[
      cannot_accept_offer
      cannot_counter
      cannot_offer
      cannot_reject_offer
      cannot_reject_own_offer
      cant_submit
      credit_card_deactivated
      credit_card_missing_customer
      credit_card_missing_external_id
      credit_card_not_found
      failed_order_code_generation
      invalid_amount_cents
      invalid_artwork_address
      invalid_commission_rate
      invalid_credit_card
      invalid_offer
      invalid_order
      invalid_seller_address
      invalid_state
      invalid_states_params
      missing_artwork_location
      missing_commission_rate
      missing_country
      missing_currency
      missing_domestic_shipping_fee
      missing_edition_set_id
      missing_merchant_account
      missing_params
      missing_partner_location
      missing_postal_code
      missing_price
      missing_selected_shipping_quote_id
      missing_shipping_quote
      missing_region
      missing_required_info
      missing_required_param
      missing_phone_number
      more_than_one_line_item
      no_taxable_addresses
      not_acquireable
      not_found
      not_last_offer
      not_offerable
      offer_not_from_buyer
      offer_total_not_defined
      order_not_submitted
      uncommittable_action
      unknown_artwork
      unknown_edition_set
      unknown_participant_type
      unknown_partner
      unpublished_artwork
      unsupported_payment_method
      unsupported_shipping_location
      wrong_fulfillment_type
    ],
    processing: %i[
      artwork_version_mismatch
      cancel_payment_failed
      cannot_capture
      capture_failed
      charge_authorization_failed
      insufficient_inventory
      payment_method_confirmation_failed
      payment_requires_action
      received_partial_refund
      refund_failed
      tax_calculator_failure
      tax_recording_failure
      tax_refund_failure
      undeduct_inventory_failure
      unknown_event_charge
    ],
    internal: %i[
      generic
      gravity
    ]
  }.freeze
end
