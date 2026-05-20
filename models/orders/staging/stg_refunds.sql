{{ config(materialized='view') }}

-- Unified refund staging across the three source systems.
--
-- Dedup precedence (see docs/designs/2026-Q2-refunds-modeling.md §3.3):
--   1. Shopify wins on (order_id, refunded_at_minute) — line-grain, system of record for amount.
--   2. Internal POS is additive (standalone register, no e-commerce pairing).
--   3. Stripe rows are kept only when no Shopify pairing exists at the same (order_id, minute).
--      Stripe tender breakdown moves to stg_refund_tenders.
--
-- Heuristic limitation: the dedup join uses minute-truncated timestamps because
-- the source systems carry no shared refund key. If/when upstream provides a
-- gateway_refund_id cross-walk, swap that in here.

WITH shopify AS (
    SELECT
        refund_id AS source_refund_id
        , order_id
        , line_item_id
        , qty_refunded
        , amount_in_cents / 100.0 AS refund_amount
        , CAST(refunded_at AS timestamp) AS refunded_at
        , DATE_TRUNC('minute', CAST(refunded_at AS timestamp)) AS refunded_at_minute
    FROM {{ ref('base_refunds_shopify') }}
)

, stripe_raw AS (
    SELECT
        refund_id AS source_refund_id
        , order_id
        , tender_type
        , amount_in_cents / 100.0 AS refund_amount
        , CAST(processed_at AS timestamp) AS refunded_at
        , DATE_TRUNC('minute', CAST(processed_at AS timestamp)) AS refunded_at_minute
    FROM {{ ref('base_refunds_stripe') }}
)

-- Collapse Stripe tender splits to one row per refund event for dedup against Shopify.
, stripe_events AS (
    SELECT
        order_id
        , refunded_at_minute
        , MIN(refunded_at) AS refunded_at
        , MIN(source_refund_id) AS source_refund_id
        , SUM(refund_amount) AS refund_amount
    FROM stripe_raw
    GROUP BY order_id, refunded_at_minute
)

, shopify_keys AS (
    SELECT DISTINCT
        order_id
        , refunded_at_minute
    FROM shopify
)

, pos AS (
    SELECT
        refund_id AS source_refund_id
        , order_id
        , amount_in_cents / 100.0 AS refund_amount
        , CAST(refunded_at AS timestamp) AS refunded_at
        , DATE_TRUNC('minute', CAST(refunded_at AS timestamp)) AS refunded_at_minute
    FROM {{ ref('base_refunds_internal_pos') }}
)

, unified AS (
    SELECT
        'shopify' AS source
        , source_refund_id
        , order_id
        , line_item_id
        , qty_refunded
        , refund_amount
        , refunded_at
        , refunded_at_minute
    FROM shopify

    UNION ALL

    SELECT
        'internal_pos' AS source
        , source_refund_id
        , order_id
        , CAST(NULL AS varchar) AS line_item_id
        , CAST(NULL AS bigint) AS qty_refunded
        , refund_amount
        , refunded_at
        , refunded_at_minute
    FROM pos

    UNION ALL

    -- Stripe-direct: only refunds with no Shopify counterpart at the same (order_id, minute).
    SELECT
        'stripe' AS source
        , se.source_refund_id
        , se.order_id
        , CAST(NULL AS varchar) AS line_item_id
        , CAST(NULL AS bigint) AS qty_refunded
        , se.refund_amount
        , se.refunded_at
        , se.refunded_at_minute
    FROM stripe_events AS se
    LEFT JOIN shopify_keys AS sk
        ON se.order_id = sk.order_id
            AND se.refunded_at_minute = sk.refunded_at_minute
    WHERE sk.order_id IS NULL
)

SELECT
    MD5(source || '-' || source_refund_id || '-' || COALESCE(line_item_id, 'ORDER')) AS refund_event_id
    , source
    , source_refund_id
    , order_id
    , line_item_id
    , qty_refunded
    , refund_amount
    , refunded_at
    , refunded_at_minute
FROM unified
