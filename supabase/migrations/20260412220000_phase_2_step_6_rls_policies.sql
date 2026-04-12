-- =============================================================================
-- Phase 2 Step 6 — RLS policies for new tables + auth hook infrastructure
-- Migration: 20260412220000_phase_2_step_6_rls_policies.sql
-- Scope: stage1_scope_v1.3.md Section 4, Section 12 Step 6
-- Target: ynriuoomotxuwhuxxmhj (globospossystem)
--
-- Delivers:
--   1. Helper functions for dual-axis access control
--   2. custom_access_token_hook() — deploy only; register in dashboard manually
--   3. RLS policies for all 11 Step 4 tables
--
-- Existing 33 policies left intact (table-lookup pattern continues to work).
-- Full existing policy migration deferred — no regression risk while these
-- policies still correctly enforce store isolation.
--
-- ⚠ POST-DEPLOY MANUAL STEP:
--   Supabase Dashboard → Authentication → Hooks → Custom Access Token Hook
--   → select public.custom_access_token_hook
--   Until this is done, app_metadata claims are not populated (policies
--   still work via table-lookup fallback via get_user_store_id()).
-- =============================================================================

BEGIN;

-- ===========================================================================
-- 1. Helper functions for dual-axis access control
-- ===========================================================================

-- Operational axis: returns current user's store id (restaurant_id)
-- Thin wrapper over existing get_user_store_id() — re-exposed for clarity.
-- Existing get_user_store_id() already present; no duplicate needed.

-- Tax axis: returns tax_entity_id of the current user's store
CREATE OR REPLACE FUNCTION public.get_user_tax_entity_id()
RETURNS uuid AS $$
  SELECT r.tax_entity_id
  FROM users u
  JOIN restaurants r ON r.id = u.restaurant_id
  WHERE u.auth_id = auth.uid() AND u.is_active = TRUE
  LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth;

COMMENT ON FUNCTION public.get_user_tax_entity_id() IS
  'Returns the tax_entity_id of the current user''s store. Enables tax-axis RLS: '
  'user can access WeTax data scoped to their store''s tax_entity. '
  'Returns NULL for super_admin (use is_super_admin() separately).';

-- Set-returning variants for future multi-store / multi-tax-entity expansion
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

COMMENT ON FUNCTION public.user_accessible_stores(uuid) IS
  'Returns all store ids (restaurant_id) accessible to a given auth uid. '
  'Stage 1: returns exactly one store per user. Foundation for multi-store in Stage 2.';

COMMENT ON FUNCTION public.user_accessible_tax_entities(uuid) IS
  'Returns all tax_entity ids accessible to a given auth uid via their store. '
  'Foundation for dual-axis JWT claim population in custom_access_token_hook.';

-- ===========================================================================
-- 2. Auth hook — populates app_metadata JWT claims on token mint/refresh
-- Deploy now. Register in dashboard: Authentication → Hooks → Custom Access
-- Token Hook → public.custom_access_token_hook
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb AS $$
DECLARE
  v_uid            uuid;
  v_user           users%ROWTYPE;
  v_store_ids      uuid[];
  v_tax_entity_ids uuid[];
BEGIN
  v_uid := (event->>'user_id')::uuid;

  SELECT * INTO v_user
  FROM users WHERE auth_id = v_uid AND is_active = TRUE LIMIT 1;

  -- No POS user found (e.g. Office app user) — return event unchanged
  IF NOT FOUND THEN
    RETURN event;
  END IF;

  v_store_ids      := ARRAY(SELECT * FROM user_accessible_stores(v_uid));
  v_tax_entity_ids := ARRAY(SELECT * FROM user_accessible_tax_entities(v_uid));

  -- Inject claims into app_metadata (not raw_user_meta_data which is client-writable)
  event := jsonb_set(event, '{claims,app_metadata,role}',
             to_jsonb(v_user.role), true);
  event := jsonb_set(event, '{claims,app_metadata,accessible_store_ids}',
             to_jsonb(v_store_ids), true);
  event := jsonb_set(event, '{claims,app_metadata,accessible_tax_entity_ids}',
             to_jsonb(v_tax_entity_ids), true);

  RETURN event;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, auth;

-- Grant execution to auth system; block direct calls from app layer
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb)
  TO supabase_auth_admin;
REVOKE EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb)
  FROM authenticated, anon, PUBLIC;

