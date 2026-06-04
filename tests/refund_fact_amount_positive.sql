-- All refund amounts must be strictly positive. A non-positive refund_amount
-- indicates either a sign-flip bug at ingest or a chargeback masquerading as a
-- refund (chargebacks are explicitly out of scope per §10 of the design doc).

SELECT
    refund_event_id
    , source
    , source_refund_id
    , refund_amount
FROM {{ ref('refund_fact') }}
WHERE refund_amount <= 0
