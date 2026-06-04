{{ config(
    materialized='incremental',
    unique_key='refund_event_id'
) }}

-- One row per refund event at order × line × source grain.
-- See docs/designs/2026-Q2-refunds-modeling.md for modeling decisions.

SELECT
    r.refund_event_id
    , r.source
    , r.source_refund_id
    , r.order_id
    , r.line_item_id
    , r.qty_refunded
    , r.refund_amount
    , r.refunded_at
    , current_timestamp AS created_at_dwh
    , current_timestamp AS updated_at_dwh
FROM {{ ref('stg_refunds') }} AS r
{% if is_incremental() %}
    WHERE r.refunded_at >= {{ get_incremental_value('refunded_at') }}
{% endif %}
