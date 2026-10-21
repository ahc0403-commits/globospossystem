-- New-store procurement setup is explicit and versioned. Existing policies and
-- issued policy-1/2/3 documents retain their current contracts.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.procurement_policy_templates (
 id uuid PRIMARY KEY, name text NOT NULL CHECK(length(btrim(name)) BETWEEN 1 AND 100),
 revision integer NOT NULL CHECK(revision>0),family_id uuid NOT NULL,
 policy jsonb NOT NULL,approved_by uuid NOT NULL,approved_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(family_id,revision)
);
CREATE TABLE public.procurement_material_specs (
 id uuid PRIMARY KEY,code text NOT NULL CHECK(code~'^[A-Z0-9][A-Z0-9_-]{1,39}$'),revision integer NOT NULL CHECK(revision>0),
 name text NOT NULL CHECK(length(btrim(name)) BETWEEN 1 AND 160),base_unit text NOT NULL CHECK(base_unit IN('g','ml','ea')),
 specification text NOT NULL CHECK(length(btrim(specification)) BETWEEN 1 AND 2000),approved_by uuid NOT NULL,approved_at timestamptz NOT NULL DEFAULT now(),UNIQUE(code,revision)
);
CREATE TABLE public.store_procurement_profiles (
 restaurant_id uuid PRIMARY KEY REFERENCES public.restaurants(id) ON DELETE CASCADE,
 template_id uuid NOT NULL REFERENCES public.procurement_policy_templates(id),revision bigint NOT NULL,enforced boolean NOT NULL DEFAULT false,
 applied_by uuid NOT NULL,applied_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.procurement_catalog_approvals (
 id uuid PRIMARY KEY,restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
 product_id uuid NOT NULL REFERENCES public.inventory_products(id) ON DELETE CASCADE,
 supplier_item_id uuid NOT NULL REFERENCES public.inventory_supplier_items(id),spec_id uuid NOT NULL REFERENCES public.procurement_material_specs(id),
 valid_from timestamptz NOT NULL,valid_until timestamptz,source_reference text NOT NULL,
 catalog_snapshot jsonb NOT NULL,approved_by uuid NOT NULL,approved_at timestamptz NOT NULL DEFAULT now(),
 CHECK(valid_until IS NULL OR valid_until>valid_from),CHECK(length(btrim(source_reference)) BETWEEN 1 AND 500)
);
CREATE INDEX procurement_catalog_approvals_product ON public.procurement_catalog_approvals(restaurant_id,product_id,approved_at DESC);
ALTER TABLE public.procurement_policy_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.procurement_material_specs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_procurement_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.procurement_catalog_approvals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_policy_templates,public.procurement_material_specs,public.store_procurement_profiles,public.procurement_catalog_approvals FROM PUBLIC,anon,authenticated;
CREATE TRIGGER procurement_policy_templates_immutable BEFORE UPDATE ON public.procurement_policy_templates FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE TRIGGER procurement_material_specs_immutable BEFORE UPDATE ON public.procurement_material_specs FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE TRIGGER procurement_catalog_approvals_immutable BEFORE UPDATE ON public.procurement_catalog_approvals FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();

CREATE FUNCTION public.procurement_catalog_snapshot_v1(p public.inventory_products,s public.inventory_supplier_items) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('product_code',p.product_code,'name',p.name,'specification',p.specification,'inventory_item_id',p.inventory_item_id,
  'base_unit',p.base_unit,'stock_unit',p.stock_unit,'base_unit_factor',p.base_unit_factor,'receipt_classification',p.receipt_classification,
  'storage_type',p.storage_type,'shelf_life_days',p.shelf_life_days,'supplier_id',s.supplier_id,'supplier_sku',s.supplier_sku,
  'order_unit',s.order_unit,'order_unit_quantity_base',s.order_unit_quantity_base,'min_order_quantity',s.min_order_quantity,
  'unit_price',s.unit_price,'tax_rate',s.tax_rate,'lead_time_days',s.lead_time_days);
$$;
REVOKE ALL ON FUNCTION public.procurement_catalog_snapshot_v1(public.inventory_products,public.inventory_supplier_items) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.admin_publish_procurement_template_v1(p_id uuid,p_family uuid,p_expected_revision integer,p_name text,p_policy jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE prior procurement_policy_templates; expected jsonb;
BEGIN
 PERFORM require_brand_admin_v1();
 IF p_id IS NULL OR p_family IS NULL OR p_expected_revision IS NULL OR p_expected_revision<0 OR length(btrim(coalesce(p_name,''))) NOT BETWEEN 1 AND 100
 OR jsonb_typeof(p_policy) IS DISTINCT FROM 'object' OR octet_length(p_policy::text)>2048
 OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_policy)k WHERE k NOT IN('stock_freshness_hours','high_value_amount','max_price_increase_percent','quantity_review_multiplier')) THEN RAISE EXCEPTION 'PROCUREMENT_TEMPLATE_INVALID'; END IF;
 IF coalesce((p_policy->>'stock_freshness_hours')::integer,0) NOT BETWEEN 1 AND 720
 OR (p_policy->>'high_value_amount')::numeric<=0 OR (p_policy->>'max_price_increase_percent')::numeric<0 OR (p_policy->>'quantity_review_multiplier')::numeric<1
 OR EXISTS(SELECT 1 FROM jsonb_each_text(p_policy)v WHERE v.value IN('NaN','Infinity','-Infinity')) THEN RAISE EXCEPTION 'PROCUREMENT_TEMPLATE_INVALID'; END IF;
 expected:=jsonb_build_object('approval_policy_version',3,'two_stage_required',true,'three_stage_required',false,'stock_freshness_hours',(p_policy->>'stock_freshness_hours')::integer,
  'high_value_amount',(p_policy->>'high_value_amount')::numeric,'max_price_increase_percent',(p_policy->>'max_price_increase_percent')::numeric,'quantity_review_multiplier',(p_policy->>'quantity_review_multiplier')::numeric);
 PERFORM pg_advisory_xact_lock(hashtextextended('procurement-template:'||p_family,0));
 SELECT * INTO prior FROM procurement_policy_templates WHERE id=p_id;
 IF FOUND THEN
  IF prior.family_id<>p_family OR prior.revision<>p_expected_revision+1 OR prior.name<>btrim(p_name) OR prior.policy<>expected OR prior.approved_by<>auth.uid() THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF;
  RETURN to_jsonb(prior);
 END IF;
 IF coalesce((SELECT max(revision) FROM procurement_policy_templates WHERE family_id=p_family),0)<>p_expected_revision THEN RAISE EXCEPTION 'PROCUREMENT_TEMPLATE_STALE'; END IF;
 INSERT INTO procurement_policy_templates VALUES(p_id,btrim(p_name),p_expected_revision+1,p_family,expected,auth.uid(),now()) RETURNING * INTO prior;
 RETURN to_jsonb(prior);
