{{ config(materialized='view') }}

-- Stripe tender-split sidecar. One row per (refund event, tender_type).
-- Joins back to stg_refunds on (order_id, refunded_at_minute) — see §3.3 of the
-- refunds design doc for why this is the chosen join key.

SELECT
    refund_id AS source_refund_id
    , order_id
    , tender_type
    , amount_in_cents / 100.0 AS tender_amount
    , CAST(processed_at AS timestamp) AS refunded_at
    , DATE_TRUNC('minute', CAST(processed_at AS timestamp)) AS refunded_at_minute
FROM {{ ref('base_refunds_stripe') }}
