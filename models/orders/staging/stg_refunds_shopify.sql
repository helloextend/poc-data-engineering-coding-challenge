{{ config(materialized='view') }}

SELECT
    refund_id
    , order_id
    , line_item_id
    , qty_refunded
    , amount_in_cents / 100.0 AS refund_amount
    , CAST(refunded_at AS timestamp) AS refunded_at
FROM {{ ref('base_refunds_shopify') }}