END $$;

CREATE FUNCTION public.admin_publish_material_spec_v1(p_id uuid,p_code text,p_expected_revision integer,p_name text,p_base_unit text,p_specification text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE prior procurement_material_specs;
BEGIN
 PERFORM require_brand_admin_v1();
 IF p_id IS NULL OR p_expected_revision IS NULL OR p_expected_revision<0 OR p_code IS NULL THEN RAISE EXCEPTION 'MATERIAL_SPEC_INVALID'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('material-spec:'||p_code,0));
 SELECT * INTO prior FROM procurement_material_specs WHERE id=p_id;
 IF FOUND THEN
  IF (prior.code,prior.revision,prior.name,prior.base_unit,prior.specification,prior.approved_by) IS DISTINCT FROM (p_code,p_expected_revision+1,btrim(p_name),p_base_unit,btrim(p_specification),auth.uid()) THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF;
  RETURN to_jsonb(prior);
 END IF;
 IF coalesce((SELECT max(revision) FROM procurement_material_specs WHERE code=p_code),0)<>p_expected_revision THEN RAISE EXCEPTION 'MATERIAL_SPEC_STALE'; END IF;
 INSERT INTO procurement_material_specs VALUES(p_id,p_code,p_expected_revision+1,btrim(p_name),p_base_unit,btrim(p_specification),auth.uid(),now()) RETURNING * INTO prior;
 RETURN to_jsonb(prior);
