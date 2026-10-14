BEGIN;
-- production-gate: self-verifying
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='120s';
CREATE SCHEMA IF NOT EXISTS pos_invoice_private;
REVOKE ALL ON SCHEMA pos_invoice_private FROM PUBLIC,anon,authenticated,service_role;
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;

CREATE TABLE public.invoice_mapping_policies(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 store_id uuid NOT NULL REFERENCES public.restaurants(id),
 tax_entity_id uuid NOT NULL REFERENCES public.tax_entity(id),
 policy_version text NOT NULL CHECK(length(btrim(policy_version)) BETWEEN 1 AND 80),
 rules jsonb NOT NULL CHECK(jsonb_typeof(rules)='object'),
 source_reference text NOT NULL CHECK(length(btrim(source_reference)) BETWEEN 1 AND 350),
 approved_by uuid NOT NULL,approved_at timestamptz NOT NULL DEFAULT statement_timestamp(),
 effective_from timestamptz NOT NULL DEFAULT statement_timestamp(),effective_to timestamptz,
 UNIQUE(store_id,policy_version),CHECK(effective_to IS NULL OR effective_to>effective_from)
);
CREATE UNIQUE INDEX invoice_mapping_policy_active ON public.invoice_mapping_policies(store_id) WHERE effective_to IS NULL;
ALTER TABLE public.invoice_mapping_policies ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.invoice_mapping_policies FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.invoice_mapping_policies TO authenticated;
CREATE POLICY invoice_mapping_policies_read ON public.invoice_mapping_policies FOR SELECT TO authenticated USING(public.is_super_admin());
ALTER TABLE public.menu_items ADD COLUMN invoice_sale_unit text CHECK(invoice_sale_unit IS NULL OR length(btrim(invoice_sale_unit)) BETWEEN 1 AND 40);
ALTER TABLE public.menu_invoice_profiles ADD COLUMN policy_id uuid REFERENCES public.invoice_mapping_policies(id),ADD COLUMN recorded_by uuid;
ALTER TABLE public.menu_invoice_profiles ADD COLUMN unit_override boolean NOT NULL DEFAULT true;
COMMENT ON COLUMN public.menu_invoice_profiles.unit_override IS 'Actual individually approved unit survives subsequent name edits; category policy units may follow category/combo changes.';
COMMENT ON COLUMN public.menu_invoice_profiles.approved_by IS 'Actual manual approver, or actual approver of policy_id for an automatic policy application.';
COMMENT ON COLUMN public.menu_invoice_profiles.recorded_by IS 'Authenticated actor performing this policy application; approved_at is the actual recording time.';
-- Indexed exclusion constraints validate complete periods and concurrent writes
-- without a table lookup for each inserted profile. NULL is an infinite bound.
DROP TRIGGER menu_invoice_profile_period ON public.menu_invoice_profiles;
DROP TRIGGER item_type_invoice_profile_period ON public.item_type_invoice_profiles;
ALTER TABLE public.menu_invoice_profiles ADD CONSTRAINT menu_invoice_period_exclusion EXCLUDE USING gist(menu_item_id WITH =,tstzrange(effective_from,effective_to,'[)') WITH &&);
ALTER TABLE public.item_type_invoice_profiles ADD CONSTRAINT item_invoice_period_exclusion EXCLUDE USING gist(store_id WITH =,tax_entity_id WITH =,item_type WITH =,tstzrange(effective_from,effective_to,'[)') WITH &&);
CREATE FUNCTION pos_invoice_private.write_mapping_batch(p_store_id uuid,p_tax_entity_id uuid,p_rows jsonb,p_policy_id uuid DEFAULT NULL) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb; policy public.invoice_mapping_policies%ROWTYPE; approver uuid;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'INVOICE_PROFILE_FORBIDDEN'; END IF;
 IF p_policy_id IS NULL THEN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'INVOICE_PROFILE_FORBIDDEN'; END IF;
  approver:=auth.uid();
 ELSE
  SELECT * INTO policy FROM public.invoice_mapping_policies WHERE id=p_policy_id AND store_id=p_store_id AND tax_entity_id=p_tax_entity_id AND effective_from<=clock_timestamp() AND effective_to IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVOICE_POLICY_SCOPE_INVALID'; END IF;
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);
  approver:=policy.approved_by;
 END IF;
 IF p_store_id IS NULL OR p_tax_entity_id IS NULL OR jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'INVOICE_PROFILE_BATCH_INVALID'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('invoice-profile:'||p_store_id::text,0));
 IF NOT EXISTS(SELECT 1 FROM public.restaurants WHERE id=p_store_id AND tax_entity_id=p_tax_entity_id) THEN RAISE EXCEPTION 'INVOICE_PROFILE_SCOPE_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_to_recordset(p_rows) x(approval_type text,menu_item_id uuid,item_type text,invoice_name_vi text,unit_name text,mapping_version text,source_reference text,effective_from timestamptz,effective_to timestamptz)
 WHERE approval_type IS NULL OR approval_type NOT IN('menu_item','item_type') OR length(btrim(COALESCE(invoice_name_vi,''))) NOT BETWEEN 1 AND 200
 OR length(btrim(COALESCE(unit_name,''))) NOT BETWEEN 1 AND 40 OR length(btrim(COALESCE(mapping_version,''))) NOT BETWEEN 1 AND 100 OR length(btrim(COALESCE(source_reference,''))) NOT BETWEEN 1 AND 500
 OR effective_from IS NULL OR effective_from>clock_timestamp() OR (effective_to IS NOT NULL AND effective_to<=effective_from)
 OR (approval_type='menu_item' AND (menu_item_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.menu_items m WHERE m.id=x.menu_item_id AND m.restaurant_id=p_store_id)))
 OR (approval_type='item_type' AND (menu_item_id IS NOT NULL OR item_type IS DISTINCT FROM 'wet_tissue_charge')))
 OR (SELECT count(DISTINCT COALESCE(x->>'menu_item_id',x->>'item_type')) FROM jsonb_array_elements(p_rows) x)<>jsonb_array_length(p_rows) THEN RAISE EXCEPTION 'INVOICE_PROFILE_BATCH_INVALID'; END IF;
 -- Close earlier open versions only for a new open-ended approval. Conflicting finite history is rejected by
 -- the indexed exclusion constraint and rolls back the entire batch.
 WITH input AS(SELECT * FROM jsonb_to_recordset(p_rows) x(approval_type text,menu_item_id uuid,effective_from timestamptz,effective_to timestamptz))
 UPDATE public.menu_invoice_profiles p SET effective_to=x.effective_from FROM input x WHERE x.approval_type='menu_item' AND p.menu_item_id=x.menu_item_id AND p.effective_to IS NULL AND p.effective_from<x.effective_from AND x.effective_to IS NULL;
 WITH input AS(SELECT * FROM jsonb_to_recordset(p_rows) x(approval_type text,item_type text,effective_from timestamptz,effective_to timestamptz))
 UPDATE public.item_type_invoice_profiles p SET effective_to=x.effective_from FROM input x WHERE x.approval_type='item_type' AND p.store_id=p_store_id AND p.tax_entity_id=p_tax_entity_id AND p.item_type=x.item_type AND p.effective_to IS NULL AND p.effective_from<x.effective_from AND x.effective_to IS NULL;
 INSERT INTO public.menu_invoice_profiles(menu_item_id,tax_entity_id,invoice_name_vi,unit_name,mapping_version,source_reference,effective_from,effective_to,approved_by,recorded_by,policy_id,unit_override)
 SELECT x.menu_item_id,p_tax_entity_id,btrim(x.invoice_name_vi),btrim(x.unit_name),x.mapping_version,x.source_reference,x.effective_from,x.effective_to,approver,auth.uid(),p_policy_id,CASE WHEN p_policy_id IS NULL THEN true ELSE coalesce(x.unit_override,false) END
 FROM jsonb_to_recordset(p_rows) x(approval_type text,menu_item_id uuid,invoice_name_vi text,unit_name text,mapping_version text,source_reference text,effective_from timestamptz,effective_to timestamptz,unit_override boolean)
 WHERE x.approval_type='menu_item' AND NOT EXISTS(SELECT 1 FROM public.menu_invoice_profiles p WHERE p.menu_item_id=x.menu_item_id AND p.tax_entity_id=p_tax_entity_id AND p.invoice_name_vi=btrim(x.invoice_name_vi) AND p.unit_name=btrim(x.unit_name)
 AND p.mapping_version=x.mapping_version AND p.source_reference=x.source_reference AND p.effective_from=x.effective_from AND p.effective_to IS NOT DISTINCT FROM x.effective_to);
 INSERT INTO public.item_type_invoice_profiles(store_id,tax_entity_id,item_type,invoice_name_vi,unit_name,mapping_version,source_reference,effective_from,effective_to,approved_by)
 SELECT p_store_id,p_tax_entity_id,x.item_type,btrim(x.invoice_name_vi),btrim(x.unit_name),x.mapping_version,x.source_reference,x.effective_from,x.effective_to,approver
 FROM jsonb_to_recordset(p_rows) x(approval_type text,item_type text,invoice_name_vi text,unit_name text,mapping_version text,source_reference text,effective_from timestamptz,effective_to timestamptz)
 WHERE x.approval_type='item_type' AND NOT EXISTS(SELECT 1 FROM public.item_type_invoice_profiles p WHERE p.store_id=p_store_id AND p.tax_entity_id=p_tax_entity_id AND p.item_type=x.item_type AND p.invoice_name_vi=btrim(x.invoice_name_vi) AND p.unit_name=btrim(x.unit_name)
 AND p.mapping_version=x.mapping_version AND p.source_reference=x.source_reference AND p.effective_from=x.effective_from AND p.effective_to IS NOT DISTINCT FROM x.effective_to);
 UPDATE public.menu_items m SET invoice_name_vi=p.invoice_name_vi,invoice_unit_name=p.unit_name FROM(
 SELECT DISTINCT ON(profile.menu_item_id) profile.menu_item_id,profile.invoice_name_vi,profile.unit_name FROM public.menu_invoice_profiles profile
 WHERE profile.tax_entity_id=p_tax_entity_id AND profile.effective_from<=clock_timestamp() AND (profile.effective_to IS NULL OR clock_timestamp()<profile.effective_to)
 AND profile.menu_item_id IN(SELECT (r->>'menu_item_id')::uuid FROM jsonb_array_elements(p_rows) r WHERE r->>'approval_type'='menu_item')
 ORDER BY profile.menu_item_id,profile.effective_from DESC) p WHERE m.id=p.menu_item_id AND m.restaurant_id=p_store_id;
 WITH input AS(SELECT * FROM jsonb_to_recordset(p_rows) x(approval_type text,menu_item_id uuid,item_type text,effective_from timestamptz)), profiles AS(
 SELECT x.approval_type,p.id,p.menu_item_id,NULL::text item_type,p.mapping_version,p.effective_from,p.effective_to FROM input x JOIN public.menu_invoice_profiles p ON x.approval_type='menu_item' AND p.menu_item_id=x.menu_item_id AND p.effective_from=x.effective_from
 UNION ALL SELECT x.approval_type,p.id,NULL::uuid,p.item_type,p.mapping_version,p.effective_from,p.effective_to FROM input x JOIN public.item_type_invoice_profiles p ON x.approval_type='item_type' AND p.store_id=p_store_id AND p.tax_entity_id=p_tax_entity_id AND p.item_type=x.item_type AND p.effective_from=x.effective_from)
 SELECT jsonb_agg(to_jsonb(p) ORDER BY approval_type,COALESCE(menu_item_id::text,item_type)) INTO result FROM profiles p;
 RETURN jsonb_build_object('store_id',p_store_id,'tax_entity_id',p_tax_entity_id,'profiles',result);
