BEGIN;

-- 1. Helper functions
CREATE OR REPLACE FUNCTION public.get_user_tax_entity_id()
RETURNS uuid AS $$
  SELECT r.tax_entity_id
  FROM users u
  JOIN restaurants r ON r.id = u.restaurant_id
  WHERE u.auth_id = auth.uid() AND u.is_active = TRUE
  LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth;

COMMENT ON FUNCTION public.get_user_tax_entity_id() IS
  'Returns the tax_entity_id of the current user''s store. Enables tax-axis RLS for WeTax tables.';

CREATE OR REPLACE FUNCTION public.get_user_store_id()
RETURNS uuid AS $$
  SELECT public.get_user_restaurant_id();
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth;

COMMENT ON FUNCTION public.get_user_store_id() IS
  'Compatibility wrapper over get_user_restaurant_id() during store/restaurant coexistence.';

CREATE OR REPLACE FUNCTION public.user_accessible_stores(uid uuid)
RETURNS SETOF uuid AS $$
  SELECT restaurant_id FROM users WHERE auth_id = uid AND is_active = TRUE;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.user_accessible_tax_entities(uid uuid)
RETURNS SETOF uuid AS $$
  SELECT DISTINCT r.tax_entity_id
  FROM users u
  JOIN restaurants r ON r.id = u.restaurant_id
  WHERE u.auth_id = uid AND u.is_active = TRUE AND r.tax_entity_id IS NOT NULL;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth;

-- 2. Auth hook
CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb AS $$
DECLARE
  v_uid            uuid;
  v_user           users%ROWTYPE;
  v_store_ids      uuid[];
  v_tax_entity_ids uuid[];
BEGIN
  v_uid := (event->>'user_id')::uuid;
  SELECT * INTO v_user FROM users WHERE auth_id = v_uid AND is_active = TRUE LIMIT 1;
  IF NOT FOUND THEN RETURN event; END IF;
  v_store_ids      := ARRAY(SELECT * FROM user_accessible_stores(v_uid));
  v_tax_entity_ids := ARRAY(SELECT * FROM user_accessible_tax_entities(v_uid));
  event := jsonb_set(event, '{claims,app_metadata,role}', to_jsonb(v_user.role), true);
  event := jsonb_set(event, '{claims,app_metadata,accessible_store_ids}', to_jsonb(v_store_ids), true);
  event := jsonb_set(event, '{claims,app_metadata,accessible_tax_entity_ids}', to_jsonb(v_tax_entity_ids), true);
  RETURN event;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, auth;

GRANT EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) TO supabase_auth_admin;
REVOKE EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) FROM authenticated, anon, PUBLIC;

COMMENT ON FUNCTION public.custom_access_token_hook(jsonb) IS
  'Supabase custom access token hook. Populates app_metadata: role, accessible_store_ids[], accessible_tax_entity_ids[]. Register in Dashboard → Authentication → Hooks → Custom Access Token Hook.';

-- 3.1 brand_master
CREATE POLICY "brand_master_admin_read" ON public.brand_master
  FOR SELECT USING (is_super_admin() OR has_any_role(ARRAY['admin']));
CREATE POLICY "brand_master_superadmin_write" ON public.brand_master
  FOR ALL USING (is_super_admin()) WITH CHECK (is_super_admin());

-- 3.2 tax_entity
CREATE POLICY "tax_entity_admin_read" ON public.tax_entity
  FOR SELECT USING (is_super_admin() OR has_any_role(ARRAY['admin']));
CREATE POLICY "tax_entity_superadmin_write" ON public.tax_entity
  FOR ALL USING (is_super_admin()) WITH CHECK (is_super_admin());

-- 3.3 einvoice_shop
CREATE POLICY "einvoice_shop_admin_read" ON public.einvoice_shop
  FOR SELECT USING (is_super_admin() OR has_any_role(ARRAY['admin']));
CREATE POLICY "einvoice_shop_superadmin_write" ON public.einvoice_shop
  FOR ALL USING (is_super_admin()) WITH CHECK (is_super_admin());

-- 3.4 partner_credentials — intentionally no policies (L2 isolation; service_role bypasses RLS)