COMMENT ON FUNCTION public.custom_access_token_hook(jsonb) IS
  'Supabase custom access token hook. Populates app_metadata claims: '
  'role, accessible_store_ids[], accessible_tax_entity_ids[]. '
  'Register in Supabase Dashboard → Authentication → Hooks → '
  'Custom Access Token Hook → select this function. '
  'Until registered, JWT claims are absent but existing table-lookup RLS '
  'policies continue to work unchanged.';

-- ===========================================================================
-- 3. RLS policies for 11 Step 4 tables
--
-- Access pattern key:
--   service_role  — bypasses RLS by default (edge functions, RPCs)
--   super_admin   — full access to all WeTax infrastructure
--   admin         — read WeTax data for own store / tax_entity
--   cashier       — read/write b2b_buyer_cache for own store (checkout)
--   waiter/kitchen — no WeTax infrastructure access
--
-- Tables with no INSERT/UPDATE/DELETE policies:
--   → authenticated users cannot write; service_role can (for edge fns)
-- Tables with no SELECT policies on specific tables (partner_credentials):
--   → L2 isolation: deny all authenticated; service_role has access via bypass
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 3.1 brand_master — admin+ read; super_admin write
-- ---------------------------------------------------------------------------
CREATE POLICY "brand_master_admin_read" ON public.brand_master
  FOR SELECT USING (
    is_super_admin() OR has_any_role(ARRAY['admin'])
  );

CREATE POLICY "brand_master_superadmin_write" ON public.brand_master
  FOR ALL USING (is_super_admin()) WITH CHECK (is_super_admin());

-- ---------------------------------------------------------------------------
-- 3.2 tax_entity — admin+ read; super_admin write
-- ---------------------------------------------------------------------------
CREATE POLICY "tax_entity_admin_read" ON public.tax_entity
  FOR SELECT USING (
    is_super_admin() OR has_any_role(ARRAY['admin'])
  );

CREATE POLICY "tax_entity_superadmin_write" ON public.tax_entity
  FOR ALL USING (is_super_admin()) WITH CHECK (is_super_admin());

-- ---------------------------------------------------------------------------
-- 3.3 einvoice_shop — admin+ read; super_admin write
-- ---------------------------------------------------------------------------
CREATE POLICY "einvoice_shop_admin_read" ON public.einvoice_shop
  FOR SELECT USING (
    is_super_admin() OR has_any_role(ARRAY['admin'])
  );

CREATE POLICY "einvoice_shop_superadmin_write" ON public.einvoice_shop
  FOR ALL USING (is_super_admin()) WITH CHECK (is_super_admin());

-- ---------------------------------------------------------------------------
-- 3.4 partner_credentials — NO authenticated policies (L2 isolation)
-- Scope Section 4.4: "RLS denies all reads except from wetax-dispatcher
-- edge function's dedicated Postgres role. Not even service_role has
-- normal read access."
-- Stage 1 compromise: service_role (edge functions) can read via RLS bypass.
-- Step 7 will add a dedicated Postgres role for the dispatcher to fully
-- implement L2. No authenticated user policy created here.
-- ---------------------------------------------------------------------------
-- (intentionally no policies on partner_credentials)
-- Reminder: RLS ENABLED + no policies = deny all authenticated users.
--           service_role bypasses RLS and retains access for edge functions.

-- ---------------------------------------------------------------------------
-- 3.5 wetax_reference_values — all authenticated read (POS dropdown data)
--                              super_admin write
-- ---------------------------------------------------------------------------
CREATE POLICY "wetax_ref_authenticated_read" ON public.wetax_reference_values
  FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "wetax_ref_superadmin_write" ON public.wetax_reference_values
  FOR ALL USING (is_super_admin()) WITH CHECK (is_super_admin());

-- ---------------------------------------------------------------------------
-- 3.6 system_config — admin+ read (dashboard status banner); super_admin write
-- ---------------------------------------------------------------------------
CREATE POLICY "system_config_admin_read" ON public.system_config
  FOR SELECT USING (
    is_super_admin() OR has_any_role(ARRAY['admin'])
  );

CREATE POLICY "system_config_superadmin_write" ON public.system_config
  FOR ALL USING (is_super_admin()) WITH CHECK (is_super_admin());

-- ---------------------------------------------------------------------------
-- 3.7 b2b_buyer_cache — cashier/admin/super_admin for own store
-- SELECT uses Tier A (own store) OR Tier B (same tax_entity) for autocomplete
-- INSERT/UPDATE: own store only (cashiers create buyer entries at checkout)
-- DELETE: admin+ own store (cleanup stale entries)
-- ---------------------------------------------------------------------------
CREATE POLICY "b2b_buyer_cache_store_select" ON public.b2b_buyer_cache
  FOR SELECT USING (
    is_super_admin() OR
    (has_any_role(ARRAY['cashier', 'admin']) AND (
      store_id = get_user_store_id()             -- Tier A: own store
      OR tax_entity_id = get_user_tax_entity_id() -- Tier B: same tax_entity
    ))
  );

