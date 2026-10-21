-- Human evidence complements executable checks. Unknown opening cash, stock,
-- recipes and external Office identity are never inferred from a POS template.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.store_external_links (
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,provider text NOT NULL CHECK(provider='office'),
 external_id uuid NOT NULL,tax_entity_id uuid NOT NULL REFERENCES public.tax_entity(id),contract_version text NOT NULL,evidence_reference text NOT NULL,
 verified_by uuid NOT NULL,verified_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(restaurant_id,provider),UNIQUE(provider,external_id)
);
ALTER TABLE public.store_external_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.store_external_links FROM PUBLIC,anon,authenticated;
CREATE TRIGGER store_external_links_immutable BEFORE UPDATE ON public.store_external_links FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE TABLE public.store_operational_acceptances (
 id uuid PRIMARY KEY,restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
 employee_id uuid NOT NULL,source_hash text NOT NULL,payload jsonb NOT NULL,input_hash text NOT NULL,
 actor_id uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX store_operational_acceptances_store ON public.store_operational_acceptances(restaurant_id,created_at DESC,id DESC);
ALTER TABLE public.store_operational_acceptances ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.store_operational_acceptances FROM PUBLIC,anon,authenticated;
CREATE TRIGGER store_operational_acceptances_immutable BEFORE UPDATE ON public.store_operational_acceptances FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE FUNCTION public.store_operational_source_v1(p_store uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT md5(jsonb_build_object('workflow',store_workflow_source(p_store),'identity',(SELECT jsonb_build_array(brand_id,tax_entity_id,name,address) FROM restaurants WHERE id=p_store),
 'external_links',(SELECT jsonb_agg(jsonb_build_array(provider,external_id,tax_entity_id,contract_version) ORDER BY provider) FROM store_external_links WHERE restaurant_id=p_store),'settings',(SELECT md5(coalesce(settings_json,'{}')::text) FROM restaurant_settings WHERE restaurant_id=p_store),
 'recipes',(SELECT jsonb_agg(jsonb_build_array(id,menu_item_id,ingredient_id,quantity_g) ORDER BY id) FROM menu_recipes WHERE restaurant_id=p_store),
 'ingredients',(SELECT jsonb_agg(jsonb_build_array(id,unit,is_active) ORDER BY id) FROM inventory_items WHERE restaurant_id=p_store AND is_active),
 'products',(SELECT jsonb_agg(jsonb_build_array(id,inventory_item_id,base_unit,is_active,is_orderable,receipt_classification) ORDER BY id) FROM inventory_products WHERE restaurant_id=p_store AND is_active))::text);
$$;
CREATE FUNCTION public.admin_get_store_operational_inputs_v1(p_store uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE result jsonb;
BEGIN
 PERFORM require_brand_admin_v1();
 IF (SELECT count(*) FROM menu_items WHERE restaurant_id=p_store)>4000 OR (SELECT count(*) FROM inventory_products WHERE restaurant_id=p_store)>2000 OR (SELECT count(*) FROM menu_recipes WHERE restaurant_id=p_store)>20000 THEN RAISE EXCEPTION 'STORE_CONFIGURATION_LIMIT'; END IF;
 SELECT jsonb_build_object('source_hash',store_operational_source_v1(p_store),'office_store_id',(SELECT external_id FROM store_external_links WHERE restaurant_id=p_store AND provider='office'),'office_required',EXISTS(SELECT 1 FROM inventory_products WHERE restaurant_id=p_store AND is_active AND is_orderable),
 'menus_without_recipe',coalesce((SELECT jsonb_agg(jsonb_build_object('id',m.id,'name',m.name) ORDER BY m.id) FROM menu_items m WHERE m.restaurant_id=p_store AND m.is_available AND NOT m.is_archived AND m.size_parent_id IS NULL AND NOT EXISTS(SELECT 1 FROM menu_recipes recipe WHERE recipe.menu_item_id=m.id)),'[]'),
 'unmeasured_inventory',(SELECT count(*) FROM inventory_items i WHERE i.restaurant_id=p_store AND i.is_active AND NOT EXISTS(SELECT 1 FROM inventory_lot_count_rows c WHERE c.ingredient_id=i.id)),
 'last_acceptance',(SELECT jsonb_build_object('id',a.id,'created_at',a.created_at,'payload',a.payload,'source_current',a.source_hash=store_operational_source_v1(p_store)) FROM store_operational_acceptances a WHERE a.restaurant_id=p_store ORDER BY created_at DESC,id DESC LIMIT 1)) INTO result FROM restaurants r WHERE r.id=p_store;
 IF result IS NULL THEN RAISE EXCEPTION 'STORE_NOT_FOUND'; END IF;
 RETURN result;
END $$;
CREATE FUNCTION public.admin_record_store_operational_acceptance_v1(p_id uuid,p_store uuid,p_employee uuid,p_source_hash text,p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE previous store_operational_acceptances; input_hash text; source text; employee store_employees; shop restaurants; office_link store_external_links;
BEGIN
 PERFORM require_brand_admin_v1();
 IF p_id IS NULL OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR octet_length(p_payload::text)>1048576
 OR jsonb_typeof(p_payload->'opening_cash_amount') IS DISTINCT FROM 'number' OR (p_payload->>'opening_cash_amount')::numeric<0
 OR p_payload->>'currency' IS DISTINCT FROM 'VND' OR p_payload->>'timezone' IS DISTINCT FROM 'Asia/Ho_Chi_Minh'
 OR length(btrim(coalesce(p_payload->>'evidence_reference',''))) NOT BETWEEN 5 AND 1000
 OR EXISTS(SELECT 1 FROM unnest(ARRAY['channels','payments_refunds','cash_closing','offline_recovery','device_handover','reporting_owner'])key WHERE p_payload->'checks'->key IS DISTINCT FROM 'true'::jsonb)
 OR jsonb_typeof(p_payload->'recipe_exemptions') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'recipe_exemptions')>4000
 THEN RAISE EXCEPTION 'STORE_OPERATIONAL_EVIDENCE_REQUIRED'; END IF;
 input_hash:=md5(jsonb_build_object('store',p_store,'employee',p_employee,'source',p_source_hash,'payload',p_payload,'actor',auth.uid())::text);
 PERFORM pg_advisory_xact_lock(hashtextextended('store-opening:'||p_store,0));
 SELECT * INTO previous FROM store_operational_acceptances WHERE id=p_id;
 IF FOUND THEN
  IF previous.input_hash<>input_hash THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF;
  RETURN to_jsonb(previous);
 END IF;
 SELECT * INTO employee FROM store_employees WHERE id=p_employee AND store_id=p_store AND is_active;
 IF NOT FOUND THEN RAISE EXCEPTION 'HANDOVER_EMPLOYEE_REQUIRED'; END IF;
 SELECT * INTO shop FROM restaurants WHERE id=p_store FOR UPDATE;
 source:=store_operational_source_v1(p_store);
 IF p_source_hash IS DISTINCT FROM source THEN RAISE EXCEPTION 'STORE_CONFIGURATION_CHANGED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_payload->'recipe_exemptions')x LEFT JOIN menu_items m ON m.id=(x->>'menu_id')::uuid AND m.restaurant_id=p_store AND m.is_available AND NOT m.is_archived
 WHERE m.id IS NULL OR length(btrim(coalesce(x->>'reason','')))<5) THEN RAISE EXCEPTION 'STORE_RECIPE_EXEMPTION_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM inventory_products WHERE restaurant_id=p_store AND is_active AND is_orderable) THEN
  IF nullif(p_payload->>'office_store_id','') IS NULL OR length(btrim(coalesce(p_payload->>'office_evidence','')))<5 OR length(btrim(coalesce(p_payload->>'office_contract_version','')))<1
   OR NOT coalesce((SELECT office_connected FROM procurement_store_onboarding WHERE restaurant_id=p_store),false) THEN RAISE EXCEPTION 'STORE_OFFICE_VERIFICATION_REQUIRED'; END IF;
  SELECT * INTO office_link FROM store_external_links WHERE restaurant_id=p_store AND provider='office';
  IF office_link.external_id IS NOT NULL AND (office_link.external_id<>(p_payload->>'office_store_id')::uuid OR office_link.tax_entity_id<>shop.tax_entity_id) THEN RAISE EXCEPTION 'STORE_OFFICE_IDENTITY_CHANGED'; END IF;
  INSERT INTO store_external_links(restaurant_id,provider,external_id,tax_entity_id,contract_version,evidence_reference,verified_by) VALUES(p_store,'office',(p_payload->>'office_store_id')::uuid,shop.tax_entity_id,p_payload->>'office_contract_version',p_payload->>'office_evidence',auth.uid()) ON CONFLICT(restaurant_id,provider) DO NOTHING;
 END IF;
 INSERT INTO store_operational_acceptances VALUES(p_id,p_store,p_employee,store_operational_source_v1(p_store),p_payload||jsonb_build_object('employee_snapshot',jsonb_build_object('id',employee.id,'name',employee.full_name,'number',employee.employee_number)),input_hash,auth.uid(),clock_timestamp()) RETURNING * INTO previous;
 RETURN to_jsonb(previous);
END $$;
ALTER FUNCTION public.admin_get_store_lifecycle_v1(uuid) RENAME TO admin_get_store_lifecycle_before_operational;
REVOKE ALL ON FUNCTION public.admin_get_store_lifecycle_before_operational(uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.admin_get_store_lifecycle_v1(p_store_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb; acceptance store_operational_acceptances; checks jsonb; source text; valid boolean;
BEGIN
 result:=admin_get_store_lifecycle_before_operational(p_store_id);
 IF (SELECT count(*) FROM inventory_products WHERE restaurant_id=p_store_id)>2000 OR (SELECT count(*) FROM menu_recipes WHERE restaurant_id=p_store_id)>20000 THEN RAISE EXCEPTION 'STORE_CONFIGURATION_LIMIT'; END IF;
 SELECT * INTO acceptance FROM store_operational_acceptances WHERE restaurant_id=p_store_id ORDER BY created_at DESC,id DESC LIMIT 1;
 valid:=coalesce(acceptance.source_hash=store_operational_source_v1(p_store_id) AND EXISTS(SELECT 1 FROM store_employees WHERE id=acceptance.employee_id AND store_id=p_store_id AND is_active),false);
 checks:=result->'checks'||jsonb_build_object('operational_acceptance',valid,
 'initial_inventory',NOT EXISTS(SELECT 1 FROM inventory_items i WHERE i.restaurant_id=p_store_id AND i.is_active AND NOT EXISTS(SELECT 1 FROM inventory_lot_count_rows c WHERE c.ingredient_id=i.id)),
 'recipes',NOT EXISTS(SELECT 1 FROM menu_recipes recipe LEFT JOIN inventory_items i ON i.id=recipe.ingredient_id AND i.restaurant_id=p_store_id AND i.is_active WHERE recipe.restaurant_id=p_store_id AND (i.id IS NULL OR recipe.quantity_g<=0)) AND
 NOT EXISTS(SELECT 1 FROM menu_items m WHERE m.restaurant_id=p_store_id AND m.is_available AND NOT m.is_archived AND m.size_parent_id IS NULL AND NOT EXISTS(SELECT 1 FROM menu_recipes r WHERE r.menu_item_id=m.id) AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(coalesce(acceptance.payload->'recipe_exemptions','[]'))x WHERE x->>'menu_id'=m.id::text)));
 source:=md5(jsonb_build_array(result->>'source_hash',store_operational_source_v1(p_store_id),acceptance.id,checks-'field_verification')::text);
 checks:=checks||jsonb_build_object('field_verification',EXISTS(SELECT 1 FROM store_opening_verifications WHERE restaurant_id=p_store_id AND source_hash=source));
 RETURN result||jsonb_build_object('checks',checks,'source_hash',source,'business_ready',NOT EXISTS(SELECT 1 FROM jsonb_each(checks)x WHERE x.value<>'true'::jsonb),'closure',store_closure_pending_v1(p_store_id));
END $$;
REVOKE ALL ON FUNCTION public.store_operational_source_v1(uuid) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.admin_get_store_operational_inputs_v1(uuid),public.admin_record_store_operational_acceptance_v1(uuid,uuid,uuid,text,jsonb),public.admin_get_store_lifecycle_v1(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_get_store_operational_inputs_v1(uuid),public.admin_record_store_operational_acceptance_v1(uuid,uuid,uuid,text,jsonb),public.admin_get_store_lifecycle_v1(uuid) TO authenticated;
COMMIT;
