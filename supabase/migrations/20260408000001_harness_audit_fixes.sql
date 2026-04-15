-- ============================================================
-- Harness Audit Fixes Migration
-- 2026-04-08
-- CR1: audit_logs RLS
-- CR2+HI3: Core table policies WITH CHECK + super_admin
-- HI4: office_payroll_reviews SELECT scope-based
-- LO1: external_sales duplicate policy cleanup
-- LO3: inventory_items super_admin access
-- ============================================================

-- ============================================================
-- CR1. audit_logs: Enable RLS + admin-only read policy
-- ============================================================
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY audit_logs_admin_read
ON audit_logs FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM users u
    WHERE u.auth_id = auth.uid()
      AND u.role IN ('admin', 'super_admin')
  )
  OR EXISTS (
    SELECT 1 FROM office_user_profiles oup
    WHERE oup.auth_id = auth.uid()
      AND oup.is_active = true
      AND oup.account_level IN ('super_admin', 'platform_admin', 'office_admin')
  )
);
-- ============================================================
-- CR2+HI3. Core tables: Replace policies with super_admin + WITH CHECK
-- Drop existing → recreate with proper USING + WITH CHECK
-- ============================================================

-- tables
DROP POLICY IF EXISTS tables_policy ON tables;
CREATE POLICY tables_policy ON tables
FOR ALL TO authenticated
USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())
WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id());
-- menu_categories
DROP POLICY IF EXISTS menu_categories_policy ON menu_categories;
CREATE POLICY menu_categories_policy ON menu_categories
FOR ALL TO authenticated
USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())
WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id());
-- menu_items
DROP POLICY IF EXISTS menu_items_policy ON menu_items;
CREATE POLICY menu_items_policy ON menu_items
FOR ALL TO authenticated
USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())
WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id());
-- orders
DROP POLICY IF EXISTS orders_policy ON orders;
CREATE POLICY orders_policy ON orders
FOR ALL TO authenticated
USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())
WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id());
-- order_items
DROP POLICY IF EXISTS order_items_policy ON order_items;
CREATE POLICY order_items_policy ON order_items
FOR ALL TO authenticated
USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())
WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id());
-- payments
DROP POLICY IF EXISTS payments_policy ON payments;
CREATE POLICY payments_policy ON payments
FOR ALL TO authenticated
USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())
WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id());
-- attendance_logs
DROP POLICY IF EXISTS attendance_logs_policy ON attendance_logs;
CREATE POLICY attendance_logs_policy ON attendance_logs
FOR ALL TO authenticated
USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())
WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id());
-- LO3. inventory_items: add super_admin
DROP POLICY IF EXISTS inventory_items_policy ON inventory_items;
CREATE POLICY inventory_items_policy ON inventory_items
FOR ALL TO authenticated
USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())
WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id());
-- ============================================================
-- HI4. office_payroll_reviews: Replace SELECT USING(true) with scope-based
-- ============================================================
DROP POLICY IF EXISTS office_payroll_reviews_authenticated_select ON office_payroll_reviews;
CREATE POLICY office_payroll_reviews_scoped_select
ON office_payroll_reviews FOR SELECT TO authenticated
USING (
  -- Office users: scope-based
  restaurant_id = ANY(office_get_accessible_store_ids())
  OR
  -- POS admin/super_admin: own restaurant or all
  EXISTS (
    SELECT 1 FROM users u
    WHERE u.auth_id = auth.uid()
      AND u.role IN ('admin', 'super_admin')
      AND (u.role = 'super_admin' OR u.restaurant_id = office_payroll_reviews.restaurant_id)
  )
);
-- ============================================================
-- LO1. external_sales: cleanup duplicate policy
-- ============================================================
DROP POLICY IF EXISTS external_sales_policy ON external_sales;
-- external_sales_read (from 20260405000011) already has is_super_admin() OR restaurant_id pattern;
