BEGIN;
-- production-gate: self-verifying
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='120s';
ALTER TABLE public.menu_invoice_profiles ADD COLUMN mapping_version text NOT NULL DEFAULT 'legacy-menu-v1',
 ADD COLUMN source_reference text NOT NULL DEFAULT 'menu_invoice_profiles approval history',
 ADD COLUMN tax_entity_id uuid REFERENCES public.tax_entity(id);
UPDATE public.menu_invoice_profiles p SET tax_entity_id=r.tax_entity_id FROM public.menu_items m JOIN public.restaurants r ON r.id=m.restaurant_id WHERE m.id=p.menu_item_id;
CREATE TABLE public.item_type_invoice_profiles(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),store_id uuid NOT NULL REFERENCES public.restaurants(id),
 tax_entity_id uuid NOT NULL REFERENCES public.tax_entity(id),item_type text NOT NULL CHECK(item_type='wet_tissue_charge'),
 invoice_name_vi text NOT NULL CHECK(length(btrim(invoice_name_vi)) BETWEEN 1 AND 200),
 unit_name text NOT NULL CHECK(length(btrim(unit_name)) BETWEEN 1 AND 40),
 mapping_version text NOT NULL CHECK(length(btrim(mapping_version)) BETWEEN 1 AND 100),
 source_reference text NOT NULL CHECK(length(btrim(source_reference)) BETWEEN 1 AND 500),
 effective_from timestamptz NOT NULL,effective_to timestamptz,
 approved_by uuid NOT NULL DEFAULT auth.uid(),approved_at timestamptz NOT NULL DEFAULT now(),
 CHECK(effective_to IS NULL OR effective_to>effective_from));
CREATE INDEX item_type_invoice_profile_history ON public.item_type_invoice_profiles(store_id,tax_entity_id,item_type,effective_from);
ALTER TABLE public.item_type_invoice_profiles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.item_type_invoice_profiles FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.item_type_invoice_profiles TO authenticated;
CREATE POLICY item_type_invoice_profiles_read ON public.item_type_invoice_profiles FOR SELECT TO authenticated USING(public.is_super_admin());

-- All writers, including the existing single-menu editor, serialize by store.
CREATE FUNCTION public.check_invoice_profile_period() RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_catalog AS $$
DECLARE scope uuid;
BEGIN
 IF TG_TABLE_NAME='menu_invoice_profiles' THEN
 SELECT restaurant_id INTO scope FROM public.menu_items WHERE id=NEW.menu_item_id;
 PERFORM pg_advisory_xact_lock(hashtextextended('invoice-profile:'||scope::text,0));
 IF NEW.tax_entity_id IS NULL THEN SELECT tax_entity_id INTO NEW.tax_entity_id FROM public.restaurants WHERE id=scope; END IF;
 IF EXISTS(SELECT 1 FROM public.menu_invoice_profiles p WHERE p.menu_item_id=NEW.menu_item_id AND p.id<>NEW.id
 AND tstzrange(p.effective_from,p.effective_to,'[)') && tstzrange(NEW.effective_from,NEW.effective_to,'[)')) THEN RAISE EXCEPTION 'INVOICE_PROFILE_HISTORY_OVERLAP'; END IF;
 ELSE
 PERFORM pg_advisory_xact_lock(hashtextextended('invoice-profile:'||NEW.store_id::text,0));
 IF EXISTS(SELECT 1 FROM public.item_type_invoice_profiles p WHERE p.store_id=NEW.store_id AND p.tax_entity_id=NEW.tax_entity_id AND p.item_type=NEW.item_type AND p.id<>NEW.id
 AND tstzrange(p.effective_from,p.effective_to,'[)') && tstzrange(NEW.effective_from,NEW.effective_to,'[)')) THEN RAISE EXCEPTION 'INVOICE_PROFILE_HISTORY_OVERLAP'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER menu_invoice_profile_period BEFORE INSERT OR UPDATE ON public.menu_invoice_profiles FOR EACH ROW EXECUTE FUNCTION public.check_invoice_profile_period();
CREATE TRIGGER item_type_invoice_profile_period BEFORE INSERT OR UPDATE ON public.item_type_invoice_profiles FOR EACH ROW EXECUTE FUNCTION public.check_invoice_profile_period();
REVOKE ALL ON FUNCTION public.check_invoice_profile_period() FROM PUBLIC,anon,authenticated;

