{{ config(materialized='view') }}

-- Unions the three refund sources into a canonical schema.
-- One row per *source* refund record (NOT yet deduped across sources).
-- Source dedup + canonical refund-event grain lands in refund_fact.

SELECT
    refund_id
    , 'shopify' AS source_system
    , order_id
    , line_item_id
    , qty_refunded
    , CAST(NULL AS varchar) AS tender_type
    , amount_in_cents / 100.0 AS refund_amount
    , CAST(refunded_at AS timestamp) AS refunded_at
FROM {{ ref('base_refunds_shopify') }}

UNION ALL

SELECT
    refund_id
    , 'stripe' AS source_system
    , order_id
    , CAST(NULL AS varchar) AS line_item_id
    , CAST(NULL AS integer) AS qty_refunded
    , tender_type
    , amount_in_cents / 100.0 AS refund_amount
    , CAST(processed_at AS timestamp) AS refunded_at
FROM {{ ref('base_refunds_stripe') }}

UNION ALL

SELECT
    refund_id
    , 'internal_pos' AS source_system
    , order_id
    , CAST(NULL AS varchar) AS line_item_id
    , CAST(NULL AS integer) AS qty_refunded
    , CAST(NULL AS varchar) AS tender_type
    , amount_in_cents / 100.0 AS refund_amount
    , CAST(refunded_at AS timestamp) AS refunded_at
FROM {{ ref('base_refunds_internal_pos') }}