END $$;

CREATE FUNCTION public.admin_apply_procurement_template_v1(p_store uuid,p_template uuid,p_expected_revision bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE t procurement_policy_templates; profile store_procurement_profiles;
BEGIN
 PERFORM require_brand_admin_v1();
 PERFORM pg_advisory_xact_lock(hashtextextended('store-procurement:'||p_store,0));
 SELECT * INTO t FROM procurement_policy_templates WHERE id=p_template;
 IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_TEMPLATE_REQUIRED'; END IF;
 SELECT * INTO profile FROM store_procurement_profiles WHERE restaurant_id=p_store;
 IF profile.template_id=p_template AND profile.revision=p_expected_revision+1 THEN RETURN to_jsonb(profile); END IF;
 IF coalesce(profile.revision,0) IS DISTINCT FROM p_expected_revision THEN RAISE EXCEPTION 'PROCUREMENT_PROFILE_STALE'; END IF;
 IF EXISTS(SELECT 1 FROM store_lifecycle WHERE restaurant_id=p_store AND state='closed') THEN RAISE EXCEPTION 'STORE_CLOSED'; END IF;
 INSERT INTO procurement_store_policies(restaurant_id,enabled,two_stage_required,three_stage_required,new_requests_enabled,stock_freshness_hours,high_value_amount,max_price_increase_percent,quantity_review_multiplier)
 VALUES(p_store,true,true,false,true,(t.policy->>'stock_freshness_hours')::int,(t.policy->>'high_value_amount')::numeric,(t.policy->>'max_price_increase_percent')::numeric,(t.policy->>'quantity_review_multiplier')::numeric)
 ON CONFLICT(restaurant_id) DO UPDATE SET enabled=true,two_stage_required=true,three_stage_required=false,new_requests_enabled=true,stock_freshness_hours=EXCLUDED.stock_freshness_hours,
 high_value_amount=EXCLUDED.high_value_amount,max_price_increase_percent=EXCLUDED.max_price_increase_percent,quantity_review_multiplier=EXCLUDED.quantity_review_multiplier,row_version=procurement_store_policies.row_version+1,updated_at=now();
 INSERT INTO store_procurement_profiles(restaurant_id,template_id,revision,applied_by,applied_at) VALUES(p_store,p_template,p_expected_revision+1,auth.uid(),now())
 ON CONFLICT(restaurant_id) DO UPDATE SET template_id=EXCLUDED.template_id,revision=EXCLUDED.revision,applied_by=EXCLUDED.applied_by,applied_at=EXCLUDED.applied_at RETURNING * INTO profile;
 RETURN to_jsonb(profile);
END $$;

CREATE FUNCTION public.admin_approve_procurement_catalog_v1(p_store uuid,p_rows jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb;
BEGIN
 PERFORM require_brand_admin_v1();
 IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) NOT BETWEEN 1 AND 100 OR octet_length(p_rows::text)>131072 THEN RAISE EXCEPTION 'PROCUREMENT_CATALOG_BATCH_LIMIT'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('store-procurement:'||p_store,0));
 IF EXISTS(SELECT 1 FROM jsonb_to_recordset(p_rows)x(id uuid,product_id uuid,supplier_item_id uuid,spec_id uuid,valid_from timestamptz,valid_until timestamptz,source_reference text)
 LEFT JOIN inventory_products p ON p.id=x.product_id AND p.restaurant_id=p_store AND p.is_active AND p.is_orderable
 LEFT JOIN restaurants catalog_store ON catalog_store.id=p.restaurant_id
 LEFT JOIN inventory_supplier_items s ON s.id=x.supplier_item_id AND s.product_id=p.id AND s.is_active
 LEFT JOIN inventory_suppliers supplier ON supplier.id=s.supplier_id AND supplier.status='active' AND (supplier.brand_id IS NULL OR supplier.brand_id=catalog_store.brand_id)
 LEFT JOIN procurement_material_specs spec ON spec.id=x.spec_id AND spec.base_unit=p.base_unit
 LEFT JOIN inventory_items item ON item.id=p.inventory_item_id AND item.restaurant_id=p_store
 WHERE x.id IS NULL OR p.id IS NULL OR s.id IS NULL OR supplier.id IS NULL OR spec.id IS NULL OR x.valid_from IS NULL
 OR (x.valid_until IS NOT NULL AND x.valid_until<=x.valid_from) OR length(btrim(coalesce(x.source_reference,''))) NOT BETWEEN 1 AND 500
 OR nullif(btrim(p.product_code),'') IS NULL OR nullif(btrim(p.specification),'') IS NULL OR nullif(btrim(s.order_unit),'') IS NULL
 OR (p.receipt_classification='stock' AND item.id IS NULL)) THEN RAISE EXCEPTION 'PROCUREMENT_CATALOG_INCOMPLETE'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_to_recordset(p_rows)x(id uuid,product_id uuid,supplier_item_id uuid,spec_id uuid,valid_from timestamptz,valid_until timestamptz,source_reference text)
 JOIN inventory_products p ON p.id=x.product_id JOIN inventory_supplier_items s ON s.id=x.supplier_item_id JOIN procurement_catalog_approvals a ON a.id=x.id
 WHERE (a.restaurant_id,a.product_id,a.supplier_item_id,a.spec_id,a.valid_from,a.valid_until,a.source_reference,a.catalog_snapshot,a.approved_by)
 IS DISTINCT FROM (p_store,x.product_id,x.supplier_item_id,x.spec_id,x.valid_from,x.valid_until,btrim(x.source_reference),procurement_catalog_snapshot_v1(p,s),auth.uid())) THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF;
 INSERT INTO procurement_catalog_approvals(id,restaurant_id,product_id,supplier_item_id,spec_id,valid_from,valid_until,source_reference,catalog_snapshot,approved_by)
 SELECT x.id,p_store,x.product_id,x.supplier_item_id,x.spec_id,x.valid_from,x.valid_until,btrim(x.source_reference),procurement_catalog_snapshot_v1(p,s),auth.uid()
 FROM jsonb_to_recordset(p_rows)x(id uuid,product_id uuid,supplier_item_id uuid,spec_id uuid,valid_from timestamptz,valid_until timestamptz,source_reference text)
 JOIN inventory_products p ON p.id=x.product_id JOIN inventory_supplier_items s ON s.id=x.supplier_item_id ON CONFLICT(id) DO NOTHING;
 SELECT jsonb_agg(to_jsonb(a) ORDER BY a.product_id) INTO result FROM procurement_catalog_approvals a JOIN jsonb_to_recordset(p_rows)x(id uuid) ON x.id=a.id;
 RETURN result;
