{{ config(
    materialized='table'
) }}

-- One row per (refund_event, line_item).
--
-- Two allocation paths (Decision #4):
--   - Direct line attribution from Shopify rows when the event has a
--     line_item_id (`has_line_attribution = TRUE` on refund_fact).
--   - Pro-rata by line_revenue (= quantity * unit_price) across the order's
--     lines when the source didn't tell us which line was refunded.
--
-- Per-line tender breakdown (cash vs store_credit) is allocated by scaling
-- the line's share against the EVENT-level cash/store_credit split. We don't
-- know which line a Stripe card-vs-store-credit dollar belongs to, so we
-- spread the tender ratio evenly across all lines in the event.

WITH refund_events AS (
    SELECT * FROM {{ ref('refund_fact') }}
)

, shopify_line_attributions AS (
    -- Direct line attribution. Sum in case Shopify has multiple rows for
    -- the same (event, line).
    SELECT
        re.refund_event_id
        , re.order_id
        , sr.line_item_id
        , sum(sr.refund_amount) AS line_refund_amount
    FROM refund_events AS re
    INNER JOIN {{ ref('stg_refunds') }} AS sr
        ON re.order_id = sr.order_id
            AND re.refunded_at = sr.refunded_at
    WHERE sr.source_system = 'shopify'
    GROUP BY re.refund_event_id, re.order_id, sr.line_item_id
)

, order_line_revenue AS (
    SELECT
        order_id
        , line_item_id
        , quantity * unit_price AS line_revenue
    FROM {{ ref('stg_line_items') }}
)

, prorata_allocations AS (
    -- For events WITHOUT line attribution, allocate the event's refund
    -- across the order's lines pro-rata by line revenue.
    SELECT
        re.refund_event_id
        , re.order_id
        , olr.line_item_id
        , re.refund_amount * olr.line_revenue
        / nullif(sum(olr.line_revenue) OVER (PARTITION BY re.refund_event_id), 0)
            AS line_refund_amount
    FROM refund_events AS re
    INNER JOIN order_line_revenue AS olr
        ON re.order_id = olr.order_id
    WHERE NOT re.has_line_attribution
)

, line_allocations AS (
    SELECT * FROM shopify_line_attributions
    UNION ALL
    SELECT * FROM prorata_allocations
)

SELECT
    la.refund_event_id
    , la.order_id
    , la.line_item_id
    , re.refunded_at
    , re.canonical_source
    , la.line_refund_amount AS refund_amount
    , la.line_refund_amount * re.cash_refund_amount
    / nullif(re.refund_amount, 0) AS cash_refund_amount
    , la.line_refund_amount * re.store_credit_amount
    / nullif(re.refund_amount, 0) AS store_credit_amount
    , current_timestamp AS created_at_dwh
    , current_timestamp AS updated_at_dwh
FROM line_allocations AS la
INNER JOIN refund_events AS re
    ON la.refund_event_id = re.refund_event_id
