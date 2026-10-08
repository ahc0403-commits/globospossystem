BEGIN;
SET LOCAL request.jwt.claim.sub = '00000000-0000-4000-8000-000000000001';
DO $test$
DECLARE f jsonb; oid uuid; job public.print_jobs%ROWTYPE;
BEGIN
  f := photo_test.create_request();
  UPDATE public.direct_order_requests SET fulfillment_method='pickup',
    customer_note='No steamed rice' WHERE id=(f->>'request_id')::uuid;
  oid := (photo_test.approve(f)->>'order_id')::uuid;
  SELECT * INTO STRICT job FROM public.print_jobs WHERE order_id=oid;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(job.payload->'items') i
    WHERE i->>'label'='Món' AND (i->>'unit_price')::numeric=0)
    OR job.payload->>'order_notes' IS NOT NULL THEN
    RAISE EXCEPTION 'RECEIPT_REQUESTS_PREDECESSOR_FAILURE_NOT_REPRODUCED';
  END IF;
END;
$test$;
ROLLBACK;
SELECT 'DIRECT_ORDER_RECEIPT_REQUESTS_BUG=REPRODUCED';
