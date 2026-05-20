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
    , current_timestamp AS created_at_dwh
    , current_timestamp AS updated_at_dwh
FROM {{ ref('stg_orders') }} AS o
LEFT JOIN order_revenue AS orev
    ON o.order_id = orev.order_id
LEFT JOIN order_shipments AS os
    ON o.order_id = os.order_id
LEFT JOIN {{ ref('lkp_merchants') }} AS m
    ON o.merchant_id = m.merchant_id
{% if is_incremental() %}
    WHERE o.ordered_at >= {{ get_incremental_value('ordered_at') }}
{% endif %}
