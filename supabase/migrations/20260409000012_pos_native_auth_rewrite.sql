-- ============================================================
-- POS-Native Auth Rewrite
-- 2026-04-09
--
-- Purpose: Remove all POS-critical authorization dependencies on
-- office_user_profiles, office_get_accessible_store_ids(), and
-- office_get_accessible_brand_ids().
--
-- Authority: POS and Office use separate Supabase projects.
-- Office identity tables must not serve as POS auth foundations.
--
-- Changes:
--   1. Rewrite 5 RLS policies to use POS-native users table
--   2. Drop office-only tables (office_purchases, office_qc_followups)
--   3. Drop office identity infrastructure (office_user_profiles,
--      office_get_accessible_store_ids, office_get_accessible_brand_ids)
--
-- Depends on: 20260409000011 (latest prior migration)
-- Non-breaking for POS runtime: zero Dart code references any dropped object
-- ============================================================

BEGIN;
-- ============================================================
-- STEP 1: Rewrite POS-critical RLS policies to POS-native checks
-- ============================================================

-- 1a. companies: Remove office_user_profiles check, keep POS users check
-- Original: security_hardening.sql M2
DROP POLICY IF EXISTS companies_scoped_read ON companies;
CREATE POLICY companies_scoped_read ON companies
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM users u
    WHERE u.auth_id = auth.uid()
      AND u.role IN ('admin', 'super_admin')
  )
);
-- 1b. brands: Same pattern
-- Original: security_hardening.sql M2
DROP POLICY IF EXISTS brands_scoped_read ON brands;
CREATE POLICY brands_scoped_read ON brands
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM users u
    WHERE u.auth_id = auth.uid()
      AND u.role IN ('admin', 'super_admin')
  )
);
-- 1c. audit_logs: Remove office_user_profiles check
-- Original: harness_audit_fixes.sql CR1
DROP POLICY IF EXISTS audit_logs_admin_read ON audit_logs;
CREATE POLICY audit_logs_admin_read
ON audit_logs FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM users u
    WHERE u.auth_id = auth.uid()
      AND u.role IN ('admin', 'super_admin')
  )
);
-- 1d. office_payroll_reviews SELECT: Replace office_get_accessible_store_ids()
-- Original: harness_audit_fixes.sql HI4
DROP POLICY IF EXISTS office_payroll_reviews_scoped_select ON office_payroll_reviews;
CREATE POLICY office_payroll_reviews_scoped_select
ON office_payroll_reviews FOR SELECT TO authenticated
USING (
  is_super_admin()
  OR restaurant_id = get_user_restaurant_id()
);
-- 1e. office_payroll_reviews UPDATE: Replace office_user_profiles check
-- Original: fix_payroll_review_rls.sql
DROP POLICY IF EXISTS office_payroll_reviews_office_update ON office_payroll_reviews;
CREATE POLICY office_payroll_reviews_pos_update
ON office_payroll_reviews FOR UPDATE TO authenticated
USING (
  has_any_role(ARRAY['admin', 'super_admin'])
  AND (is_super_admin() OR restaurant_id = get_user_restaurant_id())
)
WITH CHECK (
  has_any_role(ARRAY['admin', 'super_admin'])
  AND (is_super_admin() OR restaurant_id = get_user_restaurant_id())
);
-- ============================================================
-- STEP 2: Drop office-only tables (zero Dart/POS runtime dependency)
-- CASCADE drops their RLS policies, constraints, and indexes
-- ============================================================

-- office_purchases: Created in 20260405000006, RLS hardened in 20260408000000 H1+L2
-- No Dart code references this table
DROP TABLE IF EXISTS office_purchases CASCADE;
-- office_qc_followups: Created in 20260405000007, RLS hardened in 20260408000000 H2
-- No Dart code references this table
DROP TABLE IF EXISTS office_qc_followups CASCADE;
-- ============================================================
-- STEP 3: Drop office identity infrastructure
-- All POS-critical consumers were rewritten in Step 1.
-- Remaining consumers were on office_purchases/office_qc_followups (dropped in Step 2).
-- ============================================================

-- Drop scope functions first (they depend on office_user_profiles)
DROP FUNCTION IF EXISTS office_get_accessible_store_ids();
DROP FUNCTION IF EXISTS office_get_accessible_brand_ids();
-- Drop office identity table (CASCADE drops its policies and indexes)
DROP TABLE IF EXISTS office_user_profiles CASCADE;
COMMIT;
