-- A legal/brand transfer is an explicit closed-store operation. It retains IDs,
-- issued documents and effective legal history, and requires reopening checks.
-- production-gate: self-verifying
BEGIN;
CREATE TABLE public.store_identity_transfers (
 id uuid PRIMARY KEY,restaurant_id uuid NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
 source_brand uuid,source_entity uuid,target_brand uuid NOT NULL,target_entity uuid NOT NULL,
 expected_revision bigint NOT NULL,input_hash text NOT NULL,evidence jsonb NOT NULL,previous_scope jsonb NOT NULL,
 actor_id uuid NOT NULL,transaction_id bigint NOT NULL,effective_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX store_identity_transfers_store ON public.store_identity_transfers(restaurant_id,effective_at DESC,id DESC);
ALTER TABLE public.store_identity_transfers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.store_identity_transfers FROM PUBLIC,anon,authenticated;
CREATE TRIGGER store_identity_transfers_immutable BEFORE UPDATE ON public.store_identity_transfers FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE OR REPLACE FUNCTION public.store_guard_registered_identity_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF (NEW.brand_id,NEW.tax_entity_id,NEW.short_code) IS DISTINCT FROM (OLD.brand_id,OLD.tax_entity_id,OLD.short_code)
 AND ((NEW.brand_id,NEW.tax_entity_id) IS DISTINCT FROM (OLD.brand_id,OLD.tax_entity_id) OR EXISTS(SELECT 1 FROM store_account_onboarding_jobs WHERE store_id=OLD.id))
 AND NOT (NEW.short_code IS NOT DISTINCT FROM OLD.short_code AND EXISTS(SELECT 1 FROM store_identity_transfers t WHERE t.restaurant_id=OLD.id AND t.transaction_id=txid_current() AND t.actor_id=auth.uid() AND (t.source_brand,t.source_entity,t.target_brand,t.target_entity) IS NOT DISTINCT FROM (OLD.brand_id,OLD.tax_entity_id,NEW.brand_id,NEW.tax_entity_id))) THEN RAISE EXCEPTION 'STORE_REGISTERED_IDENTITY_FROZEN'; END IF;
 RETURN NEW;
END $$;
CREATE FUNCTION public.admin_get_store_transfer_options_v1(p_store uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 PERFORM require_brand_admin_v1();
 IF (SELECT count(*) FROM tax_entity_brands)>500 THEN RAISE EXCEPTION 'STORE_TRANSFER_SCOPE_LIMIT'; END IF;
 RETURN jsonb_build_object('current',(SELECT jsonb_build_object('brand_id',brand_id,'tax_entity_id',tax_entity_id,'name',name) FROM restaurants WHERE id=p_store),
 'targets',(SELECT jsonb_agg(jsonb_build_object('brand_id',b.id,'brand_name',b.name,'entity_id',e.id,'entity_name',e.name) ORDER BY b.name,e.name) FROM tax_entity_brands t JOIN brands b ON b.id=t.brand_id JOIN tax_entity e ON e.id=t.tax_entity_id));
END $$;
CREATE FUNCTION public.admin_transfer_store_identity_v1(p_id uuid,p_store uuid,p_expected_revision bigint,p_brand uuid,p_entity uuid,p_evidence jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE old restaurants; lifecycle store_lifecycle; prior store_identity_transfers; hash text; pending jsonb; previous jsonb; replacement jsonb; actor uuid; effective_time timestamptz:=clock_timestamp();
BEGIN
 PERFORM require_brand_admin_v1();
 IF p_id IS NULL OR jsonb_typeof(p_evidence) IS DISTINCT FROM 'object' OR octet_length(p_evidence::text)>8192 OR length(btrim(coalesce(p_evidence->>'reason','')))<5 OR length(btrim(coalesce(p_evidence->>'scope_review','')))<5 THEN RAISE EXCEPTION 'STORE_TRANSFER_EVIDENCE_REQUIRED'; END IF;
 hash:=md5(jsonb_build_array(p_store,p_expected_revision,p_brand,p_entity,p_evidence,auth.uid())::text);
 PERFORM pg_advisory_xact_lock(hashtextextended('store-opening:'||p_store,0));
 SELECT * INTO prior FROM store_identity_transfers WHERE id=p_id;
 IF FOUND THEN IF prior.input_hash<>hash THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF; RETURN p_id; END IF;
 SELECT * INTO lifecycle FROM store_lifecycle WHERE restaurant_id=p_store FOR UPDATE;
 SELECT * INTO old FROM restaurants WHERE id=p_store FOR UPDATE;
 IF lifecycle.state IS DISTINCT FROM 'closed' OR lifecycle.revision IS DISTINCT FROM p_expected_revision OR old.is_active IS DISTINCT FROM false THEN RAISE EXCEPTION 'STORE_TRANSFER_REQUIRES_CLOSED'; END IF;
 IF (p_brand,p_entity) IS NOT DISTINCT FROM (old.brand_id,old.tax_entity_id) OR NOT EXISTS(SELECT 1 FROM tax_entity_brands WHERE brand_id=p_brand AND tax_entity_id=p_entity) THEN RAISE EXCEPTION 'STORE_TRANSFER_TARGET_INVALID'; END IF;
 pending:=store_closure_pending_v1(p_store);
 IF EXISTS(SELECT 1 FROM jsonb_each_text(pending)x WHERE x.value::bigint>0) THEN RAISE EXCEPTION 'STORE_CLOSURE_PENDING'; END IF;
 -- A shared brand login must already exist in the destination; it is never
 -- renamed or moved away from the previous brand's other stores.
 WITH candidates AS(SELECT DISTINCT ON(q.id) q.id requirement_id,u.id user_id,u.fixed_account_code code,u.full_name name FROM store_fixed_account_requirements q
 JOIN users u ON u.brand_id=p_brand AND u.role=q.role AND u.account_type=q.account_type AND u.is_active AND u.auth_id IS NOT NULL AND u.fixed_account_code IS NOT NULL
 WHERE q.store_id=p_store AND q.scope='brand' AND q.is_active ORDER BY q.id,u.id)
 SELECT coalesce(jsonb_agg(to_jsonb(c)),'[]') INTO replacement FROM candidates c;
 IF p_brand<>old.brand_id AND jsonb_array_length(replacement)<>(SELECT count(*) FROM store_fixed_account_requirements WHERE store_id=p_store AND scope='brand' AND is_active) THEN RAISE EXCEPTION 'STORE_TRANSFER_TARGET_BRAND_ACCOUNTS_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM store_external_links WHERE restaurant_id=p_store) OR EXISTS(SELECT 1 FROM inventory_products WHERE restaurant_id=p_store AND is_active AND is_orderable) THEN
  IF nullif(p_evidence->>'office_store_id','') IS NULL OR length(btrim(coalesce(p_evidence->>'office_contract_version','')))<1 OR length(btrim(coalesce(p_evidence->>'office_evidence','')))<5 THEN RAISE EXCEPTION 'STORE_TRANSFER_OFFICE_EVIDENCE_REQUIRED'; END IF;
 END IF;
 SELECT jsonb_build_object('procurement_role_roster',(SELECT jsonb_agg(to_jsonb(rr)) FROM procurement_role_roster rr WHERE restaurant_id=p_store),'requirements',(SELECT jsonb_agg(to_jsonb(q) ORDER BY id) FROM store_fixed_account_requirements q WHERE store_id=p_store),'external_links',(SELECT jsonb_agg(to_jsonb(l)) FROM store_external_links l WHERE restaurant_id=p_store)) INTO previous;
 INSERT INTO store_identity_transfers VALUES(p_id,p_store,old.brand_id,old.tax_entity_id,p_brand,p_entity,p_expected_revision,hash,p_evidence,previous,auth.uid(),txid_current(),effective_time);
 SELECT id INTO actor FROM users WHERE auth_id=auth.uid();
 UPDATE restaurants SET brand_id=p_brand,tax_entity_id=p_entity,store_type=(SELECT CASE owner_type WHEN 'internal' THEN 'direct' ELSE 'external' END FROM tax_entity WHERE id=p_entity) WHERE id=p_store;
 IF old.tax_entity_id IS DISTINCT FROM p_entity THEN
  UPDATE store_tax_entity_history SET effective_to=effective_time WHERE store_id=p_store AND effective_to IS NULL;
  INSERT INTO store_tax_entity_history(store_id,tax_entity_id,effective_from,reason,created_by) VALUES(p_store,p_entity,effective_time,'store_identity_transfer:'||p_id,actor);
 END IF;
 UPDATE user_store_access SET is_active=false,updated_at=now() WHERE store_id=p_store;
 -- Preserve the previous grants in the transfer audit, then require explicit
 -- provisioning for the destination organization, including future grants.
 DELETE FROM procurement_role_roster WHERE restaurant_id=p_store;
 UPDATE procurement_store_onboarding SET office_connected=false WHERE restaurant_id=p_store;
 UPDATE user_tax_entity_access SET is_active=false,updated_at=now() WHERE user_id IN(SELECT provisioned_user_id FROM store_fixed_account_requirements WHERE store_id=p_store AND scope='store');
 IF p_brand IS DISTINCT FROM old.brand_id THEN
  UPDATE user_brand_access a SET is_active=false,updated_at=now() WHERE a.user_id IN(SELECT provisioned_user_id FROM store_fixed_account_requirements WHERE store_id=p_store AND scope='store');
  UPDATE users u SET brand_id=p_brand WHERE u.id IN(SELECT provisioned_user_id FROM store_fixed_account_requirements WHERE store_id=p_store AND scope='store') AND (u.restaurant_id=p_store OR u.primary_store_id=p_store);
  UPDATE store_fixed_account_requirements q SET provisioned_user_id=(x->>'user_id')::uuid,account_code=x->>'code',display_name=x->>'name',updated_at=now() FROM jsonb_array_elements(replacement)x WHERE q.id=(x->>'requirement_id')::uuid;
  INSERT INTO user_store_access(user_id,store_id,is_active,source_type) SELECT (x->>'user_id')::uuid,p_store,false,'direct' FROM jsonb_array_elements(replacement)x ON CONFLICT(user_id,store_id,source_type) DO UPDATE SET is_active=false,updated_at=now();
  UPDATE inventory_products SET brand_id=p_brand WHERE restaurant_id=p_store;
 END IF;
 DELETE FROM store_external_links WHERE restaurant_id=p_store;
 IF nullif(p_evidence->>'office_store_id','') IS NOT NULL THEN INSERT INTO store_external_links(restaurant_id,provider,external_id,tax_entity_id,contract_version,evidence_reference,verified_by) VALUES(p_store,'office',(p_evidence->>'office_store_id')::uuid,p_entity,p_evidence->>'office_contract_version',p_evidence->>'office_evidence',auth.uid()); END IF;
 UPDATE store_lifecycle SET revision=revision+1,changed_by=auth.uid(),changed_at=now(),activated_source_hash=NULL WHERE restaurant_id=p_store;
 PERFORM store_refresh_closed_claims_v1(p_store);
 RETURN p_id;
END $$;
-- Every transferred store must review purchasing under the new ownership before
-- accepting a new PR/PO. Historical approvals remain immutable.
CREATE FUNCTION public.store_transfer_procurement_ready_v1(p_stores uuid[]) RETURNS TABLE(store_id uuid,ready boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH moved AS(SELECT restaurant_id,max(effective_at) at FROM store_identity_transfers WHERE restaurant_id=ANY(p_stores) GROUP BY restaurant_id),
 approvals AS(SELECT a.product_id,max(approved_at) at FROM procurement_catalog_approvals a WHERE restaurant_id=ANY(p_stores) GROUP BY product_id)
 SELECT s,NOT EXISTS(SELECT 1 FROM moved m JOIN inventory_products p ON p.restaurant_id=m.restaurant_id AND p.is_active AND p.is_orderable LEFT JOIN approvals a ON a.product_id=p.id WHERE m.restaurant_id=s AND (a.at IS NULL OR a.at<m.at)) FROM unnest(p_stores)s;
$$;
ALTER FUNCTION public.store_procurement_readiness_v1(uuid[]) RENAME TO store_procurement_readiness_before_transfer;
REVOKE ALL ON FUNCTION public.store_procurement_readiness_before_transfer(uuid[]) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.store_procurement_readiness_v1(p_stores uuid[]) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE result jsonb;
BEGIN
 result:=store_procurement_readiness_before_transfer(p_stores);
 RETURN(SELECT jsonb_agg(x||jsonb_build_object('checks',x->'checks'||jsonb_build_object('identity_transfer_review',t.ready),'ready',(x->>'ready')::boolean AND t.ready) ORDER BY x->>'id') FROM jsonb_array_elements(result)x JOIN store_transfer_procurement_ready_v1(p_stores)t ON t.store_id=(x->>'id')::uuid);
END $$;
DO $$ DECLARE d text; BEGIN
 d:=pg_get_functiondef('public.store_guard_closed_procurement_v1()'::regprocedure);
 d:=replace(d,' RETURN NULL;', ' IF EXISTS(SELECT 1 FROM store_transfer_procurement_ready_v1(ARRAY(SELECT DISTINCT restaurant_id FROM new_procurement_intake)) WHERE NOT ready) THEN RAISE EXCEPTION ''STORE_TRANSFER_PROCUREMENT_REVIEW_REQUIRED''; END IF; RETURN NULL;'); EXECUTE d;
END $$;
REVOKE ALL ON FUNCTION public.store_transfer_procurement_ready_v1(uuid[]),public.store_procurement_readiness_v1(uuid[]) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.admin_get_store_transfer_options_v1(uuid),public.admin_transfer_store_identity_v1(uuid,uuid,bigint,uuid,uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_get_store_transfer_options_v1(uuid),public.admin_transfer_store_identity_v1(uuid,uuid,bigint,uuid,uuid,jsonb) TO authenticated;
COMMIT;
