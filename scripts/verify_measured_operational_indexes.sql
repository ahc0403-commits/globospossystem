DO $$
DECLARE v_name text; v_columns text[]; v_predicate text; v_expected text[];
BEGIN
  FOREACH v_name IN ARRAY ARRAY['emergency_items_queue_open_created','payments_store_created_id'] LOOP
    SELECT array_agg(a.attname::text ORDER BY k.ord),pg_get_expr(i.indpred,i.indrelid)
      INTO v_columns,v_predicate
    FROM pg_index i CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY k(attnum,ord)
    JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=k.attnum
    WHERE i.indexrelid=to_regclass('public.'||v_name) AND i.indisvalid AND i.indisready
      AND i.indrelid=CASE WHEN v_name='payments_store_created_id'
        THEN 'public.payments'::regclass ELSE 'public.emergency_fulfillment_items'::regclass END
    GROUP BY i.indpred,i.indrelid;
    v_expected := CASE WHEN v_name='payments_store_created_id'
      THEN ARRAY['restaurant_id','created_at','id'] ELSE ARRAY['queue_id','created_at','order_item_id'] END;
    IF v_columns IS DISTINCT FROM v_expected
      OR (v_name='payments_store_created_id' AND v_predicate IS NOT NULL)
      OR (v_name<>'payments_store_created_id' AND v_predicate IS DISTINCT FROM '(is_cancelled = false)') THEN
      RAISE EXCEPTION 'OPERATIONAL_INDEX_INVALID: %',v_name;
    END IF;
  END LOOP;
END $$;
SELECT 'measured operational indexes verified' AS result;