END $$;

CREATE FUNCTION public.store_procurement_readiness_v1(p_stores uuid[]) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb;
BEGIN
 IF p_stores IS NULL OR cardinality(p_stores) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'PROCUREMENT_BATCH_LIMIT'; END IF;
 IF EXISTS(SELECT restaurant_id FROM inventory_products WHERE restaurant_id=ANY(p_stores) GROUP BY restaurant_id HAVING count(*)>2000) THEN RAISE EXCEPTION 'PROCUREMENT_CATALOG_LIMIT_2000'; END IF;
 WITH shops AS MATERIALIZED(SELECT r.id,r.is_active,coalesce(l.state,'closed') lifecycle FROM restaurants r LEFT JOIN store_lifecycle l ON l.restaurant_id=r.id WHERE r.id=ANY(p_stores)),
 valid_pos AS MATERIALIZED(SELECT DISTINCT rr.restaurant_id,rr.stage FROM procurement_role_roster rr JOIN users u ON u.auth_id=rr.subject_id AND u.is_active JOIN auth.users au ON au.id=u.auth_id
 JOIN user_store_access access ON access.user_id=u.id AND access.store_id=rr.restaurant_id AND access.is_active
 WHERE rr.restaurant_id=ANY(p_stores) AND rr.system='pos' AND rr.valid_from<=now() AND rr.valid_until>now()
 AND ((rr.stage IN('requester','receiver','verifier') AND u.role='inventory_orderer') OR (rr.stage='store' AND u.role='store_admin') OR (rr.stage='finance' AND u.role='inventory_accounting'))
 UNION SELECT DISTINCT a.store_id,'finance' FROM user_store_access a JOIN users u ON u.id=a.user_id AND u.is_active AND u.role='inventory_accounting' JOIN auth.users au ON au.id=u.auth_id
 WHERE a.store_id=ANY(p_stores) AND a.is_active),
 valid_office AS MATERIALIZED(SELECT restaurant_id,stage FROM procurement_role_roster WHERE restaurant_id=ANY(p_stores) AND system='office' AND stage IN('purchase','finance') AND valid_from<=now() AND valid_until>now()),
 stages AS(SELECT restaurant_id,stage FROM valid_pos UNION SELECT restaurant_id,stage FROM valid_office),
 valid_catalog AS MATERIALIZED(SELECT DISTINCT p.id FROM inventory_products p JOIN restaurants catalog_store ON catalog_store.id=p.restaurant_id JOIN procurement_catalog_approvals a ON a.product_id=p.id AND a.restaurant_id=p.restaurant_id
 JOIN inventory_supplier_items s ON s.id=a.supplier_item_id AND s.product_id=p.id AND s.is_active JOIN inventory_suppliers supplier ON supplier.id=s.supplier_id AND supplier.status='active' AND (supplier.brand_id IS NULL OR supplier.brand_id=catalog_store.brand_id)
 JOIN procurement_material_specs spec ON spec.id=a.spec_id AND spec.base_unit=p.base_unit
 WHERE p.restaurant_id=ANY(p_stores) AND a.valid_from<=now() AND (a.valid_until IS NULL OR a.valid_until>now()) AND a.catalog_snapshot=procurement_catalog_snapshot_v1(p,s)),
 catalog AS(SELECT p.restaurant_id,count(*) total,count(*) FILTER(WHERE valid.id IS NULL) missing FROM inventory_products p LEFT JOIN valid_catalog valid ON valid.id=p.id WHERE p.restaurant_id=ANY(p_stores) AND p.is_active AND p.is_orderable GROUP BY p.restaurant_id),
 policy AS(SELECT profile.restaurant_id,profile.revision,profile.template_id,profile.enforced,
  p.enabled AND p.two_stage_required AND NOT p.three_stage_required AND p.new_requests_enabled
  AND (p.stock_freshness_hours,p.high_value_amount,p.max_price_increase_percent,p.quantity_review_multiplier)
  IS NOT DISTINCT FROM ((t.policy->>'stock_freshness_hours')::integer,(t.policy->>'high_value_amount')::numeric,(t.policy->>'max_price_increase_percent')::numeric,(t.policy->>'quantity_review_multiplier')::numeric) valid
 FROM store_procurement_profiles profile JOIN procurement_policy_templates t ON t.id=profile.template_id JOIN procurement_store_policies p ON p.restaurant_id=profile.restaurant_id WHERE profile.restaurant_id=ANY(p_stores)),
 stage_summary AS(SELECT restaurant_id,jsonb_object_agg(stage,true) roles FROM stages GROUP BY restaurant_id),
 checks AS(SELECT shop.id,policy.revision,policy.template_id,coalesce(policy.enforced,false) enforced,coalesce(catalog.total,0) product_count,coalesce(catalog.missing,0) missing_catalog,
 jsonb_build_object('store_open_for_procurement',shop.is_active AND shop.lifecycle<>'closed','policy',coalesce(policy.valid,false),
 'requester',coalesce(roles?'requester',false),'store_manager',coalesce(roles?'store',false),'receiver',coalesce(roles?'receiver',false),'verifier',coalesce(roles?'verifier',false),
 'buyer',coalesce(roles?'purchase',false),'accounting',coalesce(roles?'finance',false),
 'office_connected',coalesce(o.office_connected,false),'catalog',coalesce(catalog.total>0 AND catalog.missing=0,false)) checks
 FROM shops shop LEFT JOIN policy ON policy.restaurant_id=shop.id LEFT JOIN catalog ON catalog.restaurant_id=shop.id LEFT JOIN stage_summary ON stage_summary.restaurant_id=shop.id LEFT JOIN procurement_store_onboarding o ON o.restaurant_id=shop.id)
 SELECT jsonb_agg(to_jsonb(c)||jsonb_build_object('ready',NOT EXISTS(SELECT 1 FROM jsonb_each(c.checks)v WHERE v.value<>'true'::jsonb)) ORDER BY id) INTO result FROM checks c;
 RETURN coalesce(result,'[]');
