BEGIN;

-- 1. Sensitive reporting views must evaluate base-table RLS as the caller.
DO $$
DECLARE
  v_view text;
  v_missing text[] := ARRAY[]::text[];
BEGIN
  FOREACH v_view IN ARRAY ARRAY[
    'store_settings',
    'v_store_daily_sales',
    'v_store_attendance_summary',
    'v_inventory_status',
    'v_brand_kpi',
    'v_quality_monitoring',
    'v_qsc_dashboard_summary',
    'v_qsc_store_status',
    'v_qsc_item_status',
    'v_office_qsc_dashboard',
    'v_office_qsc_store_latest',
    'v_office_qsc_issue_queue'
  ]
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relname = v_view
        AND c.relkind = 'v'
    ) THEN
      v_missing := array_append(v_missing, v_view);
    END IF;
  END LOOP;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION 'SECURITY_HARDENING_REQUIRED_VIEWS_MISSING: %',
      array_to_string(v_missing, ', ');
  END IF;
END;
$$;

ALTER VIEW public.store_settings SET (security_invoker = true);
ALTER VIEW public.v_store_daily_sales SET (security_invoker = true);
ALTER VIEW public.v_store_attendance_summary SET (security_invoker = true);
ALTER VIEW public.v_inventory_status SET (security_invoker = true);
ALTER VIEW public.v_brand_kpi SET (security_invoker = true);
ALTER VIEW public.v_quality_monitoring SET (security_invoker = true);
ALTER VIEW public.v_qsc_dashboard_summary SET (security_invoker = true);
ALTER VIEW public.v_qsc_store_status SET (security_invoker = true);
ALTER VIEW public.v_qsc_item_status SET (security_invoker = true);
ALTER VIEW public.v_office_qsc_dashboard SET (security_invoker = true);
ALTER VIEW public.v_office_qsc_store_latest SET (security_invoker = true);
ALTER VIEW public.v_office_qsc_issue_queue SET (security_invoker = true);

REVOKE ALL ON TABLE public.store_settings FROM PUBLIC, anon;
REVOKE ALL ON TABLE public.v_store_daily_sales FROM PUBLIC, anon;
REVOKE ALL ON TABLE public.v_store_attendance_summary FROM PUBLIC, anon;
REVOKE ALL ON TABLE public.v_inventory_status FROM PUBLIC, anon;
REVOKE ALL ON TABLE public.v_brand_kpi FROM PUBLIC, anon;
REVOKE ALL ON TABLE public.v_quality_monitoring FROM PUBLIC, anon;
REVOKE ALL ON TABLE public.v_qsc_dashboard_summary FROM PUBLIC, anon;
REVOKE ALL ON TABLE public.v_qsc_store_status FROM PUBLIC, anon;
REVOKE ALL ON TABLE public.v_qsc_item_status FROM PUBLIC, anon;
REVOKE ALL ON TABLE public.v_office_qsc_dashboard FROM PUBLIC, anon;
REVOKE ALL ON TABLE public.v_office_qsc_store_latest FROM PUBLIC, anon;
REVOKE ALL ON TABLE public.v_office_qsc_issue_queue FROM PUBLIC, anon;

GRANT SELECT ON TABLE public.store_settings TO authenticated;
GRANT SELECT ON TABLE public.v_store_daily_sales TO authenticated;
GRANT SELECT ON TABLE public.v_store_attendance_summary TO authenticated;
GRANT SELECT ON TABLE public.v_inventory_status TO authenticated;
GRANT SELECT ON TABLE public.v_brand_kpi TO authenticated;
GRANT SELECT ON TABLE public.v_quality_monitoring TO authenticated;
GRANT SELECT ON TABLE public.v_qsc_dashboard_summary TO authenticated;
GRANT SELECT ON TABLE public.v_qsc_store_status TO authenticated;
GRANT SELECT ON TABLE public.v_qsc_item_status TO authenticated;
GRANT SELECT ON TABLE public.v_office_qsc_dashboard TO authenticated;
GRANT SELECT ON TABLE public.v_office_qsc_store_latest TO authenticated;
GRANT SELECT ON TABLE public.v_office_qsc_issue_queue TO authenticated;

GRANT SELECT ON TABLE public.store_settings TO service_role;
GRANT SELECT ON TABLE public.v_store_daily_sales TO service_role;
GRANT SELECT ON TABLE public.v_store_attendance_summary TO service_role;
GRANT SELECT ON TABLE public.v_inventory_status TO service_role;
GRANT SELECT ON TABLE public.v_brand_kpi TO service_role;
GRANT SELECT ON TABLE public.v_quality_monitoring TO service_role;
GRANT SELECT ON TABLE public.v_qsc_dashboard_summary TO service_role;
GRANT SELECT ON TABLE public.v_qsc_store_status TO service_role;
GRANT SELECT ON TABLE public.v_qsc_item_status TO service_role;
GRANT SELECT ON TABLE public.v_office_qsc_dashboard TO service_role;
GRANT SELECT ON TABLE public.v_office_qsc_store_latest TO service_role;
GRANT SELECT ON TABLE public.v_office_qsc_issue_queue TO service_role;

