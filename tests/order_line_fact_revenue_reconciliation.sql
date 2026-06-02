{{ config(severity='error') }}

-- Reconciles order_line_fact.line_revenue against summed raw line items for non-test orders.
-- Returns rows when totals do not match.

with fact_total as (
    select
        sum(line_revenue) as total_line_revenue,
        count(distinct line_item_id) as line_item_count
    from {{ ref('order_line_fact') }} as f
    inner join {{ source('raw', 'orders') }} as o
        on f.order_id = o.order_id
    where coalesce(lower(cast(o.is_test as varchar)), 'false') != 'true'
),

expected_total as (
    select
        sum(li.quantity * li.unit_price_in_cents) / 100.0 as expected_line_revenue,
        count(distinct li.line_item_id) as expected_line_item_count
    from {{ source('raw', 'line_items') }} as li
    inner join {{ source('raw', 'orders') }} as o
        on li.order_id = o.order_id
    where coalesce(lower(cast(o.is_test as varchar)), 'false') != 'true'
)

select
    f.total_line_revenue as fact_line_revenue,
    e.expected_line_revenue,
    e.expected_line_revenue - f.total_line_revenue as revenue_discrepancy,
    f.line_item_count as fact_line_item_count,
    e.expected_line_item_count,
    e.expected_line_item_count - f.line_item_count as line_item_count_discrepancy
from fact_total as f
cross join expected_total as e
where
    abs(e.expected_line_revenue - f.total_line_revenue) > 1
    OR (e.expected_line_item_count - f.line_item_count) != 0

