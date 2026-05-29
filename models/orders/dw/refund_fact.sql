{{ config(
    materialized='table'
) }}

-- One row per CANONICAL refund event, deduped across the three raw sources.
-- An "event" is identified by (order_id, refunded_at) — Stripe tender-type
-- splits and cross-source duplicates collapse into a single row.
--
-- Canonical refund_amount precedence (Decision #1): shopify > stripe > pos.
--   - Shopify wins when present because it carries line-level attribution.
--   - Within Stripe, rows are summed across tender_type for the event.
--
-- stripe_settled_amount = sum of Stripe rows where tender_type='card'
--   (matches what Stripe actually settles — Decision #2).
--
-- store_credit_amount = sum of Stripe rows where tender_type='store_credit'.
--   Per Decision #3, store credit is a deferred liability, so it's tracked
--   separately and excluded from cash_refund_amount.
--
-- cash_refund_amount = refund_amount − store_credit_amount.
--   This is the portion that reduces net revenue.

WITH per_source_event AS (
    SELECT
        order_id
        , refunded_at
        , source_system
        , sum(refund_amount) AS source_amount
    FROM {{ ref('stg_refunds') }}
    GROUP BY order_id, refunded_at, source_system
)

, stripe_tender AS (
    SELECT
        order_id
        , refunded_at
        , sum(CASE WHEN tender_type = 'card' THEN refund_amount ELSE 0 END) AS stripe_card_amount
        , sum(CASE WHEN tender_type = 'store_credit' THEN refund_amount ELSE 0 END) AS stripe_store_credit_amount
    FROM {{ ref('stg_refunds') }}
    WHERE source_system = 'stripe'
    GROUP BY order_id, refunded_at
)

, events AS (
    SELECT
        order_id
        , refunded_at
        , max(CASE WHEN source_system = 'shopify' THEN source_amount END) AS shopify_amount
        , max(CASE WHEN source_system = 'stripe' THEN source_amount END) AS stripe_amount
        , max(CASE WHEN source_system = 'internal_pos' THEN source_amount END) AS pos_amount
        , string_agg(DISTINCT source_system, ',' ORDER BY source_system) AS source_systems
    FROM per_source_event
    GROUP BY order_id, refunded_at
)

SELECT
    md5(e.order_id || '|' || cast(e.refunded_at AS varchar)) AS refund_event_id
    , e.order_id
    , e.refunded_at
    , coalesce(e.shopify_amount, e.stripe_amount, e.pos_amount) AS refund_amount
    , CASE
        WHEN e.shopify_amount IS NOT NULL THEN 'shopify'
        WHEN e.stripe_amount IS NOT NULL THEN 'stripe'
        ELSE 'internal_pos'
    END AS canonical_source
    , e.source_systems
    , (e.shopify_amount IS NOT NULL) AS has_line_attribution
    , coalesce(st.stripe_card_amount, 0) AS stripe_settled_amount
    , coalesce(st.stripe_store_credit_amount, 0) AS store_credit_amount
    , coalesce(e.shopify_amount, e.stripe_amount, e.pos_amount)
    - coalesce(st.stripe_store_credit_amount, 0) AS cash_refund_amount
    , current_timestamp AS created_at_dwh
    , current_timestamp AS updated_at_dwh
FROM events AS e
LEFT JOIN stripe_tender AS st
    ON e.order_id = st.order_id
        AND e.refunded_at = st.refunded_at
