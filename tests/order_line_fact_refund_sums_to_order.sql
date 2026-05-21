-- Per-order: sum(order_line_fact.refund_amount) must equal order_fact.refund_total
-- within ±$0.01 to allow for pro-rata rounding drift handled in order_line_fact.

WITH line_totals AS (
    SELECT
        order_id
        , sum(coalesce(refund_amount, 0)) AS line_refund_sum
    FROM {{ ref('order_line_fact') }}
    GROUP BY order_id
)

SELECT
    f.order_id
    , f.refund_total
    , coalesce(lt.line_refund_sum, 0) AS line_refund_sum
    , f.refund_total - coalesce(lt.line_refund_sum, 0) AS diff
FROM {{ ref('order_fact') }} AS f
LEFT JOIN line_totals AS lt
    ON f.order_id = lt.order_id
WHERE abs(f.refund_total - coalesce(lt.line_refund_sum, 0)) > 0.01
