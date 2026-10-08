-- Menu requests are enriched for a whole KDS snapshot, never per-card queries.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';
ALTER FUNCTION public.emergency_enrich_start_ready_orders(jsonb) RENAME TO emergency_enrich_start_ready_orders_pre_menu_requests;
REVOKE ALL ON FUNCTION public.emergency_enrich_start_ready_orders_pre_menu_requests(jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.emergency_enrich_start_ready_orders(p_orders jsonb)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH enriched AS MATERIALIZED (
  SELECT public.emergency_enrich_start_ready_orders_pre_menu_requests(p_orders) AS orders
 ), orders AS MATERIALIZED (
  SELECT o.value,o.ordinality FROM enriched CROSS JOIN LATERAL jsonb_array_elements(COALESCE(enriched.orders,'[]'::jsonb)) WITH ORDINALITY o
 ), items AS (
  SELECT o.ordinality AS order_ordinal,i.ordinality,i.value || jsonb_build_object('notes',CASE WHEN q.id IS NOT NULL THEN NULLIF(btrim(oi.notes),'') ELSE i.value->>'notes' END) AS value
  FROM orders o CROSS JOIN LATERAL jsonb_array_elements(COALESCE(o.value->'items','[]'::jsonb)) WITH ORDINALITY i
  LEFT JOIN public.order_items oi ON oi.id=NULLIF(i.value->>'order_item_id','')::uuid
  LEFT JOIN public.emergency_order_queue q ON q.id=NULLIF(o.value->>'queue_id','')::uuid AND q.order_id=oi.order_id
 ), grouped AS (
  SELECT order_ordinal,jsonb_agg(value ORDER BY ordinality) AS value FROM items GROUP BY order_ordinal
 )
 SELECT COALESCE(jsonb_agg(o.value||jsonb_build_object('items',COALESCE(i.value,'[]'::jsonb)) ORDER BY o.ordinality),'[]'::jsonb)
 FROM orders o LEFT JOIN grouped i ON i.order_ordinal=o.ordinality;
$$;
REVOKE ALL ON FUNCTION public.emergency_enrich_start_ready_orders(jsonb) FROM PUBLIC,anon,authenticated;
DO $verify$
BEGIN
 IF has_function_privilege('anon','public.emergency_enrich_start_ready_orders(jsonb)','EXECUTE') THEN
  RAISE EXCEPTION 'KDS_MENU_REQUEST_ACCESS_FAILED'; END IF;
END;
$verify$;
COMMIT;