EXCEPTION WHEN exclusion_violation THEN RAISE EXCEPTION 'INVOICE_PROFILE_HISTORY_OVERLAP';
END $$;
REVOKE ALL ON FUNCTION pos_invoice_private.write_mapping_batch(uuid,uuid,jsonb,uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.approve_invoice_mapping_batch(p_store_id uuid,p_tax_entity_id uuid,p_rows jsonb) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'INVOICE_PROFILE_FORBIDDEN'; END IF;
 RETURN pos_invoice_private.write_mapping_batch(p_store_id,p_tax_entity_id,p_rows);
END $$;
CREATE OR REPLACE FUNCTION public.approve_menu_invoice_profile(p_menu_item_id uuid,p_name text,p_unit text,p_effective_from timestamptz DEFAULT now()) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
BEGIN
 PERFORM public.approve_menu_invoice_profile_v3(p_menu_item_id,p_name,p_unit,p_effective_from,NULL,
 'manual-'||md5(p_menu_item_id::text||p_name||p_unit||p_effective_from::text),'Menu management authenticated approval');
END $$;

CREATE FUNCTION public.approve_invoice_mapping_policy(p_store_id uuid,p_tax_entity_id uuid,p_policy_version text,p_rules jsonb,p_source_reference text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE existing public.invoice_mapping_policies%ROWTYPE; result public.invoice_mapping_policies%ROWTYPE; recorded_at timestamptz;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'INVOICE_PROFILE_FORBIDDEN'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('invoice-profile:'||p_store_id::text,0));
 IF NOT EXISTS(SELECT 1 FROM public.restaurants WHERE id=p_store_id AND tax_entity_id=p_tax_entity_id) THEN RAISE EXCEPTION 'INVOICE_PROFILE_SCOPE_INVALID'; END IF;
 IF jsonb_typeof(p_rules) IS DISTINCT FROM 'object' OR length(COALESCE(p_rules::text,''))>100000
 OR jsonb_typeof(p_rules->'category_units') IS DISTINCT FROM 'object' OR jsonb_typeof(p_rules->'menu_units') IS DISTINCT FROM 'object'
 OR EXISTS(SELECT 1 FROM jsonb_each(p_rules->'category_units') x LEFT JOIN public.menu_categories c ON c.id::text=x.key AND c.restaurant_id=p_store_id WHERE c.id IS NULL OR jsonb_typeof(x.value)<>'string' OR length(btrim(x.value#>>'{}')) NOT BETWEEN 1 AND 40)
 OR EXISTS(SELECT 1 FROM jsonb_each(p_rules->'menu_units') x LEFT JOIN public.menu_items m ON m.id::text=x.key AND m.restaurant_id=p_store_id WHERE m.id IS NULL OR jsonb_typeof(x.value)<>'string' OR length(btrim(x.value#>>'{}')) NOT BETWEEN 1 AND 40)
 OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_rules) k WHERE k NOT IN('category_units','menu_units','combo_unit'))
 OR jsonb_typeof(p_rules->'combo_unit') IS DISTINCT FROM 'string'
 OR length(btrim(COALESCE(p_rules->>'combo_unit',''))) NOT BETWEEN 1 AND 40 THEN RAISE EXCEPTION 'INVOICE_POLICY_RULES_INVALID'; END IF;
 SELECT * INTO existing FROM public.invoice_mapping_policies WHERE store_id=p_store_id AND policy_version=btrim(p_policy_version);
 IF FOUND THEN
  IF existing.tax_entity_id<>p_tax_entity_id OR existing.rules<>p_rules OR existing.source_reference<>btrim(p_source_reference) THEN RAISE EXCEPTION 'INVOICE_POLICY_RETRY_CONFLICT'; END IF;
  RETURN to_jsonb(existing);
 END IF;
 recorded_at:=clock_timestamp();
 UPDATE public.invoice_mapping_policies SET effective_to=recorded_at WHERE store_id=p_store_id AND effective_to IS NULL;
 INSERT INTO public.invoice_mapping_policies(store_id,tax_entity_id,policy_version,rules,source_reference,approved_by,approved_at,effective_from)
 VALUES(p_store_id,p_tax_entity_id,btrim(p_policy_version),p_rules,btrim(p_source_reference),auth.uid(),recorded_at,recorded_at) RETURNING * INTO result;
 RETURN to_jsonb(result);
END $$;
REVOKE ALL ON FUNCTION public.approve_invoice_mapping_policy(uuid,uuid,text,jsonb,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.approve_invoice_mapping_policy(uuid,uuid,text,jsonb,text) TO authenticated;

CREATE FUNCTION pos_invoice_private.apply_policy_batch(p_store_id uuid,p_menu_ids uuid[],p_effective_from timestamptz DEFAULT clock_timestamp()) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE policy public.invoice_mapping_policies%ROWTYPE; rows jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'INVOICE_PROFILE_FORBIDDEN'; END IF;
 PERFORM public.require_admin_actor_for_restaurant(p_store_id);
 IF p_menu_ids IS NULL OR cardinality(p_menu_ids) NOT BETWEEN 1 AND 100 OR p_effective_from IS NULL OR p_effective_from>clock_timestamp() THEN RAISE EXCEPTION 'INVOICE_PROFILE_BATCH_INVALID'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('invoice-profile:'||p_store_id::text,0));
 SELECT p.* INTO policy FROM public.invoice_mapping_policies p JOIN public.restaurants r ON r.id=p.store_id AND r.tax_entity_id=p.tax_entity_id
 WHERE p.store_id=p_store_id AND p.effective_from<=clock_timestamp() AND p.effective_to IS NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'INVOICE_POLICY_REQUIRED'; END IF;
 IF (SELECT count(*) FROM public.menu_items WHERE id=ANY(p_menu_ids) AND restaurant_id=p_store_id)<>cardinality(p_menu_ids) THEN RAISE EXCEPTION 'INVOICE_PROFILE_SCOPE_INVALID'; END IF;
 -- Repair display fields from the real current approval without adding a version.
 UPDATE public.menu_items m SET invoice_name_vi=p.invoice_name_vi,invoice_unit_name=p.unit_name
 FROM public.menu_invoice_profiles p WHERE m.id=ANY(p_menu_ids) AND m.restaurant_id=p_store_id AND p.menu_item_id=m.id AND p.tax_entity_id=policy.tax_entity_id
 AND p.effective_from<=clock_timestamp() AND (p.effective_to IS NULL OR clock_timestamp()<p.effective_to)
 AND (m.invoice_name_vi,m.invoice_unit_name) IS DISTINCT FROM (p.invoice_name_vi,p.unit_name);
 WITH current_profiles AS MATERIALIZED(
  SELECT p.* FROM public.menu_invoice_profiles p WHERE p.menu_item_id=ANY(p_menu_ids) AND p.effective_from<=clock_timestamp() AND (p.effective_to IS NULL OR clock_timestamp()<p.effective_to)
 ), scope AS MATERIALIZED(
  SELECT m.*,coalesce(nullif(btrim(m.invoice_sale_unit),''),policy.rules->'menu_units'->>m.id::text,
   CASE WHEN p.unit_override AND p.tax_entity_id=policy.tax_entity_id THEN p.unit_name END,
   CASE WHEN m.is_combo THEN policy.rules->>'combo_unit' ELSE policy.rules->'category_units'->>m.category_id::text END) unit
  FROM public.menu_items m LEFT JOIN current_profiles p ON p.menu_item_id=m.id WHERE m.id=ANY(p_menu_ids) AND m.restaurant_id=p_store_id
 ), selected AS(
  SELECT m.*,p.id profile_id,p.invoice_name_vi approved_name,p.unit_name approved_unit,p.tax_entity_id approved_entity,p.effective_from profile_from,p.effective_to profile_to,
   coalesce(nullif(btrim(m.invoice_sale_unit),'') IS NOT NULL OR (policy.rules->'menu_units') ? m.id::text OR p.unit_override,false) unit_override
  FROM scope m LEFT JOIN current_profiles p ON p.menu_item_id=m.id
 ) SELECT jsonb_agg(jsonb_build_object('approval_type','menu_item','menu_item_id',id,'invoice_name_vi',btrim(name_vi),'unit_name',unit,
  'mapping_version',policy.policy_version||':'||substr(md5(id::text||btrim(name_vi)||unit||p_effective_from::text),1,16),
  'source_reference',policy.source_reference||' / policy:'||policy.id::text,'effective_from',p_effective_from,'effective_to',NULL,'unit_override',unit_override) ORDER BY id) INTO rows
 FROM selected WHERE profile_id IS NULL OR approved_entity<>policy.tax_entity_id OR approved_name IS DISTINCT FROM btrim(name_vi) OR approved_unit IS DISTINCT FROM unit OR profile_to IS NOT NULL;
 IF rows IS NULL THEN RETURN jsonb_build_object('profiles','[]'::jsonb,'unchanged_count',cardinality(p_menu_ids)); END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(rows) x WHERE nullif(btrim(x->>'invoice_name_vi'),'') IS NULL OR nullif(btrim(x->>'unit_name'),'') IS NULL) THEN RAISE EXCEPTION 'INVOICE_POLICY_MENU_INFORMATION_REQUIRED'; END IF;
 RETURN pos_invoice_private.write_mapping_batch(p_store_id,policy.tax_entity_id,rows,policy.id);
END $$;
REVOKE ALL ON FUNCTION pos_invoice_private.apply_policy_batch(uuid,uuid[],timestamptz) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.apply_invoice_mapping_policy_batch(p_store_id uuid,p_menu_ids uuid[],p_effective_from timestamptz DEFAULT clock_timestamp()) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'INVOICE_PROFILE_FORBIDDEN'; END IF;
 RETURN pos_invoice_private.apply_policy_batch(p_store_id,p_menu_ids,p_effective_from);
END $$;
REVOKE ALL ON FUNCTION public.apply_invoice_mapping_policy_batch(uuid,uuid[],timestamptz) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.apply_invoice_mapping_policy_batch(uuid,uuid[],timestamptz) TO authenticated;

CREATE FUNCTION pos_invoice_private.map_changed_menus() RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE changed jsonb; batch record;
BEGIN
 IF TG_OP='INSERT' THEN SELECT jsonb_agg(jsonb_build_object('id',id,'store_id',restaurant_id)) INTO changed FROM invoice_new_menus;
 ELSE
  -- The historical approved-profile view resolves store from the menu master.
  -- Moving an approved ID would rewrite that history; copy to a new ID instead.
  IF EXISTS(SELECT 1 FROM invoice_new_menus n JOIN invoice_old_menus o ON o.id=n.id
   JOIN public.menu_invoice_profiles p ON p.menu_item_id=n.id WHERE n.restaurant_id IS DISTINCT FROM o.restaurant_id) THEN
   RAISE EXCEPTION 'INVOICE_APPROVED_MENU_STORE_IMMUTABLE';
  END IF;
  SELECT jsonb_agg(jsonb_build_object('id',n.id,'store_id',n.restaurant_id)) INTO changed FROM invoice_new_menus n JOIN invoice_old_menus o ON o.id=n.id
  WHERE (n.name_vi,n.category_id,n.is_combo,n.invoice_sale_unit,n.restaurant_id) IS DISTINCT FROM (o.name_vi,o.category_id,o.is_combo,o.invoice_sale_unit,o.restaurant_id)
   OR (o.is_archived AND NOT n.is_archived);
 END IF;
 IF changed IS NULL THEN RETURN NULL; END IF;
 -- Batches are grouped by actual store; the transition relation is read once.
 FOR batch IN WITH rows AS(SELECT (x->>'id')::uuid id,(x->>'store_id')::uuid store_id FROM jsonb_array_elements(changed)x), numbered AS(
  SELECT *,((row_number() OVER(PARTITION BY store_id ORDER BY id)-1)/100)::integer part FROM rows)
  SELECT store_id,array_agg(id ORDER BY id) ids FROM numbered GROUP BY store_id,part ORDER BY store_id,part LOOP
  PERFORM pos_invoice_private.apply_policy_batch(batch.store_id,batch.ids);
 END LOOP;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION pos_invoice_private.map_changed_menus() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER invoice_map_insert AFTER INSERT ON public.menu_items REFERENCING NEW TABLE AS invoice_new_menus FOR EACH STATEMENT EXECUTE FUNCTION pos_invoice_private.map_changed_menus();
CREATE TRIGGER invoice_map_update AFTER UPDATE ON public.menu_items REFERENCING OLD TABLE AS invoice_old_menus NEW TABLE AS invoice_new_menus FOR EACH STATEMENT EXECUTE FUNCTION pos_invoice_private.map_changed_menus();

CREATE FUNCTION public.get_invoice_mapping_catalog(p_tax_entity_id uuid,p_after_id uuid DEFAULT NULL,p_limit integer DEFAULT 100) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'INVOICE_PROFILE_FORBIDDEN'; END IF;
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'INVOICE_PROFILE_BATCH_INVALID'; END IF;
 WITH scope AS MATERIALIZED(
  SELECT m.id,m.restaurant_id store_id,r.name store_name,r.tax_entity_id,m.category_id,c.name_vi category_name,m.name_vi,m.is_archived,m.is_available,m.is_visible_public,m.is_combo,m.invoice_sale_unit,
  m.invoice_name_vi,m.invoice_unit_name,p.id profile_id,p.invoice_name_vi approved_name,p.unit_name approved_unit,p.tax_entity_id approved_entity,p.effective_from,p.effective_to,
  policy.id policy_id,policy.policy_version,policy.rules,policy.approved_by policy_approved_by,policy.source_reference policy_reference
  FROM public.menu_items m JOIN public.restaurants r ON r.id=m.restaurant_id LEFT JOIN public.menu_categories c ON c.id=m.category_id
  LEFT JOIN public.menu_invoice_profiles p ON p.menu_item_id=m.id AND p.effective_from<=clock_timestamp() AND (p.effective_to IS NULL OR clock_timestamp()<p.effective_to)
  LEFT JOIN public.invoice_mapping_policies policy ON policy.store_id=r.id AND policy.tax_entity_id=r.tax_entity_id AND policy.effective_to IS NULL AND policy.effective_from<=statement_timestamp()
  WHERE p_tax_entity_id IS NULL OR r.tax_entity_id=p_tax_entity_id
 ), checked AS MATERIALIZED(
  SELECT *,CASE WHEN nullif(btrim(name_vi),'') IS NULL THEN 'source_name_required' WHEN profile_id IS NULL THEN 'approval_required'
   WHEN approved_entity IS DISTINCT FROM tax_entity_id THEN 'scope_invalid' WHEN invoice_name_vi IS DISTINCT FROM approved_name OR invoice_unit_name IS DISTINCT FROM approved_unit THEN 'display_mismatch'
   ELSE 'mapped' END mapping_status,
  coalesce(nullif(btrim(invoice_sale_unit),''),approved_unit,rules->'menu_units'->>id::text,CASE WHEN is_combo THEN rules->>'combo_unit' ELSE rules->'category_units'->>category_id::text END) suggested_unit FROM scope
 ), page AS(SELECT * FROM checked WHERE p_after_id IS NULL OR id>p_after_id ORDER BY id LIMIT p_limit)
 SELECT jsonb_build_object('tax_entity_id',p_tax_entity_id,'server_time',statement_timestamp(),'total_count',(SELECT count(*) FROM checked),'mapped_count',(SELECT count(*) FROM checked WHERE mapping_status='mapped'),
 'catalog_revision',(SELECT md5(coalesce(jsonb_agg(to_jsonb(checked)-'rules' ORDER BY id)::text,'')) FROM checked),'missing_count',(SELECT count(*) FROM checked WHERE mapping_status<>'mapped'),'rows',coalesce((SELECT jsonb_agg(to_jsonb(page)-'rules' ORDER BY id) FROM page),'[]'::jsonb),
 'entities',(SELECT jsonb_agg(jsonb_build_object('id',e.id,'name',e.name)) FROM public.tax_entity e WHERE EXISTS(SELECT 1 FROM public.restaurants r WHERE r.tax_entity_id=e.id)),'stores',(SELECT jsonb_agg(jsonb_build_object('store_id',r.id,'store_name',r.name,'policy',to_jsonb(policy),'categories',(
  SELECT jsonb_agg(jsonb_build_object('id',c.id,'name_vi',c.name_vi,'analytics_group',c.analytics_group) ORDER BY c.sort_order,c.id) FROM public.menu_categories c WHERE c.restaurant_id=r.id)))
  FROM public.restaurants r LEFT JOIN public.invoice_mapping_policies policy ON policy.store_id=r.id AND policy.tax_entity_id=r.tax_entity_id AND policy.effective_to IS NULL WHERE p_tax_entity_id IS NULL OR r.tax_entity_id=p_tax_entity_id)) INTO result;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.get_invoice_mapping_catalog(uuid,uuid,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_invoice_mapping_catalog(uuid,uuid,integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_create_menu_item_with_invoice(
  p_store_id uuid,
  p_category_id uuid,
  p_name_ko text,
  p_name_vi text,
  p_name_en text,
  p_paperless_name_vi text,
  p_price numeric,
  p_sort_order integer DEFAULT 0,
  p_is_available boolean DEFAULT true,
  p_tax jsonb DEFAULT NULL,
  p_invoice_sale_unit text DEFAULT NULL
) RETURNS public.menu_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_created public.menu_items%ROWTYPE;
  v_paperless_name_vi text := NULLIF(
    btrim(COALESCE(p_paperless_name_vi, '')), ''
  );
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);
  IF NULLIF(btrim(COALESCE(p_name_ko, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_name_vi, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_name_en, '')), '') IS NULL THEN
    RAISE EXCEPTION 'MENU_TRANSLATIONS_REQUIRED';
  END IF;
  IF char_length(COALESCE(v_paperless_name_vi, '')) > 200 THEN
    RAISE EXCEPTION 'MENU_PAPERLESS_NAME_INVALID';
  END IF;
  IF p_price IS NULL OR p_price <= 0 THEN
    RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.menu_categories
    WHERE id = p_category_id AND restaurant_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  INSERT INTO public.menu_items(
    restaurant_id, category_id, name, name_ko, name_vi, name_en,
    invoice_sale_unit, paperless_name_vi, price, is_available, is_visible_public, sort_order,
    created_at, updated_at
  ) VALUES (
    p_store_id, p_category_id, btrim(p_name_ko), btrim(p_name_ko),
    btrim(p_name_vi), btrim(p_name_en), nullif(btrim(p_invoice_sale_unit),''), v_paperless_name_vi, p_price,
    COALESCE(p_is_available, true), false, COALESCE(p_sort_order, 0),
    now(), now()
  ) RETURNING * INTO v_created;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'admin_create_menu_item', 'menu_items', v_created.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'new_values', jsonb_build_object(
        'name_ko', v_created.name_ko,
        'name_vi', v_created.name_vi,
        'name_en', v_created.name_en,
        'paperless_name_vi', v_created.paperless_name_vi,
        'price', v_created.price
      )
    )
  );
  IF p_tax IS NOT NULL THEN PERFORM public.admin_set_menu_beverage_tax(v_created.id,p_tax); END IF;
  SELECT * INTO v_created FROM public.menu_items WHERE id=v_created.id;
  RETURN v_created;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_create_menu_item_with_invoice(uuid,uuid,text,text,text,text,numeric,integer,boolean,jsonb,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.admin_create_menu_item_with_invoice(uuid,uuid,text,text,text,text,numeric,integer,boolean,jsonb,text) TO authenticated;

CREATE FUNCTION pos_invoice_private.import_new_menu_rows(p_store_id uuid,p_rows jsonb) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE categories_count integer; items_count integer;
BEGIN
 PERFORM public.require_admin_actor_for_restaurant(p_store_id);
 PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text,0));
 IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'MENU_IMPORT_ROWS_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_rows)x WHERE jsonb_typeof(x) IS DISTINCT FROM 'object'
 OR jsonb_typeof(x->'price') IS DISTINCT FROM 'number' OR (x->>'price')::numeric<=0
 OR jsonb_typeof(x->'sort_order') IS DISTINCT FROM 'number' OR jsonb_typeof(x->'category_sort_order') IS DISTINCT FROM 'number'
 OR (x->>'sort_order')::numeric<0 OR (x->>'category_sort_order')::numeric<0
 OR (x->>'sort_order')::numeric<>trunc((x->>'sort_order')::numeric) OR (x->>'category_sort_order')::numeric<>trunc((x->>'category_sort_order')::numeric)
 OR jsonb_typeof(x->'is_available') IS DISTINCT FROM 'boolean' OR jsonb_typeof(x->'is_visible_public') IS DISTINCT FROM 'boolean'
 OR nullif(btrim(x->>'name'),'') IS NULL OR length(x->>'name')>200 OR nullif(btrim(x->>'category_name'),'') IS NULL OR length(x->>'category_name')>200
 OR nullif(btrim(x->>'name_vi'),'') IS NULL OR length(x->>'name_vi')>200 OR length(coalesce(x->>'description',''))>1000 OR length(coalesce(x->>'invoice_sale_unit',''))>40) THEN RAISE EXCEPTION 'MENU_IMPORT_VI_NAME_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_rows)x GROUP BY lower(btrim(x->>'category_name')),lower(btrim(x->>'name')) HAVING count(*)>1) THEN RAISE EXCEPTION 'MENU_IMPORT_DUPLICATE_ROWS'; END IF;
 DROP TABLE IF EXISTS pg_temp.invoice_import_input;
 CREATE TEMP TABLE invoice_import_input ON COMMIT DROP AS
 SELECT gen_random_uuid() id,x.*,lower(btrim(x.category_name)) category_key,lower(btrim(x.name)) menu_key
 FROM jsonb_to_recordset(p_rows)x(source_row integer,category_name text,category_sort_order integer,name text,name_vi text,invoice_sale_unit text,description text,price numeric,is_available boolean,is_visible_public boolean,sort_order integer);
 IF EXISTS(SELECT 1 FROM public.menu_categories c JOIN(SELECT DISTINCT category_key FROM pg_temp.invoice_import_input)x ON lower(btrim(c.name))=x.category_key
 WHERE c.restaurant_id=p_store_id GROUP BY x.category_key HAVING count(*)>1) THEN RAISE EXCEPTION 'MENU_IMPORT_CATEGORY_AMBIGUOUS'; END IF;
 IF EXISTS(SELECT 1 FROM public.menu_categories c JOIN pg_temp.invoice_import_input x ON lower(btrim(c.name))=x.category_key WHERE c.restaurant_id=p_store_id AND NOT c.is_active) THEN RAISE EXCEPTION 'MENU_IMPORT_CATEGORY_INACTIVE'; END IF;
 IF EXISTS(SELECT 1 FROM public.menu_items m JOIN public.menu_categories c ON c.id=m.category_id JOIN pg_temp.invoice_import_input x ON lower(btrim(c.name))=x.category_key AND lower(btrim(m.name))=x.menu_key WHERE m.restaurant_id=p_store_id) THEN RAISE EXCEPTION 'MENU_IMPORT_ITEM_EXISTS'; END IF;
 WITH inserted AS(INSERT INTO public.menu_categories(restaurant_id,name,name_ko,name_vi,name_en,sort_order,is_active,created_at)
 SELECT p_store_id,btrim(min(x.category_name)),btrim(min(x.category_name)),btrim(min(x.category_name)),btrim(min(x.category_name)),min(x.category_sort_order),true,now()
 FROM pg_temp.invoice_import_input x WHERE NOT EXISTS(SELECT 1 FROM public.menu_categories c WHERE c.restaurant_id=p_store_id AND lower(btrim(c.name))=x.category_key) GROUP BY x.category_key RETURNING *)
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
 SELECT auth.uid(),'admin_create_menu_category','menu_categories',id,jsonb_build_object('restaurant_id',p_store_id,'source','excel_import','new_values',to_jsonb(inserted)) FROM inserted;
 GET DIAGNOSTICS categories_count=ROW_COUNT;
 INSERT INTO public.menu_items(id,restaurant_id,category_id,name,name_ko,name_vi,name_en,invoice_sale_unit,description,price,is_available,is_visible_public,sort_order,created_at,updated_at)
 SELECT x.id,p_store_id,c.id,btrim(x.name),btrim(x.name),btrim(x.name_vi),btrim(x.name),nullif(btrim(x.invoice_sale_unit),''),x.description,x.price,x.is_available,x.is_visible_public,x.sort_order,now(),now()
 FROM pg_temp.invoice_import_input x JOIN public.menu_categories c ON c.restaurant_id=p_store_id AND lower(btrim(c.name))=x.category_key;
 GET DIAGNOSTICS items_count=ROW_COUNT;
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
 SELECT auth.uid(),'admin_create_menu_item','menu_items',m.id,jsonb_build_object('restaurant_id',p_store_id,'source','excel_import','source_row',x.source_row,'new_values',to_jsonb(m)) FROM public.menu_items m JOIN pg_temp.invoice_import_input x ON x.id=m.id;
 RETURN jsonb_build_object('created_category_count',categories_count,'imported_item_count',items_count);
END $$;
REVOKE ALL ON FUNCTION pos_invoice_private.import_new_menu_rows(uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;

-- Preserve catalog replacement, image and archival rules, but stage Vietnamese
-- names/actual units once before the existing set-based writes.
DO $import$ DECLARE d text; BEGIN
 IF to_regprocedure('public.admin_import_menu_items_before_beverage_tax(uuid,jsonb)') IS NOT NULL THEN
 SELECT pg_get_functiondef('public.admin_import_menu_items_before_beverage_tax(uuid,jsonb)'::regprocedure) INTO d;
 IF strpos(d,'matched_item_id UUID,')>0 AND strpos(d,'  -- Serialize catalog replacement')>0 THEN
 d:=replace(d,'matched_item_id UUID,','invoice_name_vi TEXT, invoice_sale_unit TEXT, matched_item_id UUID,');
 d:=replace(d,'  -- Serialize catalog replacement', $patch$
 UPDATE pg_temp.menu_import_stage_items s SET invoice_name_vi=nullif(btrim(x->>'name_vi'),''),invoice_sale_unit=nullif(btrim(x->>'invoice_sale_unit'),'')
 FROM jsonb_array_elements(p_rows)x WHERE s.category_key=lower(btrim(x->>'category_name')) AND s.menu_key=lower(btrim(x->>'name'));
 IF EXISTS(SELECT 1 FROM pg_temp.menu_import_stage_items WHERE length(invoice_name_vi)>200 OR length(invoice_sale_unit)>40) THEN RAISE EXCEPTION 'MENU_IMPORT_INVOICE_INFORMATION_INVALID'; END IF;
 -- Serialize catalog replacement$patch$);
 d:=replace(d,'      name = s.name,','      name = s.name, name_vi=coalesce(s.invoice_name_vi,mi.name_vi), invoice_sale_unit=coalesce(s.invoice_sale_unit,mi.invoice_sale_unit),');
 d:=replace(d,E'  INSERT INTO public.menu_items (\n    restaurant_id,', $patch$
 IF EXISTS(SELECT 1 FROM pg_temp.menu_import_stage_items WHERE matched_item_id IS NULL AND invoice_name_vi IS NULL) THEN RAISE EXCEPTION 'MENU_IMPORT_VI_NAME_REQUIRED'; END IF;
 INSERT INTO public.menu_items (
    name_vi,invoice_sale_unit,restaurant_id,$patch$);
 d:=replace(d,E'  SELECT\n    p_store_id,\n    c.category_id,',E'  SELECT\n    s.invoice_name_vi,s.invoice_sale_unit,p_store_id,\n    c.category_id,');
 EXECUTE d;
 ELSIF strpos(d,'v_created_category_count')>0 AND strpos(d,'MENU_IMPORT_ITEM_EXISTS')>0 THEN
 EXECUTE $legacy$CREATE OR REPLACE FUNCTION public.admin_import_menu_items_before_beverage_tax(p_store_id uuid,p_rows jsonb) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $body$
 BEGIN RETURN pos_invoice_private.import_new_menu_rows(p_store_id,p_rows); END $body$;$legacy$;
 ELSE RAISE EXCEPTION 'INVOICE_IMPORT_ANCHOR_CHANGED';
 END IF;
 END IF;
END $import$;

CREATE FUNCTION pos_invoice_private.apply_beverage_rows(p_store_id uuid,p_rows jsonb) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
BEGIN
 PERFORM public.require_admin_actor_for_restaurant(p_store_id);
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_rows)x LEFT JOIN public.menu_items m ON m.id=(x->>'item_id')::uuid AND m.restaurant_id=p_store_id
 WHERE m.id IS NULL OR jsonb_typeof(x->'beverage_sugar_tax_class') IS DISTINCT FROM 'string'
 OR (x ? 'sugar_g_per_100ml' AND jsonb_typeof(x->'sugar_g_per_100ml') NOT IN('number','null'))
 OR (x ? 'tax_basis_note' AND jsonb_typeof(x->'tax_basis_note') NOT IN('string','null'))) THEN RAISE EXCEPTION 'MENU_TAX_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_to_recordset(p_rows)x(item_id uuid,beverage_sugar_tax_class text,sugar_g_per_100ml numeric,tax_basis_note text)
 JOIN public.menu_items m ON m.id=x.item_id WHERE x.beverage_sugar_tax_class NOT IN('not_applicable','lte_5','gt_5')
 OR (x.sugar_g_per_100ml IS NOT NULL AND NOT(x.sugar_g_per_100ml BETWEEN 0 AND 100)) OR length(coalesce(btrim(x.tax_basis_note),''))>500
 OR ((m.vat_category='alcohol' OR m.is_combo) AND x.beverage_sugar_tax_class<>'not_applicable')
 OR (x.beverage_sugar_tax_class='not_applicable' AND x.sugar_g_per_100ml IS NOT NULL)
 OR (x.beverage_sugar_tax_class<>'not_applicable' AND x.sugar_g_per_100ml IS NULL AND nullif(btrim(x.tax_basis_note),'') IS NULL)
 OR (x.beverage_sugar_tax_class<>'not_applicable' AND x.sugar_g_per_100ml IS NOT NULL AND x.beverage_sugar_tax_class<>CASE WHEN x.sugar_g_per_100ml>5 THEN 'gt_5' ELSE 'lte_5' END)) THEN RAISE EXCEPTION 'MENU_TAX_INVALID'; END IF;
 WITH input AS MATERIALIZED(SELECT * FROM jsonb_to_recordset(p_rows)x(item_id uuid,beverage_sugar_tax_class text,sugar_g_per_100ml numeric,tax_basis_note text)),
 old AS MATERIALIZED(SELECT m.* FROM public.menu_items m JOIN input x ON x.item_id=m.id WHERE m.restaurant_id=p_store_id FOR UPDATE OF m),
 changed AS(UPDATE public.menu_items m SET beverage_sugar_tax_class=x.beverage_sugar_tax_class,sugar_g_per_100ml=x.sugar_g_per_100ml,tax_basis_note=nullif(btrim(x.tax_basis_note),''),updated_at=now()
 FROM input x WHERE m.id=x.item_id AND m.restaurant_id=p_store_id RETURNING m.*)
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
 SELECT auth.uid(),'admin_update_menu_beverage_tax','menu_items',n.id,jsonb_build_object('store_id',p_store_id,
 'old_values',jsonb_build_object('class',o.beverage_sugar_tax_class,'sugar',o.sugar_g_per_100ml,'basis',o.tax_basis_note,'vat_rate',o.effective_vat_rate),
 'new_values',jsonb_build_object('class',n.beverage_sugar_tax_class,'sugar',n.sugar_g_per_100ml,'basis',n.tax_basis_note,'vat_rate',n.effective_vat_rate))
 FROM changed n JOIN old o ON o.id=n.id WHERE (n.beverage_sugar_tax_class,n.sugar_g_per_100ml,n.tax_basis_note) IS DISTINCT FROM (o.beverage_sugar_tax_class,o.sugar_g_per_100ml,o.tax_basis_note);
