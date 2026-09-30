-- Server-owned stocktake snapshots; drafts never adjust stock.
-- production-gate: self-verifying
BEGIN;
ALTER TABLE public.inventory_stock_audit_sessions ADD COLUMN IF NOT EXISTS count_snapshot jsonb;
ALTER TABLE public.inventory_stock_audit_sessions ADD COLUMN IF NOT EXISTS row_version integer NOT NULL DEFAULT 1;
ALTER TABLE public.inventory_stock_audit_sessions ADD COLUMN IF NOT EXISTS saved_count_lines jsonb NOT NULL DEFAULT '[]';

CREATE OR REPLACE FUNCTION public.prepare_inventory_stock_audit(p_store_id uuid,p_session_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE s public.inventory_stock_audit_sessions%ROWTYPE; snapshot jsonb;
BEGIN
 IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_FORBIDDEN'; END IF;
 IF p_session_id IS NOT NULL THEN
  SELECT * INTO s FROM public.inventory_stock_audit_sessions WHERE id=p_session_id AND restaurant_id=p_store_id;
  IF NOT FOUND OR s.count_snapshot IS NULL THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_SESSION_NOT_FOUND'; END IF;
 ELSE
  SELECT * INTO s FROM public.inventory_stock_audit_sessions WHERE restaurant_id=p_store_id AND status IN('planned','in_progress') AND count_snapshot IS NOT NULL AND created_by IS NOT DISTINCT FROM auth.uid() ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN
   SELECT jsonb_agg(jsonb_build_object('product_id',p.id,'product_code',p.product_code,'product_name',p.name,'base_unit',p.base_unit,'base_unit_factor',p.base_unit_factor,'stock_unit',p.stock_unit,'inventory_item_id',i.id,'current_stock_base',coalesce(i.current_stock,0),'stock_updated_at',i.updated_at,'product_updated_at',p.updated_at) ORDER BY p.product_code,p.id) INTO snapshot
   FROM public.inventory_products p JOIN public.inventory_items i ON i.id=p.inventory_item_id AND i.restaurant_id=p.restaurant_id WHERE p.restaurant_id=p_store_id AND p.is_active AND i.is_active;
   IF snapshot IS NULL THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_LINES_REQUIRED'; END IF;
   INSERT INTO public.inventory_stock_audit_sessions(restaurant_id,brand_id,audit_no,audit_type,status,planned_date,started_at,created_by,assigned_to,count_snapshot)
   SELECT p_store_id,brand_id,'INV-'||gen_random_uuid()::text,'ad_hoc','planned',(now() at time zone 'Asia/Ho_Chi_Minh')::date,now(),auth.uid(),auth.uid(),snapshot FROM public.restaurants WHERE id=p_store_id RETURNING * INTO s;
  END IF;
 END IF;
 RETURN jsonb_build_object('id',s.id,'store_id',s.restaurant_id,'version',s.row_version,'status',s.status,'exported_at',s.started_at,'snapshot',s.count_snapshot,'lines',s.saved_count_lines,'memo',s.memo);
END $$;

CREATE OR REPLACE FUNCTION public.save_inventory_stock_audit_v2(p_store_id uuid,p_session_id uuid,p_expected_version integer,p_lines jsonb,p_complete boolean DEFAULT false,p_memo text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE s public.inventory_stock_audit_sessions%ROWTYPE; line jsonb; snap jsonb; actual numeric; counted_at timestamptz; pid uuid; item public.inventory_items%ROWTYPE; product public.inventory_products%ROWTYPE; canonical jsonb; difference numeric;
BEGIN
 IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_FORBIDDEN'; END IF;
 SELECT * INTO s FROM public.inventory_stock_audit_sessions WHERE id=p_session_id AND restaurant_id=p_store_id FOR UPDATE;
 IF NOT FOUND OR s.count_snapshot IS NULL THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_SESSION_NOT_FOUND'; END IF;
 IF p_complete IS NULL THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_ACTUAL_INVALID'; END IF;
 IF p_lines IS NULL OR jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)=0 THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_LINES_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_lines) l GROUP BY l->>'product_id' HAVING count(*)>1) THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_DUPLICATE_PRODUCT'; END IF;
 SELECT jsonb_agg(jsonb_build_object('product_id',l->>'product_id','actual_quantity_base',l->'actual_quantity_base','counted_at',l->>'counted_at','excluded_reason',nullif(btrim(l->>'excluded_reason'),''),'memo',nullif(btrim(l->>'memo'),'')) ORDER BY l->>'product_id') INTO canonical FROM jsonb_array_elements(p_lines) l;
 IF s.status='completed' THEN
  IF p_complete AND s.saved_count_lines=canonical AND s.memo IS NOT DISTINCT FROM nullif(btrim(p_memo),'') THEN RETURN public.prepare_inventory_stock_audit(p_store_id,p_session_id); END IF;
  RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_SESSION_NOT_EDITABLE';
 END IF;
 IF s.status NOT IN('planned','in_progress') THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_SESSION_NOT_EDITABLE'; END IF;
 IF s.row_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_VERSION_CHANGED'; END IF;
 IF p_complete AND jsonb_array_length(canonical)<>jsonb_array_length(s.count_snapshot) THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_INCOMPLETE'; END IF;
 -- Lock in a stable order. A concurrent receipt/consumption must finish before
 -- snapshot comparison; any changed stock blocks this count instead of overwriting it.
 PERFORM i.id FROM public.inventory_items i JOIN public.inventory_products p ON p.inventory_item_id=i.id WHERE p.restaurant_id=p_store_id AND p.id IN(SELECT (l->>'product_id')::uuid FROM jsonb_array_elements(canonical) l) ORDER BY i.id FOR UPDATE OF i;
 PERFORM p.id FROM public.inventory_products p WHERE p.restaurant_id=p_store_id AND p.id IN(SELECT (l->>'product_id')::uuid FROM jsonb_array_elements(canonical) l) ORDER BY p.id FOR SHARE;
 FOR line IN SELECT * FROM jsonb_array_elements(canonical) LOOP
  pid:=(line->>'product_id')::uuid;
  SELECT x INTO snap FROM jsonb_array_elements(s.count_snapshot) x WHERE x->>'product_id'=pid::text;
  IF snap IS NULL THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_PRODUCT_NOT_FOUND'; END IF;
  IF nullif(btrim(line->>'excluded_reason'),'') IS NOT NULL THEN
   IF line->>'actual_quantity_base' IS NOT NULL THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_ACTUAL_INVALID'; END IF;
  ELSE
   IF jsonb_typeof(line->'actual_quantity_base')<>'number' OR (line->>'actual_quantity_base') !~ '^[0-9]+(\.[0-9]{1,3})?$' THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_ACTUAL_INVALID'; END IF;
   actual:=(line->>'actual_quantity_base')::numeric;
   IF actual IS NULL OR actual<0 OR actual>999999999.999 THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_ACTUAL_INVALID'; END IF;
   counted_at:=(line->>'counted_at')::timestamptz;
   IF counted_at IS NULL OR counted_at<s.started_at OR counted_at>now()+interval '5 minutes' THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_COUNT_TIME_INVALID'; END IF;
  END IF;
  SELECT * INTO product FROM public.inventory_products WHERE id=pid AND restaurant_id=p_store_id AND is_active;
  IF NOT FOUND OR product.inventory_item_id IS DISTINCT FROM (snap->>'inventory_item_id')::uuid OR product.base_unit IS DISTINCT FROM snap->>'base_unit' OR product.base_unit_factor IS DISTINCT FROM (snap->>'base_unit_factor')::numeric OR product.product_code IS DISTINCT FROM snap->>'product_code' OR product.updated_at IS DISTINCT FROM (snap->>'product_updated_at')::timestamptz THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_STOCK_CHANGED'; END IF;
  SELECT * INTO item FROM public.inventory_items WHERE id=product.inventory_item_id AND restaurant_id=p_store_id AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_ITEM_NOT_FOUND'; END IF;
  IF p_complete AND (coalesce(item.current_stock,0) IS DISTINCT FROM (snap->>'current_stock_base')::numeric OR item.updated_at IS DISTINCT FROM (snap->>'stock_updated_at')::timestamptz) THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_STOCK_CHANGED'; END IF;
 END LOOP;
 IF p_complete AND (SELECT count(*) FROM public.inventory_products p JOIN public.inventory_items i ON i.id=p.inventory_item_id WHERE p.restaurant_id=p_store_id AND p.is_active AND i.is_active)<>jsonb_array_length(s.count_snapshot) THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_STOCK_CHANGED'; END IF;
 DELETE FROM public.inventory_stock_audit_lines WHERE session_id=s.id;
 FOR line IN SELECT * FROM jsonb_array_elements(canonical) LOOP
  SELECT x INTO snap FROM jsonb_array_elements(s.count_snapshot) x WHERE x->>'product_id'=line->>'product_id';
  actual:=(line->>'actual_quantity_base')::numeric;
  difference:=actual-(snap->>'current_stock_base')::numeric;
  SELECT * INTO item FROM public.inventory_items WHERE id=(snap->>'inventory_item_id')::uuid;
  INSERT INTO public.inventory_stock_audit_lines(session_id,product_id,theoretical_quantity_base,actual_quantity_base,variance_quantity_base,variance_amount,status,memo)
   VALUES(s.id,(line->>'product_id')::uuid,(snap->>'current_stock_base')::numeric,actual,difference,round(difference*coalesce(item.cost_per_unit,0),2),CASE WHEN actual IS NULL THEN 'skipped' ELSE 'counted' END,coalesce(line->>'excluded_reason',line->>'memo'));
  IF p_complete AND actual IS NOT NULL THEN
   UPDATE public.inventory_items SET current_stock=actual,quantity=actual,updated_at=now() WHERE id=item.id;
   INSERT INTO public.inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,reference_type,reference_id,note,created_by)
    VALUES(p_store_id,item.id,'adjust',difference,'inventory_stock_audit',s.id,coalesce(line->>'memo',p_memo,'Stocktake'),auth.uid());
  END IF;
 END LOOP;
 UPDATE public.inventory_stock_audit_sessions SET planned_date=coalesce((SELECT min((l->>'counted_at')::timestamptz at time zone 'Asia/Ho_Chi_Minh')::date FROM jsonb_array_elements(canonical) l),planned_date),saved_count_lines=canonical,row_version=row_version+1,status=CASE WHEN p_complete THEN 'completed' ELSE 'in_progress' END,completed_at=CASE WHEN p_complete THEN now() ELSE NULL END,memo=nullif(btrim(p_memo),''),updated_at=now() WHERE id=s.id;
 RETURN public.prepare_inventory_stock_audit(p_store_id,s.id);
