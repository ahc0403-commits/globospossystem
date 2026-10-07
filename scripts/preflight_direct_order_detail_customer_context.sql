DO $$ BEGIN
  IF to_regprocedure('public.direct_order_public_status_v3(uuid,text,uuid)') IS NULL
    OR to_regprocedure('public.direct_order_public_status_v4(uuid,text,uuid)') IS NOT NULL
    OR NOT EXISTS (SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='direct_order_requests' AND column_name='pii_purged_at')
    OR NOT EXISTS (SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='direct_order_request_items' AND column_name='item_note') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_DETAIL_PRECONDITION_FAILED';
  END IF;
END $$;
SELECT 'DIRECT_ORDER_DETAIL_PREFLIGHT=PASS';