END $$;
REVOKE ALL ON FUNCTION pos_invoice_private.apply_beverage_rows(uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;

-- Keep the outer replacement/archival wrapper; replace its per-item tax loop.
DO $wrappers$ BEGIN
 IF to_regprocedure('public.admin_import_menu_items_before_beverage_tax(uuid,jsonb)') IS NOT NULL THEN
 EXECUTE $definition$
 CREATE OR REPLACE FUNCTION public.admin_import_menu_items(p_store_id uuid,p_rows jsonb) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $body$
 DECLARE result jsonb; tax_rows jsonb;
 BEGIN
  result:=public.admin_import_menu_items_before_beverage_tax(p_store_id,p_rows);
  SELECT coalesce(jsonb_agg(x||jsonb_build_object('item_id',m.id)),'[]'::jsonb) INTO tax_rows FROM jsonb_array_elements(p_rows)x
  JOIN public.menu_categories c ON c.restaurant_id=p_store_id AND lower(btrim(c.name))=lower(btrim(x->>'category_name'))
  JOIN public.menu_items m ON m.restaurant_id=p_store_id AND m.category_id=c.id AND NOT m.is_archived AND lower(btrim(m.name))=lower(btrim(x->>'name'))
  WHERE x ? 'beverage_sugar_tax_class';
  IF jsonb_array_length(tax_rows)<>(SELECT count(*) FROM jsonb_array_elements(p_rows)x WHERE x ? 'beverage_sugar_tax_class') THEN RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND'; END IF;
  PERFORM pos_invoice_private.apply_beverage_rows(p_store_id,tax_rows);
  RETURN result;
 END $body$;
 $definition$;
 END IF;
 IF to_regprocedure('public.admin_update_menu_workbook_before_beverage_tax(uuid,jsonb,jsonb)') IS NOT NULL THEN
 EXECUTE $definition$
 CREATE OR REPLACE FUNCTION public.admin_update_menu_workbook_i18n(p_store_id uuid,p_categories jsonb,p_items jsonb) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $body$
 DECLARE result jsonb;
 BEGIN
  result:=public.admin_update_menu_workbook_before_beverage_tax(p_store_id,p_categories,p_items);
  PERFORM pos_invoice_private.apply_beverage_rows(p_store_id,(SELECT coalesce(jsonb_agg(x),'[]'::jsonb) FROM jsonb_array_elements(p_items)x WHERE x ? 'beverage_sugar_tax_class'));
  RETURN result;
 END $body$;
 $definition$;
 END IF;
END $wrappers$;
DO $$BEGIN
 IF to_regprocedure('public.admin_import_menu_items(uuid,jsonb)') IS NOT NULL THEN
  REVOKE ALL ON FUNCTION public.admin_import_menu_items(uuid,jsonb) FROM PUBLIC,anon,service_role;
  GRANT EXECUTE ON FUNCTION public.admin_import_menu_items(uuid,jsonb) TO authenticated;
 END IF;
 IF to_regprocedure('public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb)') IS NOT NULL THEN
  REVOKE ALL ON FUNCTION public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb) FROM PUBLIC,anon,service_role;
  GRANT EXECUTE ON FUNCTION public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb) TO authenticated;
 END IF;