END $$;

-- Abandon a stale snapshot explicitly so the operator can download a fresh one.
CREATE OR REPLACE FUNCTION public.cancel_inventory_stock_audit(p_store_id uuid,p_session_id uuid,p_expected_version integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
BEGIN
 IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_FORBIDDEN'; END IF;
 UPDATE public.inventory_stock_audit_sessions SET status='cancelled',updated_at=now(),row_version=row_version+1 WHERE id=p_session_id AND restaurant_id=p_store_id AND count_snapshot IS NOT NULL AND row_version=p_expected_version AND status IN('planned','in_progress');
 IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_VERSION_CHANGED'; END IF;
END $$;
REVOKE ALL ON FUNCTION public.prepare_inventory_stock_audit(uuid,uuid),public.save_inventory_stock_audit_v2(uuid,uuid,integer,jsonb,boolean,text),public.cancel_inventory_stock_audit(uuid,uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.prepare_inventory_stock_audit(uuid,uuid),public.save_inventory_stock_audit_v2(uuid,uuid,integer,jsonb,boolean,text),public.cancel_inventory_stock_audit(uuid,uuid,integer) TO authenticated,service_role;
DO $$ BEGIN
 IF to_regprocedure('public.prepare_inventory_stock_audit(uuid,uuid)') IS NULL OR to_regprocedure('public.save_inventory_stock_audit_v2(uuid,uuid,integer,jsonb,boolean,text)') IS NULL THEN RAISE EXCEPTION 'STOCK_AUDIT_EXCEL_RPC_MISSING'; END IF;
END $$;
NOTIFY pgrst,'reload schema';
COMMIT;
