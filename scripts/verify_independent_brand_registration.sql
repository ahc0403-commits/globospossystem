-- Read-only postconditions, suitable for the official production release gate.
DO $verify$
DECLARE v_signature text; v_oid oid;
BEGIN
  FOREACH v_signature IN ARRAY ARRAY[
    'public.admin_brand_groups_v1()',
    'public.admin_list_brands_v1(text,text,uuid,integer)',
    'public.admin_create_brand_v1(uuid,text,text,uuid,uuid[])',
    'public.admin_link_brand_tax_entities_v1(uuid,uuid[])'
  ] LOOP
    v_oid := to_regprocedure(v_signature);
    IF v_oid IS NULL OR NOT EXISTS(SELECT FROM pg_proc WHERE oid=v_oid AND prosecdef) THEN
      RAISE EXCEPTION 'BRAND_VERIFY_RPC_MISSING_OR_UNGUARDED:%',v_signature;
    END IF;
    IF NOT has_function_privilege('authenticated',v_oid,'EXECUTE')
      OR has_function_privilege('anon',v_oid,'EXECUTE')
      OR EXISTS(SELECT FROM pg_proc p,LATERAL aclexplode(COALESCE(p.proacl,acldefault('f',p.proowner))) acl
        WHERE p.oid=v_oid AND acl.grantee=0 AND acl.privilege_type='EXECUTE') THEN
      RAISE EXCEPTION 'BRAND_VERIFY_RPC_ACL_INVALID:%',v_signature;
    END IF;
    IF strpos(pg_get_functiondef(v_oid),'public.require_brand_admin_v1()')=0 THEN
      RAISE EXCEPTION 'BRAND_VERIFY_AUTHORIZATION_MISSING:%',v_signature;
    END IF;
  END LOOP;
  v_oid := to_regprocedure('public.require_brand_admin_v1()');
  IF v_oid IS NULL OR has_function_privilege('authenticated',v_oid,'EXECUTE')
    OR has_function_privilege('anon',v_oid,'EXECUTE') THEN
    RAISE EXCEPTION 'BRAND_VERIFY_PRIVATE_HELPER_ACL_INVALID';
  END IF;
  IF NOT EXISTS(SELECT FROM pg_class WHERE oid='public.brands'::regclass AND relrowsecurity)
    OR NOT EXISTS(SELECT FROM pg_class WHERE oid='public.tax_entity_brands'::regclass AND relrowsecurity) THEN
    RAISE EXCEPTION 'BRAND_VERIFY_RLS_REQUIRED';
  END IF;
  IF to_regclass('public.brands_name_id_page_idx') IS NULL
    OR to_regclass('public.tax_entity_brands_brand_lookup_idx') IS NULL THEN
    RAISE EXCEPTION 'BRAND_VERIFY_PAGE_INDEX_MISSING';
  END IF;
  IF EXISTS(SELECT FROM public.restaurants r LEFT JOIN public.tax_entity_brands l
    ON (l.tax_entity_id,l.brand_id)=(r.tax_entity_id,r.brand_id) WHERE l.brand_id IS NULL) THEN
    RAISE EXCEPTION 'BRAND_VERIFY_STORE_HIERARCHY_INVALID';
  END IF;
END;
$verify$;
SELECT 'BRAND_VERIFICATION_PASS' AS result,
  (SELECT count(*) FROM public.brands) AS brands,
  (SELECT count(*) FROM public.restaurants) AS stores,
  (SELECT count(*) FROM public.tax_entity_brands) AS legal_entity_links;