END $$;
REVOKE ALL ON FUNCTION public.store_procurement_readiness_v1(uuid[]) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.admin_get_procurement_setup_v1(p_store uuid,p_after uuid DEFAULT NULL,p_limit integer DEFAULT 100) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE rows jsonb; ids uuid[];
BEGIN
 PERFORM require_admin_actor_for_restaurant(p_store);
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'PROCUREMENT_PAGE_LIMIT'; END IF;
 SELECT array_agg(id) INTO ids FROM(SELECT id FROM inventory_products WHERE restaurant_id=p_store AND (p_after IS NULL OR id>p_after) ORDER BY id LIMIT p_limit)p;
 WITH suppliers AS(SELECT s.product_id,jsonb_agg(to_jsonb(s)||jsonb_build_object('supplier_name',supplier.supplier_name) ORDER BY s.id) rows FROM inventory_supplier_items s JOIN inventory_suppliers supplier ON supplier.id=s.supplier_id WHERE s.product_id=ANY(ids) AND s.is_active GROUP BY s.product_id),
 approvals AS(SELECT DISTINCT ON(product_id) * FROM procurement_catalog_approvals WHERE product_id=ANY(ids) ORDER BY product_id,approved_at DESC,id)
 SELECT coalesce(jsonb_agg(to_jsonb(p)||jsonb_build_object('suppliers',coalesce(s.rows,'[]'),'approval',to_jsonb(a)) ORDER BY p.id),'[]') INTO rows FROM inventory_products p LEFT JOIN suppliers s ON s.product_id=p.id LEFT JOIN approvals a ON a.product_id=p.id WHERE p.id=ANY(ids);
 RETURN jsonb_build_object('readiness',store_procurement_readiness_v1(ARRAY[p_store])->0,'products',rows,
  'templates',coalesce((SELECT jsonb_agg(to_jsonb(t) ORDER BY approved_at DESC,id) FROM(SELECT * FROM procurement_policy_templates ORDER BY approved_at DESC,id LIMIT 100)t),'[]'),
  'specs',coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY code,revision DESC) FROM(SELECT * FROM procurement_material_specs ORDER BY approved_at DESC,id LIMIT 200)s),'[]'));
