DO $$
BEGIN
  PERFORM queue_id,created_at,order_item_id,is_cancelled
    FROM public.emergency_fulfillment_items WHERE false;
  PERFORM restaurant_id,created_at,id FROM public.payments WHERE false;
  -- A blocking transactional build is intentionally limited to small tables.
  -- A larger deployment needs a separately reviewed concurrent-build runbook.
  IF pg_relation_size('public.emergency_fulfillment_items') > 67108864
    OR pg_relation_size('public.payments') > 67108864 THEN
    RAISE EXCEPTION 'INDEX_BUILD_REQUIRES_CONCURRENT_RUNBOOK';
  END IF;
END $$;
