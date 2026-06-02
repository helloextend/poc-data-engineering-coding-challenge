{{ config(
    materialized='incremental',
    unique_key='order_id'
) }}

WITH order_base AS (
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
    FROM {{ ref('stg_orders') }} AS o
    LEFT JOIN {{ ref('lkp_merchants') }} AS m
        ON o.merchant_id = m.merchant_id
    {% if is_incremental() %}
    -- In incremental mode, only append orders we haven't loaded yet.
    WHERE o.order_id NOT IN (SELECT t.order_id FROM {{ this }} AS t)
    {% endif %}
)

, order_lines AS (
    -- One row per order from ordered line items (not shipment allocations).
    SELECT
        li.order_id
        , count(DISTINCT li.line_item_id) AS line_count
        , sum(li.quantity) AS total_quantity
        , sum(li.quantity * li.unit_price) AS revenue
    FROM {{ ref('stg_line_items') }} AS li
    GROUP BY li.order_id
)

, shipment_aggs AS (
    -- One row per order with shipment metadata.
    SELECT
        s.order_id
        , count(DISTINCT s.shipment_id) AS shipment_count
        , min(s.shipped_at) AS shipped_at
    FROM {{ ref('stg_shipments') }} AS s
    GROUP BY s.order_id
)

SELECT
    ob.order_id
    , ob.merchant_id
    , ob.merchant_name
    , ob.customer_id
    , ob.customer_type
    , ob.order_status
    , ob.is_test
    , ob.ordered_at
    , ob.paid_at
    , sa.shipped_at
    , coalesce(sa.shipment_count, 0) AS shipment_count
    , coalesce(ol.line_count, 0) AS line_count
    , coalesce(ol.total_quantity, 0) AS total_quantity
    , coalesce(ol.revenue, 0) AS revenue
    , current_timestamp AS created_at_dwh
    , current_timestamp AS updated_at_dwh
FROM order_base AS ob
LEFT JOIN order_lines AS ol
    ON ob.order_id = ol.order_id
LEFT JOIN shipment_aggs AS sa
    ON ob.order_id = sa.order_id
