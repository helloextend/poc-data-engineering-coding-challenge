{{ config(
    materialized='incremental',
    unique_key='line_item_id'
) }}

-- One row per order line.
-- Refund attribution (see docs/designs/2026-Q2-refunds-modeling.md §3.4, §3.6):
--   * 'direct'   — Shopify-attributed refund, exact line_item_id match.
--   * 'pro_rata' — POS / Stripe-direct order-grain refund, allocated by line_revenue share.
--   * 'mixed'    — line has both direct and allocated components (rare).
--   * 'none'     — order has no refunds.
-- Rounding-drift trick: pro-rata amounts are rounded to cents and the residual
-- is pushed to the largest line per order so sum(line.refund_amount) ties to
-- order_fact.refund_total to the penny.

WITH refunds_direct AS (
    SELECT
        line_item_id
        , sum(refund_amount) AS direct_refund_amount
        , sum(qty_refunded) AS qty_refunded
    FROM {{ ref('refund_fact') }}
    WHERE line_item_id IS NOT NULL
    GROUP BY line_item_id
)

, refunds_order_grain AS (
    SELECT
        order_id
        , sum(refund_amount) AS order_grain_refund_total
    FROM {{ ref('refund_fact') }}
    WHERE line_item_id IS NULL
    GROUP BY order_id
)

, order_revenue AS (
    SELECT
        order_id
        , sum(quantity * unit_price) AS order_revenue_total
    FROM {{ ref('stg_line_items') }}
    GROUP BY order_id
)

, order_last_refunded AS (
    SELECT
        order_id
        , max(refunded_at) AS last_refunded_at
    FROM {{ ref('refund_fact') }}
    GROUP BY order_id
)

, line_with_allocation AS (
    SELECT
        li.line_item_id
        , li.order_id
        , li.product_id
        , li.quantity
        , li.unit_price
        , li.quantity * li.unit_price AS line_revenue
        , orv.order_revenue_total
        , rd.direct_refund_amount
        , rd.qty_refunded
        , rog.order_grain_refund_total
        , olr.last_refunded_at
        , CASE
            WHEN rog.order_grain_refund_total IS NOT NULL AND orv.order_revenue_total > 0
                THEN round(
                        (li.quantity * li.unit_price) / orv.order_revenue_total * rog.order_grain_refund_total
                        , 2
                    )
            ELSE 0
        END AS allocated_refund_raw
        , row_number() OVER (
            PARTITION BY li.order_id
            ORDER BY li.quantity * li.unit_price DESC, li.line_item_id
        ) AS line_rank
    FROM {{ ref('stg_line_items') }} AS li
    LEFT JOIN order_revenue AS orv
        ON li.order_id = orv.order_id
    LEFT JOIN refunds_direct AS rd
        ON li.line_item_id = rd.line_item_id
    LEFT JOIN refunds_order_grain AS rog
        ON li.order_id = rog.order_id
    LEFT JOIN order_last_refunded AS olr
        ON li.order_id = olr.order_id
)

, allocation_drift AS (
    SELECT
        order_id
        , max(order_grain_refund_total) - sum(allocated_refund_raw) AS drift
    FROM line_with_allocation
    WHERE order_grain_refund_total IS NOT NULL
    GROUP BY order_id
)

, lines_with_final_refund AS (
    SELECT
        lwa.line_item_id
        , lwa.order_id
        , lwa.product_id
        , lwa.quantity
        , lwa.unit_price
        , lwa.line_revenue
        , lwa.qty_refunded
        , lwa.last_refunded_at
        , coalesce(lwa.direct_refund_amount, 0)
        + lwa.allocated_refund_raw
        + CASE
            WHEN lwa.line_rank = 1 AND lwa.order_grain_refund_total IS NOT NULL
                THEN coalesce(ad.drift, 0)
            ELSE 0
        END AS refund_amount_raw
        , lwa.direct_refund_amount
        , lwa.order_grain_refund_total
    FROM line_with_allocation AS lwa
    LEFT JOIN allocation_drift AS ad
        ON lwa.order_id = ad.order_id
)

{% if is_incremental() %}
    , orders_with_new_refunds AS (
        SELECT DISTINCT order_id
        FROM {{ ref('refund_fact') }}
        WHERE refunded_at > {{ get_incremental_value('last_refunded_at', relation=this) }}
    )

    , existing_lines AS (
        SELECT line_item_id
        FROM {{ this }}
    )
{% endif %}

SELECT
    lwf.line_item_id
    , lwf.order_id
    , lwf.product_id
    , lwf.quantity
    , lwf.unit_price
    , lwf.line_revenue
    , lwf.qty_refunded
    , CASE
        WHEN lwf.direct_refund_amount IS NULL AND lwf.order_grain_refund_total IS NULL
            THEN cast(NULL AS double)
        ELSE lwf.refund_amount_raw
    END AS refund_amount
    , CASE
        WHEN lwf.direct_refund_amount IS NOT NULL AND lwf.order_grain_refund_total IS NOT NULL
            THEN 'mixed'
        WHEN lwf.direct_refund_amount IS NOT NULL
            THEN 'direct'
        WHEN lwf.order_grain_refund_total IS NOT NULL
            THEN 'pro_rata'
        ELSE 'none'
    END AS refund_allocation_method
    , lwf.line_revenue - coalesce(
        CASE
            WHEN lwf.direct_refund_amount IS NULL AND lwf.order_grain_refund_total IS NULL
                THEN 0
            ELSE lwf.refund_amount_raw
        END
        , 0
    ) AS net_line_revenue
    , lwf.last_refunded_at
    , current_timestamp AS created_at_dwh
    , current_timestamp AS updated_at_dwh
FROM lines_with_final_refund AS lwf
{% if is_incremental() %}
    LEFT JOIN existing_lines AS el
        ON lwf.line_item_id = el.line_item_id
    LEFT JOIN orders_with_new_refunds AS nrf
        ON lwf.order_id = nrf.order_id
    WHERE el.line_item_id IS NULL
        OR nrf.order_id IS NOT NULL
{% endif %}
