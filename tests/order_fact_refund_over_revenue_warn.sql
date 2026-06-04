{{ config(severity='warn') }}

-- Finance signal (not a bug): orders where refund_total exceeds revenue
-- (goodwill, over-refund, or data quality issue at the source). Surfaces as a
-- dbt test warning so Finance is notified but the build doesn't fail.

SELECT
    order_id
    , revenue
    , refund_total
    , refund_total - revenue AS over_refund
FROM {{ ref('order_fact') }}
WHERE refund_total > revenue + 0.01
    AND coalesce(lower(cast(is_test AS varchar)), 'false') != 'true'
