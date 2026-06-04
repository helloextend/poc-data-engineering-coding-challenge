-- Per-order: order_fact.refund_total must equal sum(refund_fact.refund_amount).
-- Row-level invariant (per CONTRIBUTING.md: row-level > aggregate reconciliation).

WITH fact_refunds AS (
    SELECT
        order_id
        , sum(refund_amount) AS expected_refund_total
    FROM {{ ref('refund_fact') }}
    GROUP BY order_id
)

SELECT
    f.order_id
    , f.refund_total
    , coalesce(fr.expected_refund_total, 0) AS expected_refund_total
    , f.refund_total - coalesce(fr.expected_refund_total, 0) AS diff
FROM {{ ref('order_fact') }} AS f
LEFT JOIN fact_refunds AS fr
    ON f.order_id = fr.order_id
WHERE abs(f.refund_total - coalesce(fr.expected_refund_total, 0)) > 0.01