END $$;

-- The round-trip writer validates whole relations before two set-based updates.
-- The deployed outer wrapper continues to archive omitted rows and preserve photos.
DO $roundtrip$ BEGIN
 IF to_regprocedure('public.admin_update_menu_workbook_i18n_apply(uuid,jsonb,jsonb)') IS NOT NULL THEN
 EXECUTE $definition$
 CREATE OR REPLACE FUNCTION public.admin_update_menu_workbook_i18n_apply(p_store_id uuid,p_categories jsonb,p_items jsonb) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $body$
 BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);
  IF jsonb_typeof(p_categories) IS DISTINCT FROM 'array' OR jsonb_array_length(p_categories) NOT BETWEEN 1 AND 500 OR jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items)>500 THEN RAISE EXCEPTION 'MENU_WORKBOOK_ITEMS_INVALID'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_categories)x GROUP BY x->>'category_id' HAVING count(*)>1) OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_items)x GROUP BY x->>'item_id' HAVING count(*)>1) THEN RAISE EXCEPTION 'MENU_WORKBOOK_ITEM_DUPLICATE'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_categories)x LEFT JOIN public.menu_categories c ON c.id=(x->>'category_id')::uuid AND c.restaurant_id=p_store_id
   WHERE c.id IS NULL OR x->>'store_id' IS DISTINCT FROM p_store_id::text OR jsonb_typeof(x->'sort_order') IS DISTINCT FROM 'number' OR (x->>'sort_order')::numeric<0 OR (x->>'sort_order')::numeric<>trunc((x->>'sort_order')::numeric)) THEN RAISE EXCEPTION 'MENU_WORKBOOK_CATEGORY_NOT_FOUND'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_items)x LEFT JOIN public.menu_items m ON m.id=(x->>'item_id')::uuid AND m.restaurant_id=p_store_id
   LEFT JOIN public.menu_categories c ON c.id=m.category_id AND c.restaurant_id=p_store_id
   WHERE m.id IS NULL OR c.id IS NULL OR x->>'store_id' IS DISTINCT FROM p_store_id::text OR x->>'category_id' IS DISTINCT FROM m.category_id::text
   OR jsonb_typeof(x->'price') IS DISTINCT FROM 'number' OR (x->>'price')::numeric<=0 OR jsonb_typeof(x->'sort_order') IS DISTINCT FROM 'number'
   OR (x->>'sort_order')::numeric<0 OR (x->>'sort_order')::numeric<>trunc((x->>'sort_order')::numeric)
   OR jsonb_typeof(x->'is_available') IS DISTINCT FROM 'boolean' OR jsonb_typeof(x->'is_visible_public') IS DISTINCT FROM 'boolean'
   OR length(coalesce(x->>'description',''))>1000 OR length(coalesce(x->>'paperless_name_vi',''))>200) THEN RAISE EXCEPTION 'MENU_WORKBOOK_ITEM_ROW_INVALID'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_categories||p_items)x CROSS JOIN unnest(ARRAY['name_ko','name_vi','name_en']) field
   WHERE nullif(btrim(x->>field),'') IS NULL OR length(btrim(x->>field))>200) THEN RAISE EXCEPTION 'MENU_TRANSLATIONS_REQUIRED'; END IF;
  WITH input AS MATERIALIZED(SELECT * FROM jsonb_to_recordset(p_categories)x(category_id uuid,name_ko text,name_vi text,name_en text,sort_order integer)),
  old AS MATERIALIZED(SELECT c.* FROM public.menu_categories c JOIN input x ON x.category_id=c.id FOR UPDATE OF c),
  changed AS(UPDATE public.menu_categories c SET name=btrim(x.name_ko),name_ko=btrim(x.name_ko),name_vi=btrim(x.name_vi),name_en=btrim(x.name_en),sort_order=x.sort_order FROM input x WHERE c.id=x.category_id RETURNING c.*)
  INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
  SELECT auth.uid(),'admin_update_menu_category','menu_categories',n.id,jsonb_build_object('store_id',p_store_id,'source','excel_roundtrip','old_values',to_jsonb(o),'new_values',to_jsonb(n)) FROM changed n JOIN old o ON o.id=n.id WHERE to_jsonb(o)<>to_jsonb(n);
  WITH input AS MATERIALIZED(SELECT * FROM jsonb_array_elements(p_items)),
  old AS MATERIALIZED(SELECT m.* FROM public.menu_items m JOIN input x ON m.id=(x.value->>'item_id')::uuid FOR UPDATE OF m),
  changed AS(UPDATE public.menu_items m SET name=btrim(x.value->>'name_ko'),name_ko=btrim(x.value->>'name_ko'),name_vi=btrim(x.value->>'name_vi'),name_en=btrim(x.value->>'name_en'),
   paperless_name_vi=CASE WHEN x.value ? 'paperless_name_vi' THEN nullif(btrim(x.value->>'paperless_name_vi'),'') ELSE m.paperless_name_vi END,
   invoice_sale_unit=CASE WHEN x.value ? 'invoice_sale_unit' THEN nullif(btrim(x.value->>'invoice_sale_unit'),'') ELSE m.invoice_sale_unit END,
   description=nullif(btrim(x.value->>'description'),''),price=(x.value->>'price')::numeric,is_available=(x.value->>'is_available')::boolean,is_visible_public=(x.value->>'is_visible_public')::boolean,sort_order=(x.value->>'sort_order')::integer,updated_at=now()
   FROM input x WHERE m.id=(x.value->>'item_id')::uuid RETURNING m.*)
  INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
  SELECT auth.uid(),'admin_update_menu_item','menu_items',n.id,jsonb_build_object('store_id',p_store_id,'source','excel_roundtrip','old_values',to_jsonb(o),'new_values',to_jsonb(n)) FROM changed n JOIN old o ON o.id=n.id WHERE to_jsonb(o)-'updated_at'<>to_jsonb(n)-'updated_at';
  RETURN jsonb_build_object('updated_category_count',jsonb_array_length(p_categories),'updated_item_count',jsonb_array_length(p_items),'preserved_image_count',(SELECT count(*) FROM public.menu_items m JOIN jsonb_array_elements(p_items)x ON m.id=(x->>'item_id')::uuid WHERE m.image_url IS NOT NULL OR m.image_storage_path IS NOT NULL));
 END $body$;
 $definition$;
 END IF;