-- 2. Remove the permissive sibling that defeats the scoped audit policy.
DROP POLICY IF EXISTS audit_logs_authenticated_select ON public.audit_logs;

-- 3. Internal definer helpers remain callable only by the service role.
DO $$
DECLARE
  v_signature text;
  v_function regprocedure;
BEGIN
  FOREACH v_signature IN ARRAY ARRAY[
    'public.refresh_user_claims(uuid)',
    'public.sync_all_store_access()',
    'public.sync_brand_store_access(uuid)',
    'public.sync_user_store_access(uuid)',
    'public.refresh_qc_check_photo_summary(uuid,boolean)',
    'public.recalculate_inventory_purchase_order_totals(uuid)',
    'public.enqueue_photo_objet_meinvoice_job(uuid)'
  ]
  LOOP
    v_function := to_regprocedure(v_signature);
    IF v_function IS NOT NULL THEN
      EXECUTE format(
        'REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated',
        v_function
      );
      EXECUTE format(
        'GRANT EXECUTE ON FUNCTION %s TO service_role',
        v_function
      );
    END IF;
  END LOOP;
END;
$$;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;

-- 4. Canonical identity helpers deny every inactive profile.
CREATE OR REPLACE FUNCTION public.get_user_restaurant_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
  SELECT u.restaurant_id
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.get_user_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
  SELECT u.role
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.get_user_store_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
  SELECT public.get_user_restaurant_id()
$$;

CREATE OR REPLACE FUNCTION public.has_any_role(required_roles text[])
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
  SELECT COALESCE((
    SELECT u.role = ANY(required_roles)
    FROM public.users u
    WHERE u.auth_id = auth.uid()
      AND u.is_active = TRUE
    LIMIT 1
  ), FALSE)
$$;

CREATE OR REPLACE FUNCTION public.is_super_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.auth_id = auth.uid()
      AND u.is_active = TRUE
      AND u.role = 'super_admin'
  )
$$;

-- 5. Storage access must independently reject inactive profiles.
DROP POLICY IF EXISTS storage_attendance_scoped ON storage.objects;
CREATE POLICY storage_attendance_scoped ON storage.objects
FOR ALL TO authenticated
USING (
  bucket_id = 'attendance-photos'
  AND (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.auth_id = auth.uid()
        AND u.is_active = TRUE
        AND (storage.foldername(name))[1] = u.restaurant_id::text
    )
    OR EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.auth_id = auth.uid()
        AND u.is_active = TRUE
        AND u.role = 'super_admin'
    )
  )
)
WITH CHECK (
  bucket_id = 'attendance-photos'
  AND (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.auth_id = auth.uid()
        AND u.is_active = TRUE
        AND (storage.foldername(name))[1] = u.restaurant_id::text
    )
    OR EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.auth_id = auth.uid()
        AND u.is_active = TRUE
        AND u.role = 'super_admin'
    )
  )
);

DROP POLICY IF EXISTS authenticated_access_qc_photos ON storage.objects;
DROP POLICY IF EXISTS storage_qc_scoped ON storage.objects;
CREATE POLICY storage_qc_scoped ON storage.objects
FOR ALL TO authenticated
USING (
  bucket_id = 'qc-photos'
  AND (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.auth_id = auth.uid()
        AND u.is_active = TRUE
        AND (storage.foldername(name))[1] = u.restaurant_id::text
    )
    OR EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.auth_id = auth.uid()
        AND u.is_active = TRUE
        AND u.role = 'super_admin'
    )
  )
)
WITH CHECK (
  bucket_id = 'qc-photos'
  AND (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.auth_id = auth.uid()
        AND u.is_active = TRUE
        AND (storage.foldername(name))[1] = u.restaurant_id::text
    )
    OR EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.auth_id = auth.uid()
        AND u.is_active = TRUE
        AND u.role = 'super_admin'
    )
  )
);

DROP POLICY IF EXISTS storage_payment_proofs_scoped ON storage.objects;
CREATE POLICY storage_payment_proofs_scoped ON storage.objects
FOR ALL TO authenticated
USING (
  bucket_id = 'payment-proofs'
  AND (
    EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id::text = (storage.foldername(name))[2]
    )
    OR EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.auth_id = auth.uid()
        AND u.is_active = TRUE
        AND u.role = 'super_admin'
    )
  )
)
WITH CHECK (
  bucket_id = 'payment-proofs'
  AND (
    EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id::text = (storage.foldername(name))[2]
    )
    OR EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.auth_id = auth.uid()
        AND u.is_active = TRUE
        AND u.role = 'super_admin'
    )
  )
);

COMMIT;
