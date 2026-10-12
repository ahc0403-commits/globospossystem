BEGIN;
-- production-gate: self-verifying
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';

-- Previous reported days remain unchanged. Starting with the owner's 12 October
-- correction, legacy delivery placeholders are not invoice items or mapping targets.
DO $rows$ DECLARE d text; signature text; anchor text; BEGIN
 FOREACH signature IN ARRAY ARRAY['public.pos_restaurant_receipt_rows_v2(date,uuid[])','public.pos_restaurant_receipt_rows_fresh(date,uuid[])'] LOOP
  SELECT pg_get_functiondef(signature::regprocedure) INTO d;
  anchor:='WHERE item.status<>''cancelled'' AND COALESCE(item.is_service_item,false)=false GROUP BY item.order_id';
  IF strpos(d,anchor)=0 THEN RAISE EXCEPTION 'NO_DELIVERY_FEE_EXPORT_ANCHOR_DRIFT: %',signature; END IF;
  d:=replace(d,anchor,$new$WHERE item.status<>'cancelled' AND COALESCE(item.is_service_item,false)=false
    AND (p_business_date<DATE '2026-10-12' OR NOT public.pos_is_delivery_fee_item(item.item_type,item.menu_item_id,item.display_name,item.label)) GROUP BY item.order_id$new$);
  EXECUTE d;
 END LOOP;
 SELECT pg_get_functiondef('public.get_pos_daily_sales_summary(date)'::regprocedure) INTO d;
 anchor:='COALESCE(item.is_service_item,false)=false';
 IF (length(d)-length(replace(d,anchor,'')))/length(anchor)<>3 THEN RAISE EXCEPTION 'NO_DELIVERY_FEE_SUMMARY_ANCHOR_DRIFT'; END IF;
 d:=replace(d,anchor,anchor||' AND (p_business_date<DATE ''2026-10-12'' OR NOT public.pos_is_delivery_fee_item(item.item_type,item.menu_item_id,item.display_name,item.label))');
 EXECUTE d;
 SELECT pg_get_functiondef('public.enqueue_meinvoice_cash_register_job()'::regprocedure) INTO d;
 anchor:='AND COALESCE(oi.is_service_item, false) = false;';
 IF strpos(d,anchor)=0 THEN RAISE EXCEPTION 'NO_DELIVERY_FEE_ENQUEUE_ANCHOR_DRIFT'; END IF;
 d:=replace(d,anchor,'AND COALESCE(oi.is_service_item, false) = false AND NOT public.pos_is_delivery_fee_item(oi.item_type,oi.menu_item_id,oi.display_name,oi.label);');
 EXECUTE d;
END $rows$;

DO $verify$ DECLARE signature text; BEGIN
 FOREACH signature IN ARRAY ARRAY['public.pos_restaurant_receipt_rows_v2(date,uuid[])','public.pos_restaurant_receipt_rows_fresh(date,uuid[])','public.get_pos_daily_sales_summary(date)','public.enqueue_meinvoice_cash_register_job()'] LOOP
  IF strpos(pg_get_functiondef(signature::regprocedure),'pos_is_delivery_fee_item')=0
  THEN RAISE EXCEPTION 'NO_DELIVERY_FEE_EXPORT_CONTRACT_DRIFT: %',signature; END IF;
 END LOOP;
 IF strpos(pg_get_functiondef('public.invoice_snapshot_is_valid(jsonb,timestamptz)'::regprocedure),'NULLIF(l->>''invoice_effective_to'','''') IS NOT NULL')=0
 THEN RAISE EXCEPTION 'OPEN_MAPPING_NULL_END_CONTRACT_DRIFT'; END IF;
END $verify$;
COMMIT;