END $roundtrip$;

-- Queue state only: payment completion never calls a vendor or fails due to
-- missing mappings. Preserve dispatched, attempted and externally reported jobs.
CREATE FUNCTION pos_invoice_private.mark_mapping_review() RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE protected uuid[];
BEGIN
 IF NOT EXISTS(SELECT 1 FROM invoice_new_jobs) THEN RETURN NULL; END IF;
 WITH paid AS MATERIALIZED(SELECT p.order_id,(max(p.created_at) AT TIME ZONE 'Asia/Ho_Chi_Minh')::date business_date
 FROM public.payments p JOIN (SELECT DISTINCT order_id FROM invoice_new_jobs WHERE source_system='restaurant_pos') n ON n.order_id=p.order_id WHERE p.is_revenue GROUP BY p.order_id)
 SELECT coalesce(array_agg(n.id),'{}'::uuid[]) INTO protected FROM invoice_new_jobs n JOIN paid p ON p.order_id=n.order_id
 JOIN public.sales_external_reporting_protections x ON x.business_date=p.business_date AND x.tax_entity_id=n.tax_entity_id AND x.source_system=n.source_system;
 UPDATE public.meinvoice_jobs j SET status='pending_manual_config',manual_action_type='invoice_mapping_required'
 FROM invoice_new_jobs n WHERE j.id=n.id AND j.source_system='restaurant_pos'
 AND (j.status='pending' OR (j.status='pending_manual_config' AND (j.manual_action_type IS NULL OR j.manual_action_type='invoice_mapping_required'))) AND j.misa_ref_id IS NULL AND j.invoice_number IS NULL
 AND j.dispatch_claim_id IS NULL AND coalesce(j.dispatch_attempts,0)=0
 AND j.id<>ALL(protected)
 AND (j.status<>'pending_manual_config' OR j.manual_action_type IS DISTINCT FROM 'invoice_mapping_required')
 AND EXISTS(SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(j.line_items_snapshot)='array' THEN j.line_items_snapshot ELSE '[]'::jsonb END) l WHERE
  nullif(l->>'invoice_name_vi','') IS NULL OR nullif(l->>'misa_unit_name','') IS NULL OR nullif(l->>'invoice_profile_id','') IS NULL
  OR nullif(l->>'invoice_approval_type','') IS NULL OR nullif(l->>'invoice_mapping_version','') IS NULL OR nullif(l->>'invoice_effective_from','') IS NULL
  OR nullif(l->>'invoice_store_id','') IS NULL OR nullif(l->>'invoice_source_reference','') IS NULL);
 UPDATE public.meinvoice_jobs j SET status='pending',manual_action_type=NULL FROM invoice_new_jobs n
 WHERE j.id=n.id AND j.status='pending_manual_config' AND j.manual_action_type='invoice_mapping_required'
 AND j.misa_ref_id IS NULL AND j.invoice_number IS NULL
 AND j.dispatch_claim_id IS NULL AND coalesce(j.dispatch_attempts,0)=0
 AND jsonb_array_length(CASE WHEN jsonb_typeof(j.line_items_snapshot)='array' THEN j.line_items_snapshot ELSE '[]'::jsonb END)>0
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(j.line_items_snapshot)='array' THEN j.line_items_snapshot ELSE '[]'::jsonb END) l CROSS JOIN unnest(ARRAY['invoice_name_vi','misa_unit_name','invoice_profile_id','invoice_approval_type','invoice_mapping_version','invoice_effective_from','invoice_store_id','invoice_source_reference']) field WHERE nullif(l->>field,'') IS NULL)
 AND j.id<>ALL(protected);
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION pos_invoice_private.mark_mapping_review() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER invoice_mapping_job_insert AFTER INSERT ON public.meinvoice_jobs REFERENCING NEW TABLE AS invoice_new_jobs FOR EACH STATEMENT EXECUTE FUNCTION pos_invoice_private.mark_mapping_review();
CREATE TRIGGER invoice_mapping_job_update AFTER UPDATE ON public.meinvoice_jobs REFERENCING NEW TABLE AS invoice_new_jobs FOR EACH STATEMENT EXECUTE FUNCTION pos_invoice_private.mark_mapping_review();