-- One atomic, set-based batch, never one RPC per menu. Finite initial mappings
-- retain their one-day validity; an identical retry returns the same real ids.
CREATE FUNCTION public.approve_invoice_mapping_batch(p_store_id uuid,p_tax_entity_id uuid,p_rows jsonb) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'INVOICE_PROFILE_FORBIDDEN'; END IF;
 IF p_store_id IS NULL OR p_tax_entity_id IS NULL OR jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'INVOICE_PROFILE_BATCH_INVALID'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('invoice-profile:'||p_store_id::text,0));
 IF NOT EXISTS(SELECT 1 FROM public.restaurants WHERE id=p_store_id AND tax_entity_id=p_tax_entity_id) THEN RAISE EXCEPTION 'INVOICE_PROFILE_SCOPE_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_to_recordset(p_rows) x(approval_type text,menu_item_id uuid,item_type text,invoice_name_vi text,unit_name text,mapping_version text,source_reference text,effective_from timestamptz,effective_to timestamptz)
 WHERE approval_type IS NULL OR approval_type NOT IN('menu_item','item_type') OR length(btrim(COALESCE(invoice_name_vi,''))) NOT BETWEEN 1 AND 200
 OR length(btrim(COALESCE(unit_name,''))) NOT BETWEEN 1 AND 40 OR length(btrim(COALESCE(mapping_version,''))) NOT BETWEEN 1 AND 100 OR length(btrim(COALESCE(source_reference,''))) NOT BETWEEN 1 AND 500
 OR effective_from IS NULL OR effective_from>now() OR (effective_to IS NOT NULL AND effective_to<=effective_from)
 OR (approval_type='menu_item' AND (menu_item_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.menu_items m WHERE m.id=x.menu_item_id AND m.restaurant_id=p_store_id)))
 OR (approval_type='item_type' AND (menu_item_id IS NOT NULL OR item_type IS DISTINCT FROM 'wet_tissue_charge')))
 OR (SELECT count(DISTINCT COALESCE(x->>'menu_item_id',x->>'item_type')) FROM jsonb_array_elements(p_rows) x)<>jsonb_array_length(p_rows) THEN RAISE EXCEPTION 'INVOICE_PROFILE_BATCH_INVALID'; END IF;
 -- Close earlier open versions only for a new open-ended approval. Conflicting finite history is rejected by
 -- the common overlap trigger and rolls back the entire batch.
 WITH input AS(SELECT * FROM jsonb_to_recordset(p_rows) x(approval_type text,menu_item_id uuid,effective_from timestamptz,effective_to timestamptz))
 UPDATE public.menu_invoice_profiles p SET effective_to=x.effective_from FROM input x WHERE x.approval_type='menu_item' AND p.menu_item_id=x.menu_item_id AND p.effective_to IS NULL AND p.effective_from<x.effective_from AND x.effective_to IS NULL;
 WITH input AS(SELECT * FROM jsonb_to_recordset(p_rows) x(approval_type text,item_type text,effective_from timestamptz,effective_to timestamptz))
 UPDATE public.item_type_invoice_profiles p SET effective_to=x.effective_from FROM input x WHERE x.approval_type='item_type' AND p.store_id=p_store_id AND p.tax_entity_id=p_tax_entity_id AND p.item_type=x.item_type AND p.effective_to IS NULL AND p.effective_from<x.effective_from AND x.effective_to IS NULL;
 INSERT INTO public.menu_invoice_profiles(menu_item_id,tax_entity_id,invoice_name_vi,unit_name,mapping_version,source_reference,effective_from,effective_to)
 SELECT x.menu_item_id,p_tax_entity_id,btrim(x.invoice_name_vi),btrim(x.unit_name),x.mapping_version,x.source_reference,x.effective_from,x.effective_to
 FROM jsonb_to_recordset(p_rows) x(approval_type text,menu_item_id uuid,invoice_name_vi text,unit_name text,mapping_version text,source_reference text,effective_from timestamptz,effective_to timestamptz)
 WHERE x.approval_type='menu_item' AND NOT EXISTS(SELECT 1 FROM public.menu_invoice_profiles p WHERE p.menu_item_id=x.menu_item_id AND p.tax_entity_id=p_tax_entity_id AND p.invoice_name_vi=btrim(x.invoice_name_vi) AND p.unit_name=btrim(x.unit_name)
 AND p.mapping_version=x.mapping_version AND p.source_reference=x.source_reference AND p.effective_from=x.effective_from AND p.effective_to IS NOT DISTINCT FROM x.effective_to);
 INSERT INTO public.item_type_invoice_profiles(store_id,tax_entity_id,item_type,invoice_name_vi,unit_name,mapping_version,source_reference,effective_from,effective_to)
 SELECT p_store_id,p_tax_entity_id,x.item_type,btrim(x.invoice_name_vi),btrim(x.unit_name),x.mapping_version,x.source_reference,x.effective_from,x.effective_to
 FROM jsonb_to_recordset(p_rows) x(approval_type text,item_type text,invoice_name_vi text,unit_name text,mapping_version text,source_reference text,effective_from timestamptz,effective_to timestamptz)
 WHERE x.approval_type='item_type' AND NOT EXISTS(SELECT 1 FROM public.item_type_invoice_profiles p WHERE p.store_id=p_store_id AND p.tax_entity_id=p_tax_entity_id AND p.item_type=x.item_type AND p.invoice_name_vi=btrim(x.invoice_name_vi) AND p.unit_name=btrim(x.unit_name)
 AND p.mapping_version=x.mapping_version AND p.source_reference=x.source_reference AND p.effective_from=x.effective_from AND p.effective_to IS NOT DISTINCT FROM x.effective_to);
 UPDATE public.menu_items m SET invoice_name_vi=p.invoice_name_vi,invoice_unit_name=p.unit_name FROM(
 SELECT DISTINCT ON(profile.menu_item_id) profile.menu_item_id,profile.invoice_name_vi,profile.unit_name FROM public.menu_invoice_profiles profile
 WHERE profile.tax_entity_id=p_tax_entity_id AND profile.effective_from<=now() AND (profile.effective_to IS NULL OR now()<profile.effective_to)
 AND profile.menu_item_id IN(SELECT (r->>'menu_item_id')::uuid FROM jsonb_array_elements(p_rows) r WHERE r->>'approval_type'='menu_item')
 ORDER BY profile.menu_item_id,profile.effective_from DESC) p WHERE m.id=p.menu_item_id AND m.restaurant_id=p_store_id;
 WITH input AS(SELECT * FROM jsonb_to_recordset(p_rows) x(approval_type text,menu_item_id uuid,item_type text,effective_from timestamptz)), profiles AS(
 SELECT x.approval_type,p.id,p.menu_item_id,NULL::text item_type,p.mapping_version,p.effective_from,p.effective_to FROM input x JOIN public.menu_invoice_profiles p ON x.approval_type='menu_item' AND p.menu_item_id=x.menu_item_id AND p.effective_from=x.effective_from
 UNION ALL SELECT x.approval_type,p.id,NULL::uuid,p.item_type,p.mapping_version,p.effective_from,p.effective_to FROM input x JOIN public.item_type_invoice_profiles p ON x.approval_type='item_type' AND p.store_id=p_store_id AND p.tax_entity_id=p_tax_entity_id AND p.item_type=x.item_type AND p.effective_from=x.effective_from)
 SELECT jsonb_agg(to_jsonb(p) ORDER BY approval_type,COALESCE(menu_item_id::text,item_type)) INTO result FROM profiles p;
 RETURN jsonb_build_object('store_id',p_store_id,'tax_entity_id',p_tax_entity_id,'profiles',result);
