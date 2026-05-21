-- Dedup invariant for §3.3: no (order_id, refunded_at_minute) appears in
-- stg_refunds from BOTH the shopify and stripe sources. If this fires, the
-- minute-truncation heuristic missed a collision and the same logical refund
-- is being double-counted.

WITH per_source AS (
    SELECT
        order_id
        , refunded_at_minute
        , source
    FROM {{ ref('stg_refunds') }}
    WHERE source IN ('shopify', 'stripe')
    GROUP BY order_id, refunded_at_minute, source
)

SELECT
    order_id
    , refunded_at_minute
    , count(DISTINCT source) AS source_count
FROM per_source
GROUP BY order_id, refunded_at_minute
HAVING count(DISTINCT source) > 1
