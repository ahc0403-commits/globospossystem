BEGIN;
CREATE FUNCTION public.record_procurement_accounting_status(p_store_id uuid,p_rows jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
BEGIN
 IF auth.role() IS DISTINCT FROM 'service_role' OR jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows)>50 THEN RAISE EXCEPTION 'PROCUREMENT_SCOPE_FORBIDDEN'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_rows) x LEFT JOIN public.inventory_purchase_orders po ON po.id=(x->>'purchase_order_id')::uuid AND po.restaurant_id=p_store_id AND po.workflow_version=2 WHERE po.id IS NULL) THEN RAISE EXCEPTION 'PROCUREMENT_SCOPE_FORBIDDEN'; END IF;
 INSERT INTO public.procurement_accounting_status(purchase_order_id,restaurant_id,source_order_version,invoice_count,payable_count,held_count,paid_count,reconciliation_required,observed_at)
 SELECT (x->>'purchase_order_id')::uuid,p_store_id,COALESCE((x->>'source_order_version')::integer,0),(x->>'invoice_count')::integer,(x->>'payable_count')::integer,(x->>'held_count')::integer,(x->>'paid_count')::integer,COALESCE((x->>'reconciliation_required')::boolean,true),(x->>'observed_at')::timestamptz FROM jsonb_array_elements(p_rows) x
 ON CONFLICT(purchase_order_id) DO UPDATE SET source_order_version=EXCLUDED.source_order_version,invoice_count=EXCLUDED.invoice_count,payable_count=EXCLUDED.payable_count,held_count=EXCLUDED.held_count,paid_count=EXCLUDED.paid_count,reconciliation_required=EXCLUDED.reconciliation_required,observed_at=EXCLUDED.observed_at
 WHERE EXCLUDED.observed_at>=procurement_accounting_status.observed_at AND EXCLUDED.source_order_version>=procurement_accounting_status.source_order_version;
END $$;
REVOKE ALL ON FUNCTION public.record_procurement_accounting_status(uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.record_procurement_accounting_status(uuid,jsonb) TO service_role;
COMMIT;