-- 3.5 wetax_reference_values
CREATE POLICY "wetax_ref_authenticated_read" ON public.wetax_reference_values
  FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "wetax_ref_superadmin_write" ON public.wetax_reference_values
  FOR ALL USING (is_super_admin()) WITH CHECK (is_super_admin());

-- 3.6 system_config
CREATE POLICY "system_config_admin_read" ON public.system_config
  FOR SELECT USING (is_super_admin() OR has_any_role(ARRAY['admin']));
CREATE POLICY "system_config_superadmin_write" ON public.system_config
  FOR ALL USING (is_super_admin()) WITH CHECK (is_super_admin());

-- 3.7 b2b_buyer_cache
CREATE POLICY "b2b_buyer_cache_store_select" ON public.b2b_buyer_cache
  FOR SELECT USING (
    is_super_admin() OR
    (has_any_role(ARRAY['cashier','admin']) AND (
      store_id = get_user_store_id() OR
      tax_entity_id = get_user_tax_entity_id()
    ))
  );
CREATE POLICY "b2b_buyer_cache_store_insert" ON public.b2b_buyer_cache
  FOR INSERT WITH CHECK (
    is_super_admin() OR
    (has_any_role(ARRAY['cashier','admin']) AND store_id = get_user_store_id())
  );
CREATE POLICY "b2b_buyer_cache_store_update" ON public.b2b_buyer_cache
  FOR UPDATE
  USING (is_super_admin() OR (has_any_role(ARRAY['cashier','admin']) AND store_id = get_user_store_id()))
  WITH CHECK (is_super_admin() OR (has_any_role(ARRAY['cashier','admin']) AND store_id = get_user_store_id()));
CREATE POLICY "b2b_buyer_cache_admin_delete" ON public.b2b_buyer_cache
  FOR DELETE USING (is_super_admin() OR (has_any_role(ARRAY['admin']) AND store_id = get_user_store_id()));

-- 3.8 store_tax_entity_history
CREATE POLICY "store_tax_history_admin_read" ON public.store_tax_entity_history
  FOR SELECT USING (is_super_admin() OR (has_any_role(ARRAY['admin']) AND store_id = get_user_store_id()));
CREATE POLICY "store_tax_history_superadmin_insert" ON public.store_tax_entity_history
  FOR INSERT WITH CHECK (is_super_admin());
CREATE POLICY "store_tax_history_superadmin_update" ON public.store_tax_entity_history
  FOR UPDATE USING (is_super_admin()) WITH CHECK (is_super_admin());
-- No DELETE: enforces append-only (Invariant I5)

-- 3.9 einvoice_jobs (crossing table — operational OR tax axis)
CREATE POLICY "einvoice_jobs_admin_read" ON public.einvoice_jobs
  FOR SELECT USING (
    is_super_admin() OR
    (has_any_role(ARRAY['admin']) AND (
      EXISTS (
        SELECT 1 FROM orders o
        WHERE o.id = einvoice_jobs.order_id AND o.restaurant_id = get_user_store_id()
      )
      OR einvoice_jobs.tax_entity_id = get_user_tax_entity_id()
    ))
  );
-- No INSERT/UPDATE: service_role only

-- 3.10 einvoice_events
CREATE POLICY "einvoice_events_admin_read" ON public.einvoice_events
  FOR SELECT USING (
    is_super_admin() OR
    (has_any_role(ARRAY['admin']) AND (
      job_id IS NULL OR
      EXISTS (
        SELECT 1 FROM einvoice_jobs ej
        WHERE ej.id = einvoice_events.job_id AND (
          EXISTS (SELECT 1 FROM orders o WHERE o.id = ej.order_id AND o.restaurant_id = get_user_store_id())
          OR ej.tax_entity_id = get_user_tax_entity_id()
        )
      )
    ))
  );
-- No INSERT/UPDATE/DELETE: service_role only (append-only)

-- 3.11 partner_credential_access_log
CREATE POLICY "credential_log_superadmin_read" ON public.partner_credential_access_log
  FOR SELECT USING (is_super_admin());
-- No INSERT: service_role (dispatcher) only (append-only, Invariant I6)

COMMIT;;
