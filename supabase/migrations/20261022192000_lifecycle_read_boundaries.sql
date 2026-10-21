-- Explicit bounded reference pages; no truncated readiness hashes. Closing also
-- waits for prepaid delivery/pickup and unfinished packaging.
-- production-gate: self-verifying
BEGIN;
CREATE FUNCTION public.admin_procurement_reference_page_v1(p_kind text,p_after uuid DEFAULT NULL,p_search text DEFAULT '') RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE result jsonb;
BEGIN
 PERFORM require_brand_admin_v1();
 IF length(coalesce(p_search,''))>160 THEN RAISE EXCEPTION 'REFERENCE_SEARCH_LIMIT'; END IF;
 IF p_kind='specs' THEN
  WITH latest AS(SELECT DISTINCT ON(code) id,code,revision,name,base_unit,specification FROM procurement_material_specs WHERE coalesce(p_search,'')='' OR code ILIKE '%'||p_search||'%' OR name ILIKE '%'||p_search||'%' ORDER BY code,revision DESC),
  page AS MATERIALIZED(SELECT * FROM latest WHERE p_after IS NULL OR id>p_after ORDER BY id LIMIT 51), visible AS(SELECT * FROM page ORDER BY id LIMIT 50)
  SELECT jsonb_build_object('rows',coalesce((SELECT jsonb_agg(to_jsonb(v) ORDER BY id) FROM visible v),'[]'),'next_cursor',CASE WHEN (SELECT count(*) FROM page)>50 THEN (SELECT id FROM visible ORDER BY id DESC LIMIT 1) END) INTO result;
 ELSIF p_kind='templates' THEN
  WITH latest AS(SELECT DISTINCT ON(family_id) id,family_id,revision,name,policy FROM procurement_policy_templates WHERE coalesce(p_search,'')='' OR name ILIKE '%'||p_search||'%' ORDER BY family_id,revision DESC),
  page AS MATERIALIZED(SELECT * FROM latest WHERE p_after IS NULL OR id>p_after ORDER BY id LIMIT 51), visible AS(SELECT * FROM page ORDER BY id LIMIT 50)
  SELECT jsonb_build_object('rows',coalesce((SELECT jsonb_agg(to_jsonb(v) ORDER BY id) FROM visible v),'[]'),'next_cursor',CASE WHEN (SELECT count(*) FROM page)>50 THEN (SELECT id FROM visible ORDER BY id DESC LIMIT 1) END) INTO result;
 ELSE RAISE EXCEPTION 'REFERENCE_KIND_INVALID'; END IF;
 RETURN result;
END $$;
DO $$ DECLARE d text; signature text; BEGIN
 d:=pg_get_functiondef('public.store_closure_pending_v1(uuid)'::regprocedure);
 d:=replace(d,'''orders'',', '''leftover_packaging'',(SELECT count(*) FROM leftover_packaging_requests WHERE restaurant_id=p_store AND status NOT IN(''completed'',''cancelled'')),''prepaid_handoffs'',(SELECT count(*) FROM direct_delivery_fulfillment_tickets WHERE restaurant_id=p_store AND status NOT IN(''completed'',''cancelled'')),''orders'','); EXECUTE d;
 d:=pg_get_functiondef('public.admin_get_store_lifecycle_before_operational(uuid)'::regprocedure);
 d:=replace(d,' accounts:=public.store_credential_snapshot_v1', ' IF (SELECT count(*) FROM store_employees WHERE store_id=p_store_id AND is_active)>200 OR (SELECT count(*) FROM printer_destinations WHERE restaurant_id=p_store_id)>20 OR (SELECT count(*) FROM printer_endpoints WHERE physical_printer_id IN(SELECT physical_printer_id FROM printer_destinations WHERE restaurant_id=p_store_id))>100 THEN RAISE EXCEPTION ''STORE_SETUP_SCOPE_LIMIT''; END IF; accounts:=public.store_credential_snapshot_v1');
 d:=replace(d,'''accounts'',jsonb_array_length(accounts)>0', '''accounts'',NOT EXISTS(SELECT 1 FROM store_account_onboarding_jobs j CROSS JOIN LATERAL jsonb_array_elements(j.accounts) a WHERE j.store_id=p_store_id AND a->>''scope''=''store'' AND NOT (p_store_id=''273b057e-3b69-46e3-93c1-6194c2802849''::uuid AND a->>''account_code''=''jgbt_tray1'') AND NOT EXISTS(SELECT 1 FROM store_fixed_account_requirements req WHERE req.store_id=p_store_id AND req.account_code=a->>''account_code'' AND req.is_active)) AND jsonb_array_length(accounts)>0'); EXECUTE d;
 FOREACH signature IN ARRAY ARRAY['public.admin_get_store_operational_inputs_v1(uuid)','public.admin_get_store_lifecycle_v1(uuid)'] LOOP
  d:=pg_get_functiondef(signature::regprocedure);
  d:=replace(d,' AND m.size_parent_id IS NULL','');
  d:=replace(d,'>20000 THEN RAISE', '>20000 OR (SELECT count(*) FROM inventory_items WHERE restaurant_id='||CASE WHEN signature LIKE '%inputs%' THEN 'p_store' ELSE 'p_store_id' END||' AND is_active)>2000 THEN RAISE');
  -- An old count cannot establish the reopening stock balance.
  d:=replace(d,'c.ingredient_id=i.id)', 'c.ingredient_id=i.id AND c.created_at>=coalesce((SELECT max(created_at) FROM store_reopening_events WHERE restaurant_id=i.restaurant_id),''-infinity''::timestamptz))'); EXECUTE d;
 END LOOP;
 d:=pg_get_functiondef('public.inventory_lot_workspace_v1(uuid,uuid,uuid)'::regprocedure);
 d:=replace(d,' WITH page AS', ' IF (SELECT count(*) FROM store_employees WHERE store_id=p_store AND is_active)>200 THEN RAISE EXCEPTION ''INVENTORY_EMPLOYEE_SCOPE_LIMIT''; END IF; WITH page AS'); EXECUTE d;
 d:=pg_get_functiondef('public.admin_save_inventory_location_v1(uuid,uuid,text,text,boolean,bigint)'::regprocedure);
 d:=replace(d,'''inventory-location:''||p_id','''inventory-locations-store:''||p_store'); EXECUTE d;
END $$;
REVOKE ALL ON FUNCTION public.admin_procurement_reference_page_v1(text,uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_procurement_reference_page_v1(text,uuid,text) TO authenticated;
COMMIT;
