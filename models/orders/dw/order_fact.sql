{{ config(
    materialized='incremental',
    unique_key='order_id'
) }}

WITH order_line_revenue AS (
    SELECT
        li.order_id
        , count(DISTINCT li.line_item_id) AS line_count
        , sum(li.quantity) AS total_quantity
        , sum(li.quantity * li.unit_price) AS revenue
    FROM {{ ref('stg_line_items') }} AS li
    GROUP BY li.order_id
)

, shipment_info AS (
    SELECT
        order_id
        , count(DISTINCT shipment_id) AS shipment_count
        , min(shipped_at) AS shipped_at
    FROM {{ ref('stg_shipments') }}
    GROUP BY order_id
)

, enriched AS (
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
        , si.shipped_at
        , coalesce(si.shipment_count, 0) AS shipment_count
        , coalesce(olr.line_count, 0) AS line_count
        , coalesce(olr.total_quantity, 0) AS total_quantity
        , coalesce(olr.revenue, 0.0) AS revenue
    FROM {{ ref('stg_orders') }} AS o
    LEFT JOIN {{ ref('lkp_merchants') }} AS m
        ON o.merchant_id = m.merchant_id
    LEFT JOIN order_line_revenue AS olr
        ON o.order_id = olr.order_id
    LEFT JOIN shipment_info AS si
        ON o.order_id = si.order_id
)

SELECT
    order_id
    , merchant_id
    , merchant_name
    , customer_id
    , customer_type
    , order_status
    , is_test
    , ordered_at
    , paid_at
    , shipped_at
    , shipment_count
    , line_count
    , total_quantity
    , revenue
    , current_timestamp AS created_at_dwh
    , current_timestamp AS updated_at_dwh
FROM enriched
{% if is_incremental() %}
    WHERE ordered_at >= {{ get_incremental_value('updated_at_dwh') }}
{% endif %}
