{{ config(materialized='view') }}

-- TODO: backfill historical pre-2023 data once we get the parquet drop from finance
-- (Sandra) -- this comment is from the prior contractor and predates the current data contract

SELECT cast(ordered_at as date) as order_date,
sum(revenue) as daily_revenue,
       count(distinct order_id) as orders
FROM {{ ref('order_fact') }}
where coalesce(lower(cast(is_test as varchar)), 'false') != 'true'
group by 1
order by 1
