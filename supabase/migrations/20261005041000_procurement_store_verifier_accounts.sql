BEGIN;

-- production-gate: self-verifying
-- Keep the existing legal-entity accounting identity. Add a separate,
-- explicitly scoped store verifier through the fixed-account provisioning path.
DO $$
DECLARE
  v_name text;
  v_definition text;
  v_expression text;
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'store_fixed_account_requirements_type_check',
    'store_fixed_account_requirements_role_check',
    'store_fixed_account_requirements_role_type_check'
  ] LOOP
    SELECT pg_get_constraintdef(oid) INTO v_definition FROM pg_constraint
    WHERE conrelid='public.store_fixed_account_requirements'::regclass
      AND conname=v_name;
    v_expression := substring(v_definition FROM '^CHECK \((.*)\)$');
    IF v_expression IS NULL THEN
      RAISE EXCEPTION 'PROCUREMENT_FIXED_ACCOUNT_CONSTRAINT_MISSING: %',v_name;
    END IF;
    EXECUTE format('ALTER TABLE public.store_fixed_account_requirements DROP CONSTRAINT %I',v_name);
    EXECUTE format(
      'ALTER TABLE public.store_fixed_account_requirements ADD CONSTRAINT %I CHECK ((%s) OR (account_type=''inventory_accounting'' AND role=''inventory_accounting'' AND scope=''store''))',
      v_name,v_expression);
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_prepare_procurement_store_account(
  p_store_id uuid,p_account_code text,p_role text,p_display_name text,p_reason text
) RETURNS public.store_fixed_account_requirements
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,auth,pg_catalog
AS $$
DECLARE
  v_actor_id uuid;
  v_short text;
  v_code text := lower(btrim(p_account_code));
  v_existing public.store_fixed_account_requirements%ROWTYPE;
  v_result public.store_fixed_account_requirements%ROWTYPE;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'PROCUREMENT_ACCOUNT_PREPARATION_FORBIDDEN';
  END IF;
  SELECT id INTO v_actor_id FROM public.users
    WHERE auth_id=auth.uid() AND is_active;
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'PROCUREMENT_ACCOUNT_PREPARATION_FORBIDDEN';
  END IF;
  SELECT lower(short_code) INTO v_short FROM public.restaurants
    WHERE id=p_store_id AND is_active;
  IF NOT FOUND OR v_short IS NULL THEN
    RAISE EXCEPTION 'PROCUREMENT_ACCOUNT_ACTIVE_STORE_REQUIRED';
  END IF;
  IF p_role IS NULL OR p_role NOT IN ('inventory_orderer','inventory_accounting')
     OR v_code IS NULL OR v_code !~ '^[a-z][a-z0-9_]{1,31}$'
     OR left(v_code,length(v_short)+1)<>v_short||'_'
     OR NULLIF(btrim(p_display_name),'') IS NULL
     OR NULLIF(btrim(p_reason),'') IS NULL THEN
    RAISE EXCEPTION 'PROCUREMENT_ACCOUNT_INPUT_INVALID';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('procurement_fixed_account'),hashtext(v_code));
  IF EXISTS(SELECT 1 FROM public.store_fixed_account_requirements
      WHERE lower(account_code)=v_code AND store_id<>p_store_id) THEN
    RAISE EXCEPTION 'PROCUREMENT_ACCOUNT_CODE_SCOPE_CONFLICT';
  END IF;
  SELECT * INTO v_existing FROM public.store_fixed_account_requirements
    WHERE store_id=p_store_id AND account_code=v_code FOR UPDATE;
  IF FOUND AND (v_existing.account_type<>p_role OR v_existing.role<>p_role
      OR v_existing.scope<>'store' OR NOT v_existing.is_active) THEN
    RAISE EXCEPTION 'PROCUREMENT_ACCOUNT_IDENTITY_CONFLICT';
  END IF;
  IF EXISTS(SELECT 1 FROM public.users u WHERE lower(u.fixed_account_code)=v_code
      AND (v_existing.provisioned_user_id IS NULL
           OR u.id<>v_existing.provisioned_user_id OR u.role<>p_role
           OR u.account_type<>p_role OR NOT u.is_active)) THEN
    RAISE EXCEPTION 'PROCUREMENT_ACCOUNT_IDENTITY_CONFLICT';
  END IF;
  IF v_existing.provisioned_user_id IS NOT NULL
     AND v_existing.display_name<>btrim(p_display_name) THEN
    RAISE EXCEPTION 'PROCUREMENT_ACCOUNT_PROVISIONED_IDENTITY_IMMUTABLE';
  END IF;
  INSERT INTO public.store_fixed_account_requirements(
    store_id,account_code,account_type,role,display_name,scope
  ) VALUES(p_store_id,v_code,p_role,p_role,btrim(p_display_name),'store')
  ON CONFLICT(store_id,account_code) DO UPDATE SET
    display_name=EXCLUDED.display_name,updated_at=now()
  RETURNING * INTO v_result;
  INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
  VALUES(v_actor_id,'prepare_procurement_account','store_fixed_account_requirement',
    v_result.id,jsonb_build_object('store_id',p_store_id,'account_code',v_code,
      'role',p_role,'reason',btrim(p_reason),'auth_provisioned',false));
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_prepare_procurement_store_account(uuid,text,text,text,text)
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.admin_prepare_procurement_store_account(uuid,text,text,text,text)
  TO authenticated;

DO $$
BEGIN
  IF position('PROCUREMENT_ACCOUNT_PREPARATION_FORBIDDEN' IN pg_get_functiondef(
      'public.admin_prepare_procurement_store_account(uuid,text,text,text,text)'::regprocedure))=0
     OR NOT EXISTS(SELECT 1 FROM pg_constraint
       WHERE conrelid='public.store_fixed_account_requirements'::regclass
       AND conname='store_fixed_account_requirements_role_type_check'
       AND pg_get_constraintdef(oid) LIKE '%inventory_accounting%') THEN
    RAISE EXCEPTION 'PROCUREMENT_STORE_ACCOUNT_CONTRACT_FAILED';
  END IF;
END;
$$;
COMMIT;
