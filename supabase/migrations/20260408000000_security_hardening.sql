-- ============================================================
-- Security Hardening Migration
-- 2026-04-08
-- Fixes: RLS policy vulnerabilities, missing search_path,
--        CHECK constraints, storage policies, duplicate policies
-- ============================================================

-- ============================================================
-- H1. office_purchases: Replace USING(true) with scope-based RLS
-- ============================================================
DROP POLICY IF EXISTS office_purchases_authenticated_select ON office_purchases;
DROP POLICY IF EXISTS office_purchases_authenticated_insert ON office_purchases;
DROP POLICY IF EXISTS office_purchases_authenticated_update ON office_purchases;

-- SELECT: office users can see purchases for their accessible stores
-- POS admin/super_admin can see their restaurant's purchases
CREATE POLICY office_purchases_scoped_select
ON office_purchases FOR SELECT TO authenticated
USING (
  -- Office users: scope-based access
  restaurant_id = ANY(office_get_accessible_store_ids())
  OR
  -- POS admin/super_admin: own restaurant
  EXISTS (
    SELECT 1 FROM users u
    WHERE u.auth_id = auth.uid()
      AND u.role IN ('admin', 'super_admin')
      AND (u.role = 'super_admin' OR u.restaurant_id = office_purchases.restaurant_id)
  )
);

-- INSERT: only office users with purchase domain authority
CREATE POLICY office_purchases_scoped_insert
ON office_purchases FOR INSERT TO authenticated
WITH CHECK (
  restaurant_id = ANY(office_get_accessible_store_ids())
  AND EXISTS (
    SELECT 1 FROM office_user_profiles oup
    WHERE oup.auth_id = auth.uid()
      AND oup.is_active = true
  )
);

-- UPDATE: only office users with appropriate level
CREATE POLICY office_purchases_scoped_update
ON office_purchases FOR UPDATE TO authenticated
USING (
  restaurant_id = ANY(office_get_accessible_store_ids())
  AND EXISTS (
    SELECT 1 FROM office_user_profiles oup
    WHERE oup.auth_id = auth.uid()
      AND oup.is_active = true
      AND oup.account_level IN ('super_admin', 'platform_admin', 'office_admin', 'brand_admin')
  )
)
WITH CHECK (
  restaurant_id = ANY(office_get_accessible_store_ids())
);

-- ============================================================
-- H2. office_qc_followups: Replace USING(true) with scope-based RLS
-- ============================================================
DROP POLICY IF EXISTS office_qc_followups_authenticated_select ON office_qc_followups;
DROP POLICY IF EXISTS office_qc_followups_authenticated_insert ON office_qc_followups;
DROP POLICY IF EXISTS office_qc_followups_authenticated_update ON office_qc_followups;

CREATE POLICY office_qc_followups_scoped_select
ON office_qc_followups FOR SELECT TO authenticated
USING (
  restaurant_id = ANY(office_get_accessible_store_ids())
  OR
  EXISTS (
    SELECT 1 FROM users u
    WHERE u.auth_id = auth.uid()
      AND u.role IN ('admin', 'super_admin')
      AND (u.role = 'super_admin' OR u.restaurant_id = office_qc_followups.restaurant_id)
  )
);

CREATE POLICY office_qc_followups_scoped_insert
ON office_qc_followups FOR INSERT TO authenticated
WITH CHECK (
  restaurant_id = ANY(office_get_accessible_store_ids())
  AND EXISTS (
    SELECT 1 FROM office_user_profiles oup
    WHERE oup.auth_id = auth.uid()
      AND oup.is_active = true
  )
);

CREATE POLICY office_qc_followups_scoped_update
ON office_qc_followups FOR UPDATE TO authenticated
USING (
  restaurant_id = ANY(office_get_accessible_store_ids())
  AND EXISTS (
    SELECT 1 FROM office_user_profiles oup
    WHERE oup.auth_id = auth.uid()
      AND oup.is_active = true
      AND oup.account_level IN ('super_admin', 'platform_admin', 'office_admin', 'brand_admin')
  )
)
WITH CHECK (
  restaurant_id = ANY(office_get_accessible_store_ids())
);

-- ============================================================
-- M2. companies & brands: Restrict to office users + POS admin/super_admin
-- ============================================================
DROP POLICY IF EXISTS "authenticated_read" ON companies;
DROP POLICY IF EXISTS "authenticated_read" ON brands;

CREATE POLICY companies_scoped_read ON companies
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM office_user_profiles oup
    WHERE oup.auth_id = auth.uid() AND oup.is_active = true
  )
  OR EXISTS (
    SELECT 1 FROM users u
    WHERE u.auth_id = auth.uid()
      AND u.role IN ('admin', 'super_admin')
  )
);

