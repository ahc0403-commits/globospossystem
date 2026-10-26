-- Explicit per-store configuration; does not enable stores automatically.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';

CREATE TABLE public.company_tax_lookup_setting_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  actor_auth_id uuid NOT NULL,
  previous_enabled boolean,
  enabled boolean NOT NULL,
  changed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE public.company_tax_lookup_setting_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.company_tax_lookup_setting_events FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.company_tax_lookup_setting_events TO service_role;

CREATE FUNCTION public.pos_company_tax_lookup_status(p_store_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE actor_role text; setting boolean;
BEGIN
  SELECT role INTO actor_role FROM public.users
    WHERE auth_id = auth.uid() AND is_active LIMIT 1;
  IF actor_role IS NULL OR actor_role NOT IN ('cashier','admin','store_admin','brand_admin','super_admin')
    OR NOT EXISTS (SELECT 1 FROM public.restaurants WHERE id=p_store_id AND is_active)
    OR (actor_role <> 'super_admin' AND NOT EXISTS (
      SELECT 1 FROM public.user_accessible_stores(auth.uid()) scope(store_id)
      WHERE scope.store_id=p_store_id
    )) THEN RETURN jsonb_build_object('outcome','forbidden'); END IF;
  SELECT enabled INTO setting FROM public.company_tax_lookup_settings WHERE store_id=p_store_id;
  RETURN jsonb_build_object('outcome',CASE WHEN setting IS TRUE THEN 'enabled' ELSE 'disabled' END,
    'configured',setting IS NOT NULL,'can_manage',actor_role='super_admin');
END; $$;

CREATE FUNCTION public.pos_set_company_tax_lookup(p_store_id uuid,p_enabled boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE previous boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE auth_id=auth.uid() AND is_active AND role='super_admin')
    THEN RAISE EXCEPTION 'COMPANY_LOOKUP_FORBIDDEN' USING ERRCODE='42501'; END IF;
  IF p_enabled IS NULL THEN RAISE EXCEPTION 'COMPANY_LOOKUP_INVALID_SETTING'; END IF;
  -- Serializes first creation and later changes for this one store.
  PERFORM 1 FROM public.restaurants WHERE id=p_store_id AND is_active FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'COMPANY_LOOKUP_STORE_UNAVAILABLE'; END IF;
  SELECT enabled INTO previous FROM public.company_tax_lookup_settings WHERE store_id=p_store_id;
  IF previous IS DISTINCT FROM p_enabled THEN
    INSERT INTO public.company_tax_lookup_settings(store_id,enabled) VALUES(p_store_id,p_enabled)
      ON CONFLICT(store_id) DO UPDATE SET enabled=EXCLUDED.enabled;
    INSERT INTO public.company_tax_lookup_setting_events(store_id,actor_auth_id,previous_enabled,enabled)
      VALUES(p_store_id,auth.uid(),previous,p_enabled);
  END IF;
  RETURN public.pos_company_tax_lookup_status(p_store_id);
END; $$;

REVOKE ALL ON FUNCTION public.pos_company_tax_lookup_status(uuid),
  public.pos_set_company_tax_lookup(uuid,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pos_company_tax_lookup_status(uuid),
  public.pos_set_company_tax_lookup(uuid,boolean) TO authenticated;
DO $$ BEGIN
  IF has_function_privilege('anon','public.pos_company_tax_lookup_status(uuid)','EXECUTE')
    OR has_function_privilege('anon','public.pos_set_company_tax_lookup(uuid,boolean)','EXECUTE')
    OR has_table_privilege('authenticated','public.company_tax_lookup_settings','SELECT')
    OR has_table_privilege('authenticated','public.company_tax_lookup_setting_events','INSERT')
    OR NOT has_function_privilege('authenticated','public.pos_company_tax_lookup_status(uuid)','EXECUTE')
    THEN RAISE EXCEPTION 'COMPANY_LOOKUP_CONFIGURATION_ACL_DRIFT'; END IF;
END; $$;
COMMIT;