END $$;
REVOKE ALL ON FUNCTION public.approve_invoice_mapping_batch(uuid,uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.approve_invoice_mapping_batch(uuid,uuid,jsonb) TO authenticated;

CREATE FUNCTION public.approve_menu_invoice_profile_v3(p_menu_item_id uuid,p_name text,p_unit text,p_effective_from timestamptz,p_effective_to timestamptz,p_mapping_version text,p_source_reference text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE store uuid; seller uuid;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'INVOICE_PROFILE_FORBIDDEN'; END IF;
 SELECT m.restaurant_id,r.tax_entity_id INTO store,seller FROM public.menu_items m JOIN public.restaurants r ON r.id=m.restaurant_id WHERE m.id=p_menu_item_id;
 IF store IS NULL THEN RAISE EXCEPTION 'INVOICE_PROFILE_SCOPE_INVALID'; END IF;
 RETURN public.approve_invoice_mapping_batch(store,seller,jsonb_build_array(jsonb_build_object('approval_type','menu_item','menu_item_id',p_menu_item_id,'invoice_name_vi',p_name,'unit_name',p_unit,
 'effective_from',p_effective_from,'effective_to',p_effective_to,'mapping_version',p_mapping_version,'source_reference',p_source_reference)));
END $$;
REVOKE ALL ON FUNCTION public.approve_menu_invoice_profile_v3(uuid,text,text,timestamptz,timestamptz,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.approve_menu_invoice_profile_v3(uuid,text,text,timestamptz,timestamptz,text,text) TO authenticated;

CREATE FUNCTION public.resolve_invoice_mapping_scope(p_tax_entity_id uuid,p_menu_ids uuid[],p_store_names text[]) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'INVOICE_PROFILE_FORBIDDEN'; END IF;
 IF p_tax_entity_id IS NULL OR COALESCE(cardinality(p_menu_ids),0)>100 OR COALESCE(cardinality(p_store_names),0)>100 THEN RAISE EXCEPTION 'INVOICE_PROFILE_BATCH_INVALID'; END IF;
 RETURN jsonb_build_object('menus',(SELECT COALESCE(jsonb_agg(jsonb_build_object('menu_item_id',m.id,'store_id',r.id,'store_name',r.name)),'[]') FROM public.menu_items m JOIN public.restaurants r ON r.id=m.restaurant_id WHERE m.id=ANY(p_menu_ids) AND r.tax_entity_id=p_tax_entity_id),
 'stores',(SELECT COALESCE(jsonb_agg(jsonb_build_object('store_id',id,'store_name',name)),'[]') FROM public.restaurants WHERE tax_entity_id=p_tax_entity_id AND name=ANY(p_store_names)));
END $$;
REVOKE ALL ON FUNCTION public.resolve_invoice_mapping_scope(uuid,uuid[],text[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.resolve_invoice_mapping_scope(uuid,uuid[],text[]) TO authenticated;

DO $single$ DECLARE d text; BEGIN
 SELECT pg_get_functiondef('public.approve_menu_invoice_profile(uuid,text,text,timestamptz)'::regprocedure) INTO d;
 IF strpos(d,' PERFORM 1 FROM public.menu_items WHERE id=p_menu_item_id FOR UPDATE;')=0 THEN RAISE EXCEPTION 'INVOICE_SINGLE_APPROVAL_ANCHOR_CHANGED'; END IF;
 d:=replace(d,' PERFORM 1 FROM public.menu_items WHERE id=p_menu_item_id FOR UPDATE;',
 ' PERFORM pg_advisory_xact_lock(hashtextextended(''invoice-profile:''||(SELECT restaurant_id::text FROM public.menu_items WHERE id=p_menu_item_id),0)); PERFORM 1 FROM public.menu_items WHERE id=p_menu_item_id FOR UPDATE;');
 EXECUTE d;
END $single$;

CREATE VIEW public.invoice_approved_profiles WITH(security_invoker=true) AS
 SELECT p.id,m.restaurant_id store_id,p.tax_entity_id,'menu_item'::text approval_type,p.menu_item_id,NULL::text item_type,p.invoice_name_vi,p.unit_name,p.mapping_version,p.source_reference,p.effective_from,p.effective_to FROM public.menu_invoice_profiles p JOIN public.menu_items m ON m.id=p.menu_item_id
 UNION ALL SELECT id,store_id,tax_entity_id,'item_type',NULL::uuid,item_type,invoice_name_vi,unit_name,mapping_version,source_reference,effective_from,effective_to FROM public.item_type_invoice_profiles;
REVOKE ALL ON public.invoice_approved_profiles FROM PUBLIC,anon,authenticated;

CREATE TABLE public.sales_external_reporting_protections(
 business_date date NOT NULL,tax_entity_id uuid NOT NULL REFERENCES public.tax_entity(id),source_system text NOT NULL CHECK(source_system IN('restaurant_pos','photo_objet_moers')),
 reported_receipt_count integer NOT NULL CHECK(reported_receipt_count>0),source_reference text NOT NULL,source_sha256 text NOT NULL CHECK(source_sha256~'^[a-f0-9]{64}$'),
 verification_state text NOT NULL DEFAULT 'user_provided_report' CHECK(verification_state='user_provided_report'),created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(business_date,tax_entity_id,source_system));
ALTER TABLE public.sales_external_reporting_protections ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sales_external_reporting_protections FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.sales_external_reporting_protections TO authenticated;
CREATE POLICY external_reporting_protections_read ON public.sales_external_reporting_protections FOR SELECT TO authenticated USING(public.is_super_admin());
-- The provided completion report is evidence for protection, not invented MISA
-- invoice numbers or a verified provider status. Scope is deliberately one day.
INSERT INTO public.sales_external_reporting_protections(business_date,tax_entity_id,source_system,reported_receipt_count,source_reference,source_sha256)
 SELECT DATE '2026-10-11',id,s.source_system,s.n,'01-pos-improvement-plan-2026-10-11.md / user provided completion report',
 '392d28bdf40c8064b13e1c44ac0268f3e4692aa6773922a5d43346ac26581c3c' FROM public.tax_entity CROSS JOIN (VALUES('restaurant_pos',105),('photo_objet_moers',464)) s(source_system,n)
 WHERE id='a6bda671-4179-5a29-a798-76357b42b497'::uuid;
CREATE FUNCTION public.sales_job_is_externally_reported(p_tax_entity_id uuid,p_source_system text,p_order_id uuid,p_source_snapshot jsonb) RETURNS boolean
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM public.sales_external_reporting_protections x WHERE x.tax_entity_id=p_tax_entity_id AND x.source_system=p_source_system
 AND x.business_date=CASE WHEN p_source_system='restaurant_pos' THEN
 (SELECT (max(created_at) AT TIME ZONE 'Asia/Ho_Chi_Minh')::date FROM public.payments WHERE order_id=p_order_id AND is_revenue)
 ELSE (NULLIF(p_source_snapshot->>'sale_date','')::timestamptz AT TIME ZONE 'Asia/Ho_Chi_Minh')::date END);
$$;
REVOKE ALL ON FUNCTION public.sales_job_is_externally_reported(uuid,text,uuid,jsonb) FROM PUBLIC,anon,authenticated;

-- Extend the existing scoped, batch SQL in place, with explicit fail-closed
-- anchors. Never mutate previously applied migration files.
DO $patch$ DECLARE d text; approved text; fields text; BEGIN
 SELECT pg_get_functiondef('public.pos_restaurant_receipt_rows_v2(date,uuid[])'::regprocedure) INTO d;
 approved:=$old$SELECT DISTINCT ON(item.id) item.id,profile.id profile_id,profile.invoice_name_vi,profile.unit_name
    FROM public.order_items item JOIN paid_orders scope ON scope.order_id=item.order_id
    JOIN public.menu_invoice_profiles profile ON profile.menu_item_id=item.menu_item_id
      AND profile.effective_from<=scope.sold_at AND (profile.effective_to IS NULL OR scope.sold_at<profile.effective_to)
    ORDER BY item.id,profile.effective_from DESC,profile.id DESC$old$;
 IF strpos(d,approved)=0 THEN RAISE EXCEPTION 'INVOICE_MAPPING_ROWS_ANCHOR_CHANGED'; END IF;
 d:=replace(d,approved,$new$SELECT DISTINCT ON(item.id) item.id,profile.id profile_id,profile.invoice_name_vi,profile.unit_name,profile.approval_type,profile.mapping_version,profile.source_reference,profile.effective_from,profile.effective_to,profile.store_id
    FROM public.order_items item JOIN paid_orders scope ON scope.order_id=item.order_id
    JOIN public.restaurants r ON r.id=scope.store_id LEFT JOIN latest_jobs j ON j.order_id=scope.order_id LEFT JOIN historical_entities h ON h.order_id=scope.order_id
    JOIN public.invoice_approved_profiles profile ON profile.store_id=scope.store_id AND profile.tax_entity_id=COALESCE(j.tax_entity_id,h.tax_entity_id,r.tax_entity_id)
    AND ((profile.approval_type='menu_item' AND profile.menu_item_id=item.menu_item_id) OR (profile.approval_type='item_type' AND item.menu_item_id IS NULL AND profile.item_type=item.item_type))
      AND profile.effective_from<=scope.sold_at AND (profile.effective_to IS NULL OR scope.sold_at<profile.effective_to)
    ORDER BY item.id,profile.effective_from DESC,profile.id DESC$new$);
 fields:=$new$'source_order_item_id',item.id,'invoice_approval_type',profile.approval_type,'invoice_mapping_version',profile.mapping_version,
      'invoice_source_reference',profile.source_reference,'invoice_effective_from',profile.effective_from,'invoice_effective_to',profile.effective_to,'invoice_store_id',profile.store_id,$new$;
 d:=replace(d,'''menu_item_id'',item.menu_item_id',fields||'''menu_item_id'',item.menu_item_id');
 EXECUTE d;
 -- Explicit original-source rebuild mode: never choose a v2+ stored snapshot.
 d:=replace(d,'CREATE OR REPLACE FUNCTION public.pos_restaurant_receipt_rows_v2(', 'CREATE OR REPLACE FUNCTION public.pos_restaurant_receipt_rows_fresh(');
 d:=replace(d,'job.snapshot_version>=2','false');
 d:=replace(d,'COALESCE(job.contact_locked,false)','false');
 EXECUTE d;
 -- Completion snapshots use the actual revenue payment sale time, not the
 -- enqueue wall clock. The fixture and production interfaces share these anchors.
 SELECT pg_get_functiondef('public.enqueue_meinvoice_cash_register_job()'::regprocedure) INTO d;
 approved := 'LEFT JOIN public.menu_invoice_profiles profile ON profile.menu_item_id=oi.menu_item_id AND profile.effective_from<=now() AND (profile.effective_to IS NULL OR now()<profile.effective_to)';
 IF strpos(d,approved)=0 OR strpos(d,'''invoice_profile_id'', profile.id')=0 THEN RAISE EXCEPTION 'INVOICE_MAPPING_ENQUEUE_ANCHOR_CHANGED'; END IF;
 d:=replace(d,approved,$new$CROSS JOIN (SELECT max(created_at) sold_at FROM public.payments WHERE order_id=NEW.id AND is_revenue) sale
 LEFT JOIN public.invoice_approved_profiles profile ON profile.store_id=(SELECT restaurant_id FROM public.orders WHERE id=NEW.id)
 AND profile.tax_entity_id=(SELECT tax_entity_id FROM public.restaurants WHERE id=profile.store_id)
 AND ((profile.approval_type='menu_item' AND profile.menu_item_id=oi.menu_item_id) OR (profile.approval_type='item_type' AND oi.menu_item_id IS NULL AND profile.item_type=oi.item_type))
 AND profile.effective_from<=sale.sold_at AND (profile.effective_to IS NULL OR sale.sold_at<profile.effective_to)$new$);
 d:=replace(d,'''invoice_profile_id'', profile.id', $new$'source_order_item_id',oi.id,'invoice_approval_type',profile.approval_type,'invoice_mapping_version',profile.mapping_version,
 'invoice_source_reference',profile.source_reference,'invoice_effective_from',profile.effective_from,'invoice_effective_to',profile.effective_to,'invoice_store_id',profile.store_id,'invoice_profile_id', profile.id$new$);
 EXECUTE d;
END $patch$;
REVOKE ALL ON FUNCTION public.pos_restaurant_receipt_rows_fresh(date,uuid[]) FROM PUBLIC,anon,authenticated;

-- No MISA I/O. Read-only local validator is also used in the write transaction.
CREATE FUNCTION public.invoice_snapshot_is_valid(p_lines jsonb,p_sold_at timestamptz) RETURNS boolean
 LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog AS $$
DECLARE l jsonb; k text; n numeric; totals jsonb:='{}'; rate text;
BEGIN
 IF p_sold_at IS NULL OR jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines)=0 THEN RETURN false; END IF;
 FOR l IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
  IF COALESCE(l->>'order_item_id','')='' OR COALESCE(l->>'invoice_profile_id','')='' OR COALESCE(l->>'invoice_store_id','')=''
  OR COALESCE(l->>'invoice_name_vi','')='' OR COALESCE(l->>'misa_unit_name','')='' OR COALESCE(l->>'invoice_mapping_version','')=''
  OR COALESCE(l->>'invoice_source_reference','')='' OR COALESCE(l->>'invoice_approval_type','') NOT IN('menu_item','item_type')
  OR (l->>'invoice_approval_type'='item_type' AND (l->>'item_type' IS DISTINCT FROM 'wet_tissue_charge' OR NULLIF(l->>'menu_item_id','') IS NOT NULL))
  OR (l->>'invoice_approval_type'='menu_item' AND NULLIF(l->>'menu_item_id','') IS NULL) THEN RETURN false; END IF;
  FOREACH k IN ARRAY ARRAY['quantity','unit_price','misa_unit_price','misa_discount_amount','total_amount_ex_tax','vat_rate','vat_amount'] LOOP
   n:=(l->>k)::numeric;
   IF n IS NULL OR n::text IN('NaN','Infinity','-Infinity') OR n<0 OR (k='quantity' AND n=0) OR (k='vat_rate' AND n>100) THEN RETURN false; END IF;
  END LOOP;
  IF abs((l->>'quantity')::numeric*(l->>'misa_unit_price')::numeric-(l->>'misa_discount_amount')::numeric-(l->>'total_amount_ex_tax')::numeric)>0.005
  OR round((l->>'total_amount_ex_tax')::numeric*(l->>'vat_rate')::numeric/100)<>round((l->>'vat_amount')::numeric)
  OR NULLIF(l->>'invoice_effective_from','') IS NULL OR (l->>'invoice_effective_from')::timestamptz>p_sold_at
  OR (NULLIF(l->>'invoice_effective_to','') IS NOT NULL AND p_sold_at>=(l->>'invoice_effective_to')::timestamptz) THEN RETURN false; END IF;
  rate:=l->>'vat_rate';
  totals:=jsonb_set(totals,ARRAY[rate],jsonb_build_object('supply',COALESCE((totals->rate->>'supply')::numeric,0)+(l->>'total_amount_ex_tax')::numeric,'vat',COALESCE((totals->rate->>'vat')::numeric,0)+(l->>'vat_amount')::numeric));
 END LOOP;
 RETURN NOT EXISTS(SELECT 1 FROM jsonb_each(totals) t WHERE round((t.value->>'supply')::numeric*t.key::numeric/100)<>round((t.value->>'vat')::numeric));
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR datetime_field_overflow THEN RETURN false;
END $$;
REVOKE ALL ON FUNCTION public.invoice_snapshot_is_valid(jsonb,timestamptz) FROM PUBLIC,anon,authenticated;
ALTER TABLE public.meinvoice_job_snapshot_versions ADD COLUMN revision_reason text NOT NULL DEFAULT 'explicit_pending_revalidation';
CREATE FUNCTION public.revalidate_meinvoice_export_snapshots(p_business_date date,p_tax_entity_id uuid,p_order_ids uuid[]) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb; scope jsonb; n integer;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_ONLY'; END IF;
 IF p_business_date IS NULL OR p_business_date<DATE '2020-01-01' OR p_business_date>(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date OR p_tax_entity_id IS NULL OR cardinality(p_order_ids) NOT BETWEEN 1 AND 100 OR p_order_ids IS NULL
 OR EXISTS(SELECT 1 FROM unnest(p_order_ids) x WHERE x IS NULL) OR cardinality(p_order_ids)<>(SELECT count(DISTINCT x) FROM unnest(p_order_ids) x) THEN RAISE EXCEPTION 'INVOICE_EXPORT_SCOPE_INVALID'; END IF;
 PERFORM 1 FROM public.meinvoice_jobs WHERE order_id=ANY(p_order_ids) ORDER BY id FOR UPDATE;
 SELECT count(*),jsonb_agg(to_jsonb(s)) INTO n,scope FROM public.pos_restaurant_receipt_rows_fresh(p_business_date,p_order_ids) s WHERE s.tax_entity_id=p_tax_entity_id;
 IF n<>cardinality(p_order_ids) THEN RAISE EXCEPTION 'INVOICE_EXPORT_SCOPE_CHANGED'; END IF;
 WITH input AS MATERIALIZED(SELECT * FROM jsonb_to_recordset(scope) s(receipt_id text,line_items jsonb,payment_method text,buyer_email text,buyer_phone text,payment_methods text[],sold_at timestamptz,gross_sales numeric)),
 decisions AS MATERIALIZED(SELECT j.id,s.receipt_id,s.line_items,s.payment_method,
 j.buyer_snapshot||jsonb_build_object('email',s.buyer_email,'phone',s.buyer_phone) buyer,
 CASE WHEN jsonb_typeof(j.payment_summary)='object' THEN j.payment_summary||jsonb_build_object('methods',to_jsonb(s.payment_methods)) ELSE j.payment_summary END payments,
 CASE WHEN j.id IS NULL THEN 'missing_job'
 WHEN EXISTS(SELECT 1 FROM public.sales_external_reporting_protections x WHERE x.business_date=p_business_date AND x.tax_entity_id=p_tax_entity_id AND x.source_system='restaurant_pos') THEN 'externally_reported'
 WHEN j.status NOT IN('pending_manual_config','dispatch_paused','pending') OR j.misa_ref_id IS NOT NULL OR j.invoice_number IS NOT NULL OR j.dispatch_claim_id IS NOT NULL OR COALESCE(j.dispatch_attempts,0)>0 THEN 'protected'
 WHEN s.payment_method='UNMAPPED' OR NOT public.invoice_snapshot_is_valid(s.line_items,s.sold_at)
 OR abs((SELECT sum((l->>'total_amount_ex_tax')::numeric+(l->>'vat_amount')::numeric) FROM jsonb_array_elements(s.line_items) l)-s.gross_sales)>0.005 THEN 'invalid_source'
 WHEN ROW(j.payment_method_snapshot,j.line_items_snapshot,j.buyer_snapshot,j.payment_summary) IS NOT DISTINCT FROM ROW(s.payment_method,s.line_items,j.buyer_snapshot||jsonb_build_object('email',s.buyer_email,'phone',s.buyer_phone),CASE WHEN jsonb_typeof(j.payment_summary)='object' THEN j.payment_summary||jsonb_build_object('methods',to_jsonb(s.payment_methods)) ELSE j.payment_summary END) THEN 'unchanged' ELSE 'updated' END outcome
 FROM input s LEFT JOIN public.meinvoice_jobs j ON j.order_id::text=s.receipt_id AND j.tax_entity_id=p_tax_entity_id AND j.source_system='restaurant_pos'),
 updated AS(UPDATE public.meinvoice_jobs j SET payment_method_snapshot=d.payment_method,line_items_snapshot=d.line_items,buyer_snapshot=d.buyer,payment_summary=d.payments,updated_at=now()
 FROM decisions d WHERE j.id=d.id AND d.outcome='updated' RETURNING j.id)
 SELECT jsonb_build_object('target_count',count(*),'updated_count',(SELECT count(*) FROM updated),'unchanged_count',count(*) FILTER(WHERE outcome='unchanged'),
 'protected_count',count(*) FILTER(WHERE outcome IN('protected','externally_reported')),'error_count',count(*) FILTER(WHERE outcome IN('invalid_source','missing_job')),
 'receipts',COALESCE(jsonb_agg(jsonb_build_object('receipt_id',receipt_id,'outcome',outcome) ORDER BY receipt_id),'[]')) INTO result FROM decisions;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.refresh_meinvoice_export_snapshots(p_business_date date,p_tax_entity_id uuid,p_order_ids uuid[]) RETURNS integer
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
BEGIN RETURN (public.revalidate_meinvoice_export_snapshots(p_business_date,p_tax_entity_id,p_order_ids)->>'updated_count')::integer; END $$;
REVOKE ALL ON FUNCTION public.revalidate_meinvoice_export_snapshots(date,uuid,uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.revalidate_meinvoice_export_snapshots(date,uuid,uuid[]) TO authenticated;

DO $guards$ DECLARE d text; BEGIN
 SELECT pg_get_functiondef('public.preserve_meinvoice_export_snapshot()'::regprocedure) INTO d;
 d:=replace(d,' IF OLD.status IN(', ' IF public.sales_job_is_externally_reported(OLD.tax_entity_id,OLD.source_system,OLD.order_id,OLD.source_snapshot) THEN RAISE EXCEPTION ''MEINVOICE_EXTERNALLY_REPORTED_IMMUTABLE''; END IF; IF OLD.status IN(');
 EXECUTE d;
 SELECT pg_get_functiondef('public.claim_meinvoice_jobs(uuid,integer,uuid)'::regprocedure) INTO d;
 IF strpos(d,'SELECT id FROM public.meinvoice_jobs WHERE')=0 THEN RAISE EXCEPTION 'INVOICE_MAPPING_CLAIM_ANCHOR_CHANGED'; END IF;
 d:=replace(d,'SELECT id FROM public.meinvoice_jobs WHERE','SELECT id FROM public.meinvoice_jobs j WHERE NOT public.sales_job_is_externally_reported(j.tax_entity_id,j.source_system,j.order_id,j.source_snapshot) AND');
 d:=replace(d,'snapshot_version>=2 AND', 'snapshot_version>=2 AND public.invoice_snapshot_is_valid(line_items_snapshot,COALESCE((SELECT max(p.created_at) FROM public.payments p WHERE p.order_id=j.order_id AND p.is_revenue),j.created_at)) AND');
 EXECUTE d;
END $guards$;
DO $verify$ BEGIN
 IF has_function_privilege('anon','public.approve_invoice_mapping_batch(uuid,uuid,jsonb)','EXECUTE') OR has_function_privilege('anon','public.revalidate_meinvoice_export_snapshots(date,uuid,uuid[])','EXECUTE')
 OR strpos(pg_get_functiondef('public.pos_restaurant_receipt_rows_fresh(date,uuid[])'::regprocedure),'job.snapshot_version>=2')>0
 OR strpos(pg_get_functiondef('public.claim_meinvoice_jobs(uuid,integer,uuid)'::regprocedure),'sales_job_is_externally_reported')=0 THEN RAISE EXCEPTION 'SALES_INVOICE_MAPPING_CONTRACT_DRIFT'; END IF;
END $verify$;
COMMIT;