CREATE POLICY brands_scoped_read ON brands
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM office_user_profiles oup
    WHERE oup.auth_id = auth.uid() AND oup.is_active = true
  )
  OR EXISTS (
    SELECT 1 FROM users u
    WHERE u.auth_id = auth.uid()
      AND u.role IN ('admin', 'super_admin')
  )
);

-- ============================================================
-- M4. office_payroll_reviews: Remove duplicate old policy
-- (20260405000010 already dropped and recreated; ensure clean state)
-- ============================================================
DROP POLICY IF EXISTS office_payroll_reviews_admin_update ON office_payroll_reviews;

-- ============================================================
-- M1. Storage: Replace overly broad policies with path-based access
-- attendance-photos: users can only access their restaurant's folder
-- Pattern: attendance-photos/{restaurant_id}/...
-- ============================================================
DROP POLICY IF EXISTS "restaurant_staff_access" ON storage.objects;

CREATE POLICY storage_attendance_scoped ON storage.objects
FOR ALL TO authenticated
USING (
  bucket_id = 'attendance-photos'
  AND (
    -- POS users: match restaurant_id in path
    EXISTS (
      SELECT 1 FROM users u
      WHERE u.auth_id = auth.uid()
        AND (storage.foldername(name))[1] = u.restaurant_id::text
    )
    -- Super admin: full access
    OR EXISTS (
      SELECT 1 FROM users u
      WHERE u.auth_id = auth.uid() AND u.role = 'super_admin'
    )
  )
)
WITH CHECK (
  bucket_id = 'attendance-photos'
  AND (
    EXISTS (
      SELECT 1 FROM users u
      WHERE u.auth_id = auth.uid()
        AND (storage.foldername(name))[1] = u.restaurant_id::text
    )
    OR EXISTS (
      SELECT 1 FROM users u
      WHERE u.auth_id = auth.uid() AND u.role = 'super_admin'
    )
  )
);

-- qc-photos bucket: same pattern
DROP POLICY IF EXISTS "qc_photos_access" ON storage.objects;

CREATE POLICY storage_qc_scoped ON storage.objects
FOR ALL TO authenticated
USING (
  bucket_id = 'qc-photos'
  AND (
    EXISTS (
      SELECT 1 FROM users u
      WHERE u.auth_id = auth.uid()
        AND (storage.foldername(name))[1] = u.restaurant_id::text
    )
    OR EXISTS (
      SELECT 1 FROM users u
      WHERE u.auth_id = auth.uid() AND u.role = 'super_admin'
    )
  )
)
WITH CHECK (
  bucket_id = 'qc-photos'
  AND (
    EXISTS (
      SELECT 1 FROM users u
      WHERE u.auth_id = auth.uid()
        AND (storage.foldername(name))[1] = u.restaurant_id::text
    )
    OR EXISTS (
      SELECT 1 FROM users u
      WHERE u.auth_id = auth.uid() AND u.role = 'super_admin'
    )
  )
);

-- ============================================================
-- M3. delivery_settlement_items: Add CHECK constraint on reference_rate
-- ============================================================
ALTER TABLE delivery_settlement_items
  ADD CONSTRAINT chk_reference_rate_range
  CHECK (reference_rate IS NULL OR (reference_rate >= 0 AND reference_rate <= 1));

-- ============================================================
-- L2. office_purchases: Add CHECK constraint on total_amount
-- ============================================================
ALTER TABLE office_purchases
  ADD CONSTRAINT chk_total_amount_non_negative
  CHECK (total_amount >= 0);

-- ============================================================
-- H6. Set search_path on all SECURITY DEFINER functions
-- ============================================================

-- Helper functions
ALTER FUNCTION get_user_restaurant_id() SET search_path = public, auth;
ALTER FUNCTION get_user_role() SET search_path = public, auth;
ALTER FUNCTION has_any_role(TEXT[]) SET search_path = public, auth;
ALTER FUNCTION is_super_admin() SET search_path = public, auth;

-- Core business RPCs
ALTER FUNCTION create_order(UUID, UUID, JSONB) SET search_path = public, auth;
ALTER FUNCTION create_buffet_order(UUID, UUID, INT, JSONB) SET search_path = public, auth;
ALTER FUNCTION add_items_to_order(UUID, UUID, JSONB) SET search_path = public, auth;
ALTER FUNCTION process_payment(UUID, UUID, DECIMAL, TEXT) SET search_path = public, auth;
ALTER FUNCTION cancel_order(UUID, UUID) SET search_path = public, auth;

-- Office payroll RPCs
ALTER FUNCTION office_confirm_payroll(UUID) SET search_path = public, auth;
ALTER FUNCTION office_return_payroll(UUID) SET search_path = public, auth;

-- Trigger function
ALTER FUNCTION on_payroll_store_submitted() SET search_path = public, auth;
