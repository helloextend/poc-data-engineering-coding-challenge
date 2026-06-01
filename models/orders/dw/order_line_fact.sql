{{ config(
    materialized='incremental',
    unique_key='line_item_id'
) }}

WITH shopify_refunds AS (
    SELECT
        line_item_id
        , sum(refund_amount) AS refund_amount_shopify
    FROM {{ ref('stg_refunds_shopify') }}
    GROUP BY line_item_id
)

, order_stripe_refunds AS (
    SELECT
        order_id
        , sum(refund_amount) AS refund_amount_stripe
    FROM {{ ref('stg_refunds_stripe') }}
    GROUP BY order_id
)

, order_pos_refunds AS (
    SELECT
        order_id
        , sum(refund_amount) AS refund_amount_internal_pos
    FROM {{ ref('stg_refunds_internal_pos') }}
    GROUP BY order_id
)

, line_base AS (
    SELECT
        li.line_item_id
        , li.order_id
        , li.product_id
        , li.quantity
        , li.unit_price
        , li.line_status
        , li.quantity * li.unit_price AS line_revenue
        , CASE
            WHEN li.line_status = 'cancelled' THEN li.quantity * li.unit_price
            ELSE 0
        END AS cancelled_revenue
        , coalesce(sf.refund_amount_shopify, 0) AS refund_amount_shopify
        , sum(li.quantity * li.unit_price) OVER (PARTITION BY li.order_id) AS order_line_revenue
    FROM {{ ref('stg_line_items') }} AS li
    LEFT JOIN shopify_refunds AS sf
        ON li.line_item_id = sf.line_item_id
)

, enriched AS (
    SELECT
        lb.line_item_id
        , lb.order_id
        , lb.product_id
        , lb.quantity
        , lb.unit_price
        , lb.line_status
        , lb.line_revenue
        , lb.cancelled_revenue
        , lb.refund_amount_shopify
        , CASE
            WHEN lb.order_line_revenue > 0
                THEN coalesce(str.refund_amount_stripe, 0) * lb.line_revenue / lb.order_line_revenue
            ELSE 0
        END AS refund_amount_stripe
        , CASE
            WHEN lb.order_line_revenue > 0
                THEN coalesce(pos.refund_amount_internal_pos, 0) * lb.line_revenue / lb.order_line_revenue
            ELSE 0
        END AS refund_amount_internal_pos
    FROM line_base AS lb
    LEFT JOIN order_stripe_refunds AS str
        ON lb.order_id = str.order_id
    LEFT JOIN order_pos_refunds AS pos
        ON lb.order_id = pos.order_id
)

SELECT
    line_item_id
    , order_id
    , product_id
    , quantity
    , unit_price
    , line_status
    , line_revenue
    , cancelled_revenue
    , refund_amount_shopify
    , refund_amount_stripe
    , refund_amount_internal_pos
    , refund_amount_shopify + refund_amount_stripe + refund_amount_internal_pos AS refund_amount
    , line_revenue - cancelled_revenue
        - (refund_amount_shopify + refund_amount_stripe + refund_amount_internal_pos) AS net_revenue
    , current_timestamp AS created_at_dwh
    , current_timestamp AS updated_at_dwh
FROM enriched

{% if is_incremental() %}
    WHERE line_item_id NOT IN (SELECT t.line_item_id FROM {{ this }} AS t)
{% endif %}
