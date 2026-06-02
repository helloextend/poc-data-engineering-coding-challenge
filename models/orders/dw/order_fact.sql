{{ config(
    materialized='incremental',
    unique_key='order_id'
) }}

WITH line_totals AS (
    SELECT
        li.order_id
        , count(DISTINCT li.line_item_id) AS line_count
        , sum(li.quantity)               AS total_quantity
        , sum(li.quantity * li.unit_price) AS revenue
    FROM {{ ref('stg_line_items') }} AS li
    GROUP BY li.order_id
)

, shipment_aggs AS (
    SELECT
        order_id
        , count(DISTINCT shipment_id) AS shipment_count
        , min(shipped_at)             AS shipped_at
    FROM {{ ref('stg_shipments') }}
    GROUP BY order_id
)

, joined AS (
    SELECT
        o.order_id
        , o.merchant_id
        , o.customer_id
        , o.order_status
        , o.is_test
        , o.ordered_at
        , o.paid_at
        , sa.shipment_count
        , sa.shipped_at
        , lt.line_count
        , lt.total_quantity
        , lt.revenue
    FROM {{ ref('stg_orders') }} AS o
    LEFT JOIN shipment_aggs AS sa
        ON o.order_id = sa.order_id
    LEFT JOIN line_totals AS lt
        ON o.order_id = lt.order_id
)

, enriched AS (
    SELECT
        j.order_id
        , j.merchant_id
        , m.merchant_name
        , j.customer_id
        , m.customer_type
        , j.order_status
        , j.is_test
        , j.ordered_at
        , j.paid_at
        , j.shipped_at
        , j.shipment_count
        , j.line_count
        , j.total_quantity
        , j.revenue
    FROM joined AS j
    LEFT JOIN {{ ref('lkp_merchants') }} AS m
        ON j.merchant_id = m.merchant_id
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