-- Exercise deployed trigger functions with existing orders in temporary tables.
-- No real print job, receipt, order, payment, stock or account is written.
BEGIN;
DO $catalog$
BEGIN
  IF has_function_privilege('anon','public.direct_order_receipt_content(uuid,uuid,jsonb)','EXECUTE')
    OR has_function_privilege('authenticated','public.direct_order_receipt_content(uuid,uuid,jsonb)','EXECUTE')
    OR has_function_privilege('anon','public.direct_order_receipt_packing_context(uuid,uuid)','EXECUTE')
    OR NOT has_function_privilege('authenticated','public.direct_order_receipt_packing_context(uuid,uuid)','EXECUTE')
    OR has_function_privilege('authenticated','public.direct_order_enrich_print_fulfillment()','EXECUTE')
    OR has_function_privilege('authenticated','public.direct_order_enrich_digital_receipt_packing()','EXECUTE')
    OR NOT EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid='public.print_jobs'::regclass
        AND tgname='zz_direct_order_enrich_print_fulfillment'
        AND tgfoid='public.direct_order_enrich_print_fulfillment()'::regprocedure
        AND tgtype=7 AND tgenabled='O')
    OR NOT EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid='public.digital_receipts'::regclass
        AND tgname='zz_direct_order_enrich_digital_receipt_packing'
        AND tgfoid='public.direct_order_enrich_digital_receipt_packing()'::regprocedure
        AND tgtype=7 AND tgenabled='O') THEN
    RAISE EXCEPTION 'RECEIPT_REQUESTS_CATALOG_FAILED';
  END IF;
END;
$catalog$;
CREATE TEMP TABLE receipt_probe_jobs(order_id uuid,restaurant_id uuid,
  copy_type text,combined_payment_group_id uuid,payload jsonb);
CREATE TRIGGER force_print_job_menu_labels_vi BEFORE INSERT ON receipt_probe_jobs
  FOR EACH ROW EXECUTE FUNCTION public.force_print_job_menu_labels_vi();
CREATE TRIGGER zz_direct_order_enrich_print_fulfillment BEFORE INSERT ON receipt_probe_jobs
  FOR EACH ROW EXECUTE FUNCTION public.direct_order_enrich_print_fulfillment();
CREATE TEMP TABLE receipt_probe_digital(order_id uuid,restaurant_id uuid,
  combined_payment_group_id uuid,snapshot jsonb);
CREATE TRIGGER digital_receipt_force_vietnamese_items_trigger BEFORE INSERT ON receipt_probe_digital
  FOR EACH ROW EXECUTE FUNCTION public.digital_receipt_force_vietnamese_items();
CREATE TRIGGER zz_direct_order_enrich_digital_receipt_packing BEFORE INSERT ON receipt_probe_digital
  FOR EACH ROW EXECUTE FUNCTION public.direct_order_enrich_digital_receipt_packing();
DO $operational$
DECLARE
  actor uuid; row record; context jsonb; items jsonb; original jsonb;
  printed jsonb; digital jsonb; line jsonb; source jsonb;
  checked integer:=0; pickups integer:=0; deliveries integer:=0; notes integer:=0;
  expected integer; actual integer;
BEGIN
  SELECT auth_id INTO actor FROM public.users
    WHERE role='super_admin' AND is_active AND auth_id IS NOT NULL LIMIT 1;
  IF actor IS NULL THEN RAISE EXCEPTION 'RECEIPT_PROBE_ACTIVE_ACTOR_REQUIRED'; END IF;
  PERFORM set_config('request.jwt.claim.sub',actor::text,true);
  FOR row IN SELECT f.order_id,f.restaurant_id,f.delivery_fee_item_id,
      r.diner_count,r.fulfillment_method,r.reference_code,
      NULLIF(btrim(r.customer_note),'') AS note
    FROM public.direct_order_financials f JOIN public.direct_order_requests r
      ON r.id=f.request_id AND r.restaurant_id=f.restaurant_id
    ORDER BY f.approved_at DESC LIMIT 50 LOOP
    context:=public.direct_order_receipt_packing_context(row.restaurant_id,row.order_id);
    IF context IS DISTINCT FROM jsonb_build_object('diner_count',row.diner_count,
      'fulfillment_method',row.fulfillment_method,'direct_order_reference',row.reference_code,
      'order_notes',row.note,'delivery_fee_item_id',row.delivery_fee_item_id) THEN
      RAISE EXCEPTION 'RECEIPT_PROBE_NATIVE_CONTEXT_MISMATCH';
    END IF;
    SELECT COALESCE(jsonb_agg(to_jsonb(i)||jsonb_build_object('item_id',i.id)
      ORDER BY i.created_at,i.id),'[]'::jsonb) INTO items
      FROM public.order_items i WHERE i.order_id=row.order_id
        AND i.restaurant_id=row.restaurant_id AND i.status<>'cancelled';
    original:=jsonb_build_object('items',items,'total_amount',149040,
      'vat_amount',11040,'payments',jsonb_build_array('unchanged'));
    INSERT INTO receipt_probe_jobs VALUES(row.order_id,row.restaurant_id,'receipt',NULL,original)
      RETURNING payload INTO printed;
    INSERT INTO receipt_probe_digital VALUES(row.order_id,row.restaurant_id,NULL,original)
      RETURNING snapshot INTO digital;
    expected:=jsonb_array_length(items);
    IF row.fulfillment_method='pickup' THEN
      SELECT expected-count(*) INTO expected FROM jsonb_array_elements(items) e
        WHERE e->>'item_id'=row.delivery_fee_item_id::text;
      pickups:=pickups+1;
    ELSE deliveries:=deliveries+1; END IF;
    IF jsonb_array_length(printed->'items')<>expected
      OR jsonb_array_length(digital->'items')<>expected
      OR printed->'items' IS DISTINCT FROM digital->'items'
      OR printed->>'order_notes' IS DISTINCT FROM row.note
      OR digital->>'order_notes' IS DISTINCT FROM row.note
      OR printed-ARRAY['items','order_notes','diner_count','fulfillment_method','direct_order_reference','refunded_total']
        IS DISTINCT FROM original-'items'
      OR digital-ARRAY['items','order_notes','diner_count','fulfillment_method','direct_order_reference']
        IS DISTINCT FROM original-'items' THEN
      RAISE EXCEPTION 'RECEIPT_PROBE_CONTENT_OR_FINANCIAL_MISMATCH';
    END IF;
    FOR line IN SELECT e FROM jsonb_array_elements(printed->'items') e LOOP
      SELECT e INTO STRICT source FROM jsonb_array_elements(items) e
        WHERE e->>'item_id'=line->>'item_id';
      IF line-ARRAY['label','notes'] IS DISTINCT FROM source-ARRAY['label','notes']
        OR line->>'notes' IS DISTINCT FROM COALESCE(NULLIF(btrim(source->>'notes'),''),source->>'notes')
        OR (line->>'item_id'=row.delivery_fee_item_id::text
          AND (row.fulfillment_method='pickup' OR line->>'label'<>'Phí giao hàng')) THEN
        RAISE EXCEPTION 'RECEIPT_PROBE_LINE_OR_DELIVERY_FEE_MISMATCH';
      END IF;
    END LOOP;
    INSERT INTO receipt_probe_jobs VALUES(row.order_id,row.restaurant_id,'kitchen',NULL,original)
      RETURNING payload INTO printed;
    IF printed ? 'order_notes' OR jsonb_array_length(printed->'items')<>jsonb_array_length(items) THEN
      RAISE EXCEPTION 'RECEIPT_PROBE_NON_RECEIPT_CHANGED';
    END IF;
    INSERT INTO receipt_probe_digital VALUES(row.order_id,row.restaurant_id,gen_random_uuid(),'{"items":[],"group":true}'::jsonb)
      RETURNING snapshot INTO digital;
    IF digital<>'{"items":[],"group":true}'::jsonb THEN
      RAISE EXCEPTION 'RECEIPT_PROBE_COMBINED_CHANGED';
    END IF;
    IF row.note IS NOT NULL THEN notes:=notes+1; END IF;
    checked:=checked+1;
  END LOOP;
  IF checked=0 THEN RAISE EXCEPTION 'RECEIPT_PROBE_REAL_ORDERS_REQUIRED'; END IF;
  IF public.direct_order_receipt_content(gen_random_uuid(),row.order_id,items) IS NOT NULL THEN
    RAISE EXCEPTION 'RECEIPT_PROBE_CROSS_STORE_ENRICHED';
  END IF;
  PERFORM set_config('request.jwt.claim.sub','',true);
  BEGIN
    PERFORM public.direct_order_receipt_packing_context(row.restaurant_id,row.order_id);
    RAISE EXCEPTION 'RECEIPT_PROBE_MISSING_ACTOR_ACCEPTED';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM<>'DIRECT_ORDER_FORBIDDEN' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'RECEIPT_REQUESTS_OPERATIONAL=PASS existing_orders=% pickup=% delivery=% customer_notes=% persisted_test_rows=0',checked,pickups,deliveries,notes;
END;
$operational$;
ROLLBACK;
SELECT 'RECEIPT_REQUESTS_VERIFICATION=PASS';
