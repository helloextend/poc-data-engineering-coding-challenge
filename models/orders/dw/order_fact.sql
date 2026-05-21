{{ config(
    materialized='incremental',
    unique_key='order_id'
) }}

WITH order_revenue AS (
    SELECT
        order_id
        , sum(quantity * unit_price) AS revenue
        , sum(quantity) AS quantity_ordered
        , count(DISTINCT line_item_id) AS line_count
    FROM {{ ref('stg_line_items') }}
    GROUP BY order_id
)

, order_shipments AS (
    SELECT
        order_id
        , count(DISTINCT shipment_id) AS shipment_count
        , min(shipped_at) AS first_shipped_at
    FROM {{ ref('stg_shipments') }}
    GROUP BY order_id
)

, order_refunds AS (
    SELECT
        order_id
        , sum(refund_amount) AS refund_total
        , count(DISTINCT source_refund_id) AS refund_count
        , max(refunded_at) AS last_refunded_at
    FROM {{ ref('refund_fact') }}
    GROUP BY order_id
)

-- Orders with refund activity since the last incremental run.
-- Watermark column is `last_refunded_at` on this model (order_fact) — any refund
-- with refunded_at strictly greater than the previous max means the order needs
-- a refresh of its refund aggregates. See docs/designs/2026-Q2-refunds-modeling.md §4.
, orders_with_new_refunds AS (
    SELECT DISTINCT order_id
    FROM {{ ref('refund_fact') }}
    {% if is_incremental() %}
        WHERE refunded_at > {{ get_incremental_value('last_refunded_at', relation=this) }}
    {% endif %}
)

SELECT
    o.order_id
    , o.merchant_id
    , m.merchant_name
    , o.customer_id
    , m.customer_type
    , o.order_status
    , o.is_test
    , o.ordered_at
    , o.paid_at
    , os.first_shipped_at AS shipped_at
    , coalesce(os.shipment_count, 0) AS shipment_count
    , orev.line_count
    , orev.quantity_ordered AS total_quantity
    , orev.revenue
    , coalesce(orf.refund_total, 0) AS refund_total
    , coalesce(orf.refund_count, 0) AS refund_count
    , orf.last_refunded_at
    , orev.revenue - coalesce(orf.refund_total, 0) AS net_revenue
    , coalesce(orf.refund_total, 0) >= orev.revenue AND orev.revenue > 0 AS is_fully_refunded
    , current_timestamp AS created_at_dwh
    , current_timestamp AS updated_at_dwh
FROM {{ ref('stg_orders') }} AS o
LEFT JOIN order_revenue AS orev
    ON o.order_id = orev.order_id
LEFT JOIN order_shipments AS os
    ON o.order_id = os.order_id
LEFT JOIN order_refunds AS orf
    ON o.order_id = orf.order_id
LEFT JOIN {{ ref('lkp_merchants') }} AS m
    ON o.merchant_id = m.merchant_id
{% if is_incremental() %}
    LEFT JOIN orders_with_new_refunds AS nrf
        ON o.order_id = nrf.order_id
    WHERE o.ordered_at >= {{ get_incremental_value('ordered_at') }}
        OR nrf.order_id IS NOT NULL
{% endif %}