END $$;

CREATE FUNCTION public.store_guard_procurement_intake_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE ids uuid[]; readiness jsonb;
BEGIN
 IF TG_OP='UPDATE' THEN
  SELECT array_agg(DISTINCT n.restaurant_id) INTO ids FROM new_procurement n JOIN old_procurement before_row ON before_row.id=n.id
  WHERE n.status IS DISTINCT FROM before_row.status AND n.status IN('submitted','office_review','approved','allocated')
  AND (EXISTS(SELECT 1 FROM store_registration_requests q WHERE q.store_id=n.restaurant_id) OR EXISTS(SELECT 1 FROM store_procurement_profiles p WHERE p.restaurant_id=n.restaurant_id AND p.enforced));
 ELSE
 SELECT array_agg(DISTINCT n.restaurant_id) INTO ids FROM new_procurement n WHERE
 (EXISTS(SELECT 1 FROM store_registration_requests q WHERE q.store_id=n.restaurant_id) OR EXISTS(SELECT 1 FROM store_procurement_profiles p WHERE p.restaurant_id=n.restaurant_id AND p.enforced));
 END IF;
 IF ids IS NULL THEN RETURN NULL; END IF;
 -- Insert batches are bounded; no store-by-store readiness queries.
 readiness:=store_procurement_readiness_v1(ids);
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(readiness)r WHERE r->>'ready'<>'true') THEN RAISE EXCEPTION 'STORE_PROCUREMENT_NOT_READY'; END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER store_guard_procurement_intake AFTER INSERT ON public.inventory_purchase_requests REFERENCING NEW TABLE AS new_procurement FOR EACH STATEMENT EXECUTE FUNCTION public.store_guard_procurement_intake_v1();
CREATE TRIGGER store_guard_procurement_progress AFTER UPDATE ON public.inventory_purchase_requests REFERENCING OLD TABLE AS old_procurement NEW TABLE AS new_procurement FOR EACH STATEMENT EXECUTE FUNCTION public.store_guard_procurement_intake_v1();
REVOKE ALL ON FUNCTION public.store_guard_procurement_intake_v1() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.admin_publish_procurement_template_v1(uuid,uuid,integer,text,jsonb),public.admin_publish_material_spec_v1(uuid,text,integer,text,text,text),public.admin_apply_procurement_template_v1(uuid,uuid,bigint),public.admin_approve_procurement_catalog_v1(uuid,jsonb),public.admin_get_procurement_setup_v1(uuid,uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_publish_procurement_template_v1(uuid,uuid,integer,text,jsonb),public.admin_publish_material_spec_v1(uuid,text,integer,text,text,text),public.admin_apply_procurement_template_v1(uuid,uuid,bigint),public.admin_approve_procurement_catalog_v1(uuid,jsonb),public.admin_get_procurement_setup_v1(uuid,uuid,integer) TO authenticated;

CREATE FUNCTION public.admin_activate_procurement_profile_v1(p_store uuid,p_expected_revision bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE ready jsonb; profile store_procurement_profiles;
BEGIN
 PERFORM require_brand_admin_v1();
 PERFORM pg_advisory_xact_lock(hashtextextended('store-procurement:'||p_store,0));
 SELECT * INTO profile FROM store_procurement_profiles WHERE restaurant_id=p_store FOR UPDATE;
 IF profile.restaurant_id IS NULL OR profile.revision IS DISTINCT FROM p_expected_revision THEN RAISE EXCEPTION 'PROCUREMENT_PROFILE_STALE'; END IF;
 ready:=store_procurement_readiness_v1(ARRAY[p_store])->0;
 IF ready->>'ready' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'STORE_PROCUREMENT_NOT_READY'; END IF;
 UPDATE store_procurement_profiles SET enforced=true WHERE restaurant_id=p_store RETURNING * INTO profile;
 RETURN to_jsonb(profile);
END $$;
REVOKE ALL ON FUNCTION public.admin_activate_procurement_profile_v1(uuid,bigint) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_activate_procurement_profile_v1(uuid,bigint) TO authenticated;

COMMIT;