-- Owner-provided correction declaration protects the whole day conservatively.
-- Five is the known correction scope, not a claim of 46 provider submissions.
-- This hashes the supplied declaration document, never an unavailable Excel file.
INSERT INTO public.sales_external_reporting_protections(business_date,tax_entity_id,source_system,reported_receipt_count,source_reference,source_sha256)
 SELECT DATE '2026-10-13',id,'restaurant_pos',5,
 'INVOICE_MAPPING_OWNER_CORRECTION_DECLARATION_2026_10_13.md / owner-provided Excel correction declaration (5 affected receipts; whole day protected)',
 '2be1c97f271f44a67824fab408ae5b43a66b08431bf864dc90859f528217ab4c' FROM public.tax_entity WHERE id='a6bda671-4179-5a29-a798-76357b42b497'::uuid
 ON CONFLICT(business_date,tax_entity_id,source_system) DO NOTHING;

DO $$BEGIN
 IF has_function_privilege('anon','public.get_invoice_mapping_catalog(uuid,uuid,integer)','EXECUTE') OR has_function_privilege('authenticated','pos_invoice_private.write_mapping_batch(uuid,uuid,jsonb,uuid)','EXECUTE') THEN RAISE EXCEPTION 'INVOICE_POLICY_ACL_INVALID'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='invoice_map_insert' AND tgrelid='public.menu_items'::regclass) THEN RAISE EXCEPTION 'INVOICE_POLICY_TRIGGER_MISSING'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conname='menu_invoice_period_exclusion' AND conrelid='public.menu_invoice_profiles'::regclass)
 OR NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='invoice_mapping_job_insert' AND tgrelid='public.meinvoice_jobs'::regclass)
 OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.invoice_mapping_policies'::regclass)
 OR strpos(pg_get_functiondef('public.admin_import_menu_items(uuid,jsonb)'::regprocedure),'apply_beverage_rows')=0
 OR strpos(pg_get_functiondef('public.admin_update_menu_workbook_i18n_apply(uuid,jsonb,jsonb)'::regprocedure),'invoice_sale_unit')=0 THEN RAISE EXCEPTION 'INVOICE_POLICY_POSTCONDITION_INVALID'; END IF;
END $$;
COMMIT;