CREATE POLICY "b2b_buyer_cache_store_insert" ON public.b2b_buyer_cache
  FOR INSERT WITH CHECK (
    is_super_admin() OR
    (has_any_role(ARRAY['cashier', 'admin']) AND store_id = get_user_store_id())
  );

CREATE POLICY "b2b_buyer_cache_store_update" ON public.b2b_buyer_cache
  FOR UPDATE
  USING (
    is_super_admin() OR
    (has_any_role(ARRAY['cashier', 'admin']) AND store_id = get_user_store_id())
  )
  WITH CHECK (
    is_super_admin() OR
    (has_any_role(ARRAY['cashier', 'admin']) AND store_id = get_user_store_id())
  );

CREATE POLICY "b2b_buyer_cache_admin_delete" ON public.b2b_buyer_cache
  FOR DELETE USING (
    is_super_admin() OR
    (has_any_role(ARRAY['admin']) AND store_id = get_user_store_id())
  );

-- ---------------------------------------------------------------------------
-- 3.8 store_tax_entity_history — admin+ read; super_admin insert/update
-- No DELETE policy → DELETE denied for all authenticated (Invariant I5)
-- ---------------------------------------------------------------------------
CREATE POLICY "store_tax_history_admin_read" ON public.store_tax_entity_history
  FOR SELECT USING (
    is_super_admin() OR
    (has_any_role(ARRAY['admin']) AND store_id = get_user_store_id())
  );

CREATE POLICY "store_tax_history_superadmin_insert" ON public.store_tax_entity_history
  FOR INSERT WITH CHECK (is_super_admin());

CREATE POLICY "store_tax_history_superadmin_update" ON public.store_tax_entity_history
  FOR UPDATE USING (is_super_admin()) WITH CHECK (is_super_admin());

-- No DELETE policy: enforces append-only (Invariant I5)

-- ---------------------------------------------------------------------------
-- 3.9 einvoice_jobs — crossing table (Section 4.2)
-- SELECT: admin+ via operational axis (order's restaurant) OR tax axis
-- INSERT/UPDATE: no authenticated policy (service_role via edge functions/RPCs)
-- ---------------------------------------------------------------------------
CREATE POLICY "einvoice_jobs_admin_read" ON public.einvoice_jobs
  FOR SELECT USING (
    is_super_admin() OR
    (has_any_role(ARRAY['admin']) AND (
      -- Operational axis: user's store owns the underlying order
      EXISTS (
        SELECT 1 FROM orders o
        WHERE o.id = einvoice_jobs.order_id
          AND o.restaurant_id = get_user_store_id()
      )
      OR
      -- Tax axis: job's tax_entity matches user's store's tax_entity
      einvoice_jobs.tax_entity_id = get_user_tax_entity_id()
    ))
  );

-- No INSERT/UPDATE policy: service_role (RPC/edge fn) only

-- ---------------------------------------------------------------------------
-- 3.10 einvoice_events — admin+ read via job linkage; no auth writes
-- job_id is NULLABLE (system-level events like polling_activated have no job)
-- ---------------------------------------------------------------------------
CREATE POLICY "einvoice_events_admin_read" ON public.einvoice_events
  FOR SELECT USING (
    is_super_admin() OR
    (has_any_role(ARRAY['admin']) AND (
      job_id IS NULL  -- system-level events visible to all admins
      OR EXISTS (
        SELECT 1 FROM einvoice_jobs ej
        WHERE ej.id = einvoice_events.job_id AND (
          EXISTS (
            SELECT 1 FROM orders o
            WHERE o.id = ej.order_id
              AND o.restaurant_id = get_user_store_id()
          )
          OR ej.tax_entity_id = get_user_tax_entity_id()
        )
      )
    ))
  );

-- No INSERT/UPDATE/DELETE policy: service_role (append-only, Invariant I6)

-- ---------------------------------------------------------------------------
-- 3.11 partner_credential_access_log — super_admin read; no auth writes
-- Invariant I6: append-only. No UPDATE/DELETE policies.
-- ---------------------------------------------------------------------------
CREATE POLICY "credential_log_superadmin_read" ON public.partner_credential_access_log
  FOR SELECT USING (is_super_admin());

-- No INSERT policy: service_role (dispatcher edge function) appends

COMMIT;
