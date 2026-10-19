BEGIN;
DO $$
DECLARE f jsonb := photo_test.create_request(); e text;
BEGIN
 BEGIN
  PERFORM public.direct_order_approve_payment((f->>'store_id')::uuid,(f->>'request_id')::uuid,108000,NULL);
 EXCEPTION WHEN OTHERS THEN e:=SQLERRM; END;
 IF e IS DISTINCT FROM 'DIRECT_ORDER_VERIFIED_PAYMENT_REQUIRED' THEN RAISE EXCEPTION 'ORIGINAL_FAILURE_NOT_REPRODUCED:%',e; END IF;
 PERFORM photo_test.assert_empty_graph((f->>'request_id')::uuid);
END $$;
ROLLBACK;
