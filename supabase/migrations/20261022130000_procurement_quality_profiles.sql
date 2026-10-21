-- Approved, immutable item criteria. PO lines freeze their version; an explicit
-- amendment is required to change criteria for an already-issued PO.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.procurement_quality_profiles (
 id uuid PRIMARY KEY,restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
 product_id uuid NOT NULL REFERENCES public.inventory_products(id) ON DELETE CASCADE,revision integer NOT NULL CHECK(revision>0),
 criteria jsonb NOT NULL,reason text NOT NULL,approved_by uuid NOT NULL,approved_at timestamptz NOT NULL DEFAULT now(),UNIQUE(product_id,revision)
);
CREATE TABLE public.procurement_order_quality (
 order_line_id uuid PRIMARY KEY REFERENCES public.inventory_purchase_order_lines(id) ON DELETE CASCADE,
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
 profile_id uuid NOT NULL REFERENCES public.procurement_quality_profiles(id),
 catalog_approval_id uuid NOT NULL REFERENCES public.procurement_catalog_approvals(id),
 template_id uuid NOT NULL REFERENCES public.procurement_policy_templates(id),
 captured_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.procurement_quality_amendments (
 id uuid PRIMARY KEY,order_line_id uuid NOT NULL REFERENCES public.procurement_order_quality(order_line_id) ON DELETE CASCADE,
 profile_id uuid NOT NULL REFERENCES public.procurement_quality_profiles(id),reason text NOT NULL CHECK(length(btrim(reason)) BETWEEN 5 AND 1000),
 approved_by uuid NOT NULL,approved_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX procurement_quality_amendments_line ON public.procurement_quality_amendments(order_line_id,approved_at DESC,id);
ALTER TABLE public.procurement_quality_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.procurement_order_quality ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.procurement_quality_amendments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_quality_profiles,public.procurement_order_quality,public.procurement_quality_amendments FROM PUBLIC,anon,authenticated;
CREATE TRIGGER procurement_quality_profiles_immutable BEFORE UPDATE ON public.procurement_quality_profiles FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE TRIGGER procurement_order_quality_immutable BEFORE UPDATE ON public.procurement_order_quality FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE TRIGGER procurement_quality_amendments_immutable BEFORE UPDATE ON public.procurement_quality_amendments FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE FUNCTION public.admin_publish_quality_profile_v1(p_id uuid,p_store uuid,p_product uuid,p_expected_revision integer,p_criteria jsonb,p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE prior procurement_quality_profiles;
BEGIN
 PERFORM require_brand_admin_v1();
 IF p_id IS NULL OR p_expected_revision IS NULL OR p_expected_revision<0 OR NOT EXISTS(SELECT 1 FROM inventory_products WHERE id=p_product AND restaurant_id=p_store AND is_active)
 OR length(btrim(coalesce(p_reason,''))) NOT BETWEEN 5 AND 1000 OR jsonb_typeof(p_criteria) IS DISTINCT FROM 'object' OR octet_length(p_criteria::text)>4096 THEN RAISE EXCEPTION 'QUALITY_PROFILE_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_criteria)k WHERE k NOT IN('temperature_required','temperature_min_c','temperature_max_c','expiry_required','min_remaining_days','min_sample_count','photo_required','lot_required'))
 OR EXISTS(SELECT 1 FROM unnest(ARRAY['temperature_required','expiry_required','photo_required','lot_required'])k WHERE jsonb_typeof(p_criteria->k) IS DISTINCT FROM 'boolean')
 OR jsonb_typeof(p_criteria->'min_sample_count') IS DISTINCT FROM 'number' OR (p_criteria->>'min_sample_count')::numeric NOT BETWEEN 1 AND 1000 OR (p_criteria->>'min_sample_count')::numeric<>trunc((p_criteria->>'min_sample_count')::numeric)
 THEN RAISE EXCEPTION 'QUALITY_PROFILE_INVALID'; END IF;
 IF (p_criteria->>'temperature_required')::boolean THEN
  IF jsonb_typeof(p_criteria->'temperature_min_c') IS DISTINCT FROM 'number' OR jsonb_typeof(p_criteria->'temperature_max_c') IS DISTINCT FROM 'number'
  OR (p_criteria->>'temperature_min_c')::numeric NOT BETWEEN -100 AND 100 OR (p_criteria->>'temperature_max_c')::numeric NOT BETWEEN -100 AND 100
  OR (p_criteria->>'temperature_min_c')::numeric>(p_criteria->>'temperature_max_c')::numeric THEN RAISE EXCEPTION 'QUALITY_TEMPERATURE_CRITERIA_REQUIRED'; END IF;
 ELSIF coalesce(p_criteria->'temperature_min_c','null')<>'null'::jsonb OR coalesce(p_criteria->'temperature_max_c','null')<>'null'::jsonb THEN RAISE EXCEPTION 'QUALITY_NOT_APPLICABLE_CONFLICT'; END IF;
 IF (p_criteria->>'expiry_required')::boolean THEN
  IF jsonb_typeof(p_criteria->'min_remaining_days') IS DISTINCT FROM 'number' OR (p_criteria->>'min_remaining_days')::numeric NOT BETWEEN 0 AND 3650
  OR (p_criteria->>'min_remaining_days')::numeric<>trunc((p_criteria->>'min_remaining_days')::numeric) THEN RAISE EXCEPTION 'QUALITY_EXPIRY_CRITERIA_REQUIRED'; END IF;
 ELSIF coalesce(p_criteria->'min_remaining_days','null')<>'null'::jsonb THEN RAISE EXCEPTION 'QUALITY_NOT_APPLICABLE_CONFLICT'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('quality-product:'||p_product,0));
 SELECT * INTO prior FROM procurement_quality_profiles WHERE id=p_id;
 IF FOUND THEN
  IF (prior.restaurant_id,prior.product_id,prior.revision,prior.criteria,prior.reason,prior.approved_by) IS DISTINCT FROM(p_store,p_product,p_expected_revision+1,p_criteria,btrim(p_reason),auth.uid()) THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF;
  RETURN to_jsonb(prior);
 END IF;
 IF coalesce((SELECT max(revision) FROM procurement_quality_profiles WHERE product_id=p_product),0)<>p_expected_revision THEN RAISE EXCEPTION 'QUALITY_PROFILE_STALE'; END IF;
 INSERT INTO procurement_quality_profiles VALUES(p_id,p_store,p_product,p_expected_revision+1,p_criteria,btrim(p_reason),auth.uid(),now()) RETURNING * INTO prior;
 RETURN to_jsonb(prior);
END $$;

CREATE FUNCTION public.store_capture_order_quality_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE ids uuid[];
BEGIN
 SELECT array_agg(n.id) INTO ids FROM new_quality_order_lines n JOIN inventory_purchase_orders o ON o.id=n.purchase_order_id
 WHERE EXISTS(SELECT 1 FROM store_registration_requests r WHERE r.store_id=o.restaurant_id)
 OR EXISTS(SELECT 1 FROM store_procurement_profiles p WHERE p.restaurant_id=o.restaurant_id AND p.enforced);
 IF ids IS NULL THEN RETURN NULL; END IF;
 IF cardinality(ids)>200 THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_LINES_REQUIRED'; END IF;
 WITH profiles AS MATERIALIZED(SELECT DISTINCT ON(q.product_id) q.* FROM procurement_quality_profiles q JOIN new_quality_order_lines n ON n.product_id=q.product_id WHERE n.id=ANY(ids) ORDER BY q.product_id,q.revision DESC),
 catalogs AS MATERIALIZED(SELECT DISTINCT ON(n.id) n.id line_id,a.id catalog_id FROM new_quality_order_lines n JOIN inventory_products p ON p.id=n.product_id
 JOIN inventory_supplier_items s ON s.id=n.supplier_item_id JOIN procurement_catalog_approvals a ON a.product_id=n.product_id AND a.supplier_item_id=n.supplier_item_id AND a.restaurant_id=p.restaurant_id
 WHERE n.id=ANY(ids) AND a.valid_from<=now() AND (a.valid_until IS NULL OR a.valid_until>now()) AND a.catalog_snapshot=procurement_catalog_snapshot_v1(p,s) ORDER BY n.id,a.approved_at DESC,a.id)
 INSERT INTO procurement_order_quality(order_line_id,restaurant_id,profile_id,catalog_approval_id,template_id)
 SELECT n.id,o.restaurant_id,q.id,a.catalog_id,profile.template_id FROM new_quality_order_lines n JOIN inventory_purchase_orders o ON o.id=n.purchase_order_id
 JOIN profiles q ON q.product_id=n.product_id AND q.restaurant_id=o.restaurant_id JOIN catalogs a ON a.line_id=n.id JOIN store_procurement_profiles profile ON profile.restaurant_id=o.restaurant_id WHERE n.id=ANY(ids);
 IF (SELECT count(*) FROM procurement_order_quality WHERE order_line_id=ANY(ids))<>cardinality(ids) THEN RAISE EXCEPTION 'PROCUREMENT_ORDER_CRITERIA_REQUIRED'; END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER store_capture_order_quality AFTER INSERT ON public.inventory_purchase_order_lines REFERENCING NEW TABLE AS new_quality_order_lines FOR EACH STATEMENT EXECUTE FUNCTION public.store_capture_order_quality_v1();

CREATE FUNCTION public.admin_amend_order_quality_v1(p_id uuid,p_line uuid,p_profile uuid,p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE prior procurement_quality_amendments; ord uuid;
BEGIN
 PERFORM require_brand_admin_v1();
 SELECT purchase_order_id INTO ord FROM inventory_purchase_order_lines WHERE id=p_line;
 PERFORM 1 FROM inventory_purchase_orders WHERE id=ord FOR UPDATE;
 IF p_id IS NULL OR length(btrim(coalesce(p_reason,''))) NOT BETWEEN 5 AND 1000 OR NOT EXISTS(
  SELECT 1 FROM procurement_order_quality q JOIN inventory_purchase_order_lines l ON l.id=q.order_line_id
  JOIN procurement_quality_profiles p ON p.id=p_profile AND p.product_id=l.product_id AND p.restaurant_id=q.restaurant_id WHERE q.order_line_id=p_line) THEN RAISE EXCEPTION 'QUALITY_AMENDMENT_INVALID'; END IF;
 SELECT * INTO prior FROM procurement_quality_amendments WHERE id=p_id;
 IF FOUND THEN
  IF (prior.order_line_id,prior.profile_id,prior.reason,prior.approved_by) IS DISTINCT FROM (p_line,p_profile,btrim(p_reason),auth.uid()) THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF;
  RETURN to_jsonb(prior);
 END IF;
 INSERT INTO procurement_quality_amendments(id,order_line_id,profile_id,reason,approved_by) VALUES(p_id,p_line,p_profile,btrim(p_reason),auth.uid()) RETURNING * INTO prior;
 RETURN to_jsonb(prior);
END $$;

CREATE FUNCTION public.procurement_effective_quality_v1(p_lines uuid[]) RETURNS TABLE(order_line_id uuid,profile_id uuid,revision integer,criteria jsonb,amendment_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH amendments AS(SELECT DISTINCT ON(order_line_id) order_line_id,profile_id,id FROM procurement_quality_amendments WHERE order_line_id=ANY(p_lines) ORDER BY order_line_id,approved_at DESC,id DESC)
 SELECT q.order_line_id,p.id,p.revision,p.criteria,a.id FROM procurement_order_quality q LEFT JOIN amendments a ON a.order_line_id=q.order_line_id
 JOIN procurement_quality_profiles p ON p.id=coalesce(a.profile_id,q.profile_id) WHERE q.order_line_id=ANY(p_lines);
$$;
CREATE FUNCTION public.procurement_enrich_quality_lines_v1(p_store uuid,p_lines jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE ids uuid[]; result jsonb;
BEGIN
 IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_LINES_REQUIRED'; END IF;
 SELECT array_agg((l->>'purchase_order_line_id')::uuid) INTO ids FROM jsonb_array_elements(p_lines)l;
 IF EXISTS(SELECT 1 FROM procurement_order_quality WHERE order_line_id=ANY(ids) AND restaurant_id<>p_store) THEN RAISE EXCEPTION 'PROCUREMENT_SCOPE_FORBIDDEN'; END IF;
 SELECT jsonb_agg(CASE WHEN q.order_line_id IS NULL THEN l.value ELSE jsonb_set(l.value,'{inspection}',coalesce(l.value->'inspection','{}')||jsonb_build_object('quality_snapshot',to_jsonb(q),'employee_snapshot',CASE WHEN e.id IS NULL THEN NULL ELSE jsonb_build_object('id',e.id,'name',e.full_name,'employee_number',e.employee_number,'store_id',e.store_id) END)) END ORDER BY l.ordinality) INTO result
 FROM jsonb_array_elements(p_lines) WITH ORDINALITY l(value,ordinality) LEFT JOIN procurement_effective_quality_v1(ids)q ON q.order_line_id=(l.value->>'purchase_order_line_id')::uuid LEFT JOIN store_employees e ON e.id=nullif(l.value->'inspection'->>'employee_id','')::uuid AND e.store_id=p_store AND e.is_active;
 RETURN result;
END $$;
ALTER FUNCTION public.procurement_validate_inspection_batch(uuid,jsonb) RENAME TO procurement_validate_inspection_before_quality;
REVOKE ALL ON FUNCTION public.procurement_validate_inspection_before_quality(uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.procurement_validate_inspection_batch(p_store_id uuid,p_lines jsonb) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE inspected jsonb; ids uuid[]; today date:=(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
BEGIN
 PERFORM procurement_validate_inspection_before_quality(p_store_id,p_lines);
 SELECT array_agg((x->>'purchase_order_line_id')::uuid) INTO ids FROM jsonb_array_elements(p_lines)x;
 SELECT coalesce(jsonb_agg(jsonb_build_object('line',x,'profile',to_jsonb(q),'accepted',coalesce((x->>'accepted_quantity_base')::numeric,(x->>'received_quantity_base')::numeric-coalesce((x->>'rejected_quantity_base')::numeric,0)))),'[]') INTO inspected
 FROM jsonb_array_elements(p_lines)x JOIN procurement_effective_quality_v1(ids)q ON q.order_line_id=(x->>'purchase_order_line_id')::uuid;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(inspected)x WHERE (x->'line'->>'received_quantity_base')::numeric>0 AND
  (x->'line'->'inspection'->>'quality_profile_id' IS DISTINCT FROM x->'profile'->>'profile_id'
  OR x->'line'->'inspection'->'quality_snapshot' IS DISTINCT FROM x->'profile')) THEN RAISE EXCEPTION 'QUALITY_REINSPECTION_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(inspected)x LEFT JOIN store_employees e ON e.id=nullif(x->'line'->'inspection'->>'employee_id','')::uuid AND e.store_id=p_store_id AND e.is_active WHERE (x->>'accepted')::numeric>0 AND e.id IS NULL) THEN RAISE EXCEPTION 'QUALITY_INSPECTOR_EMPLOYEE_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(inspected)x WHERE (x->>'accepted')::numeric>0 AND
  (coalesce(x->'line'->'inspection'->>'sample_count','')!~'^[0-9]{1,4}$' OR coalesce((nullif(x->'line'->'inspection'->>'sample_count',''))::integer,0)<(x->'profile'->'criteria'->>'min_sample_count')::integer)) THEN RAISE EXCEPTION 'QUALITY_SAMPLE_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(inspected)x WHERE (x->>'accepted')::numeric>0 AND (x->'profile'->'criteria'->>'temperature_required')::boolean AND
  (nullif(x->'line'->'inspection'->>'temperature_c','') IS NULL OR (x->'line'->'inspection'->>'temperature_c')::numeric::text IN('NaN','Infinity','-Infinity')
   OR (x->'line'->'inspection'->>'temperature_c')::numeric NOT BETWEEN (x->'profile'->'criteria'->>'temperature_min_c')::numeric AND (x->'profile'->'criteria'->>'temperature_max_c')::numeric)) THEN RAISE EXCEPTION 'QUALITY_TEMPERATURE_OUT_OF_RANGE'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(inspected)x WHERE (x->>'accepted')::numeric>0 AND (x->'profile'->'criteria'->>'expiry_required')::boolean AND
  (coalesce((x->'line'->'inspection'->>'expiry_not_applicable')::boolean,false) OR nullif(x->'line'->'inspection'->>'expiry_date','') IS NULL
   OR (x->'line'->'inspection'->>'expiry_date')::date<today+(x->'profile'->'criteria'->>'min_remaining_days')::integer)) THEN RAISE EXCEPTION 'QUALITY_REMAINING_SHELF_LIFE_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(inspected)x WHERE (x->>'accepted')::numeric>0 AND (x->'profile'->'criteria'->>'photo_required')::boolean
  AND (jsonb_typeof(x->'line'->'inspection'->'photo_paths') IS DISTINCT FROM 'array' OR jsonb_array_length(x->'line'->'inspection'->'photo_paths')=0)) THEN RAISE EXCEPTION 'QUALITY_PHOTO_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(inspected)x CROSS JOIN LATERAL jsonb_array_elements_text(x->'line'->'inspection'->'photo_paths')photo(path)
 LEFT JOIN storage.objects o ON o.bucket_id='inventory-receipt-statements' AND o.name=photo.path
 WHERE (x->>'accepted')::numeric>0 AND (x->'profile'->'criteria'->>'photo_required')::boolean AND coalesce(lower(o.metadata->>'mimetype'),'') NOT IN('image/jpeg','image/png')) THEN RAISE EXCEPTION 'QUALITY_PHOTO_REQUIRED'; END IF;

END $$;
REVOKE ALL ON FUNCTION public.store_capture_order_quality_v1(),public.procurement_effective_quality_v1(uuid[]),public.procurement_enrich_quality_lines_v1(uuid,jsonb),public.procurement_validate_inspection_batch(uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;

DO $$ DECLARE d text; BEGIN
 d:=pg_get_functiondef('public.submit_inventory_receipt_batch(uuid,uuid,integer,integer,text,jsonb,text,text,text,date,text)'::regprocedure);
 IF position('IF v_order.workflow_version=2 AND v_order.procurement_status' IN d)=0 THEN RAISE EXCEPTION 'QUALITY_SUBMISSION_PATCH_MISMATCH'; END IF;
 d:=replace(d,'IF v_order.workflow_version=2 AND v_order.procurement_status','p_lines:=public.procurement_enrich_quality_lines_v1(v_order.restaurant_id,p_lines); IF v_order.workflow_version=2 AND v_order.procurement_status');
 EXECUTE d;
 d:=pg_get_functiondef('public.store_procurement_readiness_v1(uuid[])'::regprocedure);
 IF position('catalog AS(' IN d)=0 OR position('LEFT JOIN policy ON' IN d)=0 THEN RAISE EXCEPTION 'QUALITY_READINESS_PATCH_MISMATCH'; END IF;
 d:=replace(d,'catalog AS(', 'quality AS(SELECT p.restaurant_id,bool_and(q.product_id IS NOT NULL) ready FROM inventory_products p LEFT JOIN (SELECT DISTINCT product_id FROM procurement_quality_profiles WHERE restaurant_id=ANY(p_stores))q ON q.product_id=p.id WHERE p.restaurant_id=ANY(p_stores) AND p.is_active AND p.is_orderable GROUP BY p.restaurant_id), catalog AS(');
 d:=replace(d,'''catalog'',coalesce(catalog.total>0', '''quality'',coalesce(quality.ready,false),''catalog'',coalesce(catalog.total>0');
 d:=replace(d,'LEFT JOIN policy ON', 'LEFT JOIN quality ON quality.restaurant_id=shop.id LEFT JOIN policy ON');
 EXECUTE d;
 d:=pg_get_functiondef('public.admin_get_procurement_setup_v1(uuid,uuid,integer)'::regprocedure);
 d:=replace(d,'approvals AS(', 'quality AS(SELECT DISTINCT ON(product_id) * FROM procurement_quality_profiles WHERE product_id=ANY(ids) ORDER BY product_id,revision DESC), approvals AS(');
 d:=replace(d,'''approval'',to_jsonb(a)', '''approval'',to_jsonb(a),''quality'',to_jsonb(q)');
 d:=replace(d,'LEFT JOIN approvals a ON a.product_id=p.id', 'LEFT JOIN approvals a ON a.product_id=p.id LEFT JOIN quality q ON q.product_id=p.id');
 IF position('LEFT JOIN quality q' IN d)=0 THEN RAISE EXCEPTION 'QUALITY_SETUP_PATCH_MISMATCH'; END IF;
 EXECUTE d;
END $$;

ALTER FUNCTION public.get_inventory_workflow_detail(uuid) RENAME TO get_inventory_workflow_detail_before_quality;
REVOKE ALL ON FUNCTION public.get_inventory_workflow_detail_before_quality(uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.get_inventory_workflow_detail(p_purchase_order_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb; ids uuid[]; lines jsonb;
BEGIN
 result:=get_inventory_workflow_detail_before_quality(p_purchase_order_id);
 SELECT array_agg(id) INTO ids FROM inventory_purchase_order_lines WHERE purchase_order_id=p_purchase_order_id;
 SELECT coalesce(jsonb_agg(l.value||jsonb_build_object('quality',to_jsonb(q)) ORDER BY l.ordinality),'[]') INTO lines
 FROM jsonb_array_elements(result->'lines') WITH ORDINALITY l(value,ordinality) LEFT JOIN procurement_effective_quality_v1(ids)q ON q.order_line_id=(l.value->>'id')::uuid;
 RETURN jsonb_set(result,'{lines}',lines)||jsonb_build_object('inspection_employees',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'name',full_name) ORDER BY employee_number) FROM (SELECT e.id,e.full_name,e.employee_number FROM store_employees e JOIN inventory_purchase_orders o ON o.restaurant_id=e.store_id WHERE o.id=p_purchase_order_id AND e.is_active ORDER BY e.employee_number LIMIT 200)e),'[]'));

END $$;
REVOKE ALL ON FUNCTION public.admin_publish_quality_profile_v1(uuid,uuid,uuid,integer,jsonb,text),public.admin_amend_order_quality_v1(uuid,uuid,uuid,text),public.get_inventory_workflow_detail(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_publish_quality_profile_v1(uuid,uuid,uuid,integer,jsonb,text),public.admin_amend_order_quality_v1(uuid,uuid,uuid,text),public.get_inventory_workflow_detail(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_inventory_workflow_detail(uuid) TO service_role;

CREATE FUNCTION public.store_guard_order_quality_identity_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM new_quality_lines n JOIN old_quality_lines prior ON prior.id=n.id JOIN procurement_order_quality q ON q.order_line_id=n.id
 WHERE (n.product_id,n.supplier_item_id,n.base_unit_snapshot,n.receipt_classification_snapshot) IS DISTINCT FROM(prior.product_id,prior.supplier_item_id,prior.base_unit_snapshot,prior.receipt_classification_snapshot)) THEN RAISE EXCEPTION 'QUALITY_PO_IDENTITY_IMMUTABLE'; END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER store_guard_order_quality_identity AFTER UPDATE ON public.inventory_purchase_order_lines REFERENCING OLD TABLE AS old_quality_lines NEW TABLE AS new_quality_lines FOR EACH STATEMENT EXECUTE FUNCTION public.store_guard_order_quality_identity_v1();
REVOKE ALL ON FUNCTION public.store_guard_order_quality_identity_v1() FROM PUBLIC,anon,authenticated,service_role;

COMMIT;
