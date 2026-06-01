{{ config(materialized='view') }}

SELECT
    refund_id
    , order_id
    , tender_type
    , amount_in_cents / 100.0 AS refund_amount
    , CAST(processed_at AS timestamp) AS refunded_at
FROM {{ ref('base_refunds_stripe') }}
