-- ============================================================================
-- Migration: restaurants → stores atomic rename
-- Date: 2026-04-12
-- Maintenance window: 03:00-05:00 Asia/Ho_Chi_Minh
-- Scope: Table renames, column renames, FK constraints, indexes,
--         RLS policies, views, functions, triggers
-- Rollback: 20260412030001_rollback_rename_stores_to_restaurants.sql
-- ============================================================================

BEGIN;

-- ============================================================================
-- SECTION 1: Table Renames
-- ============================================================================

ALTER TABLE public.restaurants RENAME TO stores;
ALTER TABLE public.restaurant_settings RENAME TO store_settings;

-- ============================================================================
-- SECTION 2: Column Renames (restaurant_id → store_id)
-- ============================================================================
-- Every table that has a restaurant_id column gets it renamed to store_id.

ALTER TABLE public.store_settings RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.users RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.tables RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.menu_categories RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.menu_items RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.orders RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.order_items RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.payments RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.attendance_logs RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.inventory_items RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.external_sales RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.menu_recipes RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.inventory_transactions RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.inventory_physical_counts RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.qc_templates RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.qc_checks RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.staff_wage_configs RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.payroll_records RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.fingerprint_templates RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.delivery_settlements RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.qc_followups RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.office_payroll_reviews RENAME COLUMN restaurant_id TO store_id;
ALTER TABLE public.daily_closings RENAME COLUMN restaurant_id TO store_id;

-- ============================================================================
-- SECTION 3: Constraint and Index Renames
-- ============================================================================

-- Rename unique constraint on tables (restaurant_id, table_number)
ALTER INDEX IF EXISTS tables_restaurant_id_table_number_key RENAME TO tables_store_id_table_number_key;

-- Rename unique constraint on delivery_settlements
ALTER INDEX IF EXISTS unique_settlement_period RENAME TO unique_settlement_period_store;

-- Rename constraint on store_type check
ALTER TABLE public.stores RENAME CONSTRAINT restaurants_store_type_check TO stores_store_type_check;

-- Rename indexes that reference 'restaurant' in their name
ALTER INDEX IF EXISTS idx_users_restaurant RENAME TO idx_users_store;
ALTER INDEX IF EXISTS idx_tables_restaurant RENAME TO idx_tables_store;
ALTER INDEX IF EXISTS idx_menu_items_restaurant RENAME TO idx_menu_items_store;
ALTER INDEX IF EXISTS idx_orders_restaurant RENAME TO idx_orders_store;
ALTER INDEX IF EXISTS idx_orders_status RENAME TO idx_orders_store_status;
ALTER INDEX IF EXISTS idx_payments_restaurant RENAME TO idx_payments_store;
ALTER INDEX IF EXISTS idx_external_sales_restaurant RENAME TO idx_external_sales_store;
ALTER INDEX IF EXISTS idx_fingerprint_templates_restaurant RENAME TO idx_fingerprint_templates_store;
ALTER INDEX IF EXISTS idx_restaurants_store_type RENAME TO idx_stores_store_type;
ALTER INDEX IF EXISTS idx_restaurants_brand_store_type RENAME TO idx_stores_brand_store_type;
ALTER INDEX IF EXISTS idx_restaurants_brand_id RENAME TO idx_stores_brand_id;
ALTER INDEX IF EXISTS idx_office_payroll_reviews_restaurant RENAME TO idx_office_payroll_reviews_store;
ALTER INDEX IF EXISTS idx_daily_closings_restaurant_date RENAME TO idx_daily_closings_store_date;
ALTER INDEX IF EXISTS idx_inventory_items_restaurant_name_ci RENAME TO idx_inventory_items_store_name_ci;

-- Rename unique constraint on daily_closings
ALTER INDEX IF EXISTS unique_daily_closing RENAME TO unique_daily_closing_store;

-- ============================================================================
-- SECTION 4: RLS Helper Function — get_user_restaurant_id → get_user_store_id
-- ============================================================================

-- Drop old function
DROP FUNCTION IF EXISTS get_user_restaurant_id();

-- Create new function
CREATE OR REPLACE FUNCTION get_user_store_id()
RETURNS UUID AS $$
  SELECT store_id FROM users WHERE auth_id = auth.uid()
$$ LANGUAGE sql SECURITY DEFINER STABLE
SET search_path = public, auth;

-- The other helpers (get_user_role, has_any_role, is_super_admin) don't reference restaurant

-- ============================================================================
-- SECTION 5: Drop and Recreate ALL RLS Policies
-- ============================================================================

-- ────────────────────────────────────────────
-- stores (was restaurants)
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS restaurants_select_policy ON public.stores;
DROP POLICY IF EXISTS restaurants_super_admin_insert_policy ON public.stores;
DROP POLICY IF EXISTS restaurants_admin_update_policy ON public.stores;
DROP POLICY IF EXISTS restaurants_policy ON public.stores;

CREATE POLICY stores_select_policy ON public.stores
FOR SELECT TO authenticated
USING (
  is_super_admin()
  OR id = get_user_store_id()
);

-- ────────────────────────────────────────────
-- users
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS users_select_policy ON public.users;
DROP POLICY IF EXISTS users_policy ON public.users;

CREATE POLICY users_select_policy ON public.users
FOR SELECT TO authenticated
USING (
  is_super_admin()
  OR store_id = get_user_store_id()
);

-- ────────────────────────────────────────────
-- tables
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS tables_select_policy ON public.tables;
DROP POLICY IF EXISTS tables_policy ON public.tables;

CREATE POLICY tables_select_policy ON public.tables
FOR SELECT TO authenticated
USING (
  is_super_admin()
  OR store_id = get_user_store_id()
);

-- ────────────────────────────────────────────
-- menu_categories
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS menu_categories_select_policy ON public.menu_categories;
DROP POLICY IF EXISTS menu_categories_policy ON public.menu_categories;

CREATE POLICY menu_categories_select_policy ON public.menu_categories
FOR SELECT TO authenticated
USING (
  is_super_admin()
  OR store_id = get_user_store_id()
);

-- ────────────────────────────────────────────
-- menu_items
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS menu_items_select_policy ON public.menu_items;
DROP POLICY IF EXISTS menu_items_policy ON public.menu_items;

CREATE POLICY menu_items_select_policy ON public.menu_items
FOR SELECT TO authenticated
USING (
  is_super_admin()
  OR store_id = get_user_store_id()
);

-- ────────────────────────────────────────────
-- orders
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS orders_policy ON public.orders;

CREATE POLICY orders_policy ON orders
FOR ALL TO authenticated
USING (is_super_admin() OR store_id = get_user_store_id())
WITH CHECK (is_super_admin() OR store_id = get_user_store_id());

-- ────────────────────────────────────────────
-- order_items
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS order_items_policy ON public.order_items;

CREATE POLICY order_items_policy ON order_items
FOR ALL TO authenticated
USING (is_super_admin() OR store_id = get_user_store_id())
WITH CHECK (is_super_admin() OR store_id = get_user_store_id());

-- ────────────────────────────────────────────
-- payments
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS payments_policy ON public.payments;

CREATE POLICY payments_policy ON payments
FOR ALL TO authenticated
USING (is_super_admin() OR store_id = get_user_store_id())
WITH CHECK (is_super_admin() OR store_id = get_user_store_id());

-- ────────────────────────────────────────────
-- attendance_logs
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS attendance_logs_policy ON public.attendance_logs;

CREATE POLICY attendance_logs_policy ON attendance_logs
FOR ALL TO authenticated
USING (is_super_admin() OR store_id = get_user_store_id())
WITH CHECK (is_super_admin() OR store_id = get_user_store_id());

-- ────────────────────────────────────────────
-- inventory_items
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS inventory_items_policy ON public.inventory_items;

CREATE POLICY inventory_items_policy ON inventory_items
FOR ALL TO authenticated
USING (is_super_admin() OR store_id = get_user_store_id())
WITH CHECK (is_super_admin() OR store_id = get_user_store_id());

-- ────────────────────────────────────────────
-- external_sales
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS external_sales_read ON public.external_sales;
DROP POLICY IF EXISTS external_sales_policy ON public.external_sales;

CREATE POLICY external_sales_read ON external_sales
FOR SELECT
USING (
  is_super_admin()
  OR store_id = get_user_store_id()
);

-- ────────────────────────────────────────────
-- delivery_settlements
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS delivery_settlements_read ON public.delivery_settlements;
DROP POLICY IF EXISTS delivery_settlements_insert ON public.delivery_settlements;
DROP POLICY IF EXISTS delivery_settlements_confirm ON public.delivery_settlements;

CREATE POLICY delivery_settlements_read ON delivery_settlements
FOR SELECT
USING (
  is_super_admin()
  OR store_id = get_user_store_id()
);

CREATE POLICY delivery_settlements_insert ON delivery_settlements
FOR INSERT
WITH CHECK (
  store_id = get_user_store_id()
);

CREATE POLICY delivery_settlements_confirm ON delivery_settlements
FOR UPDATE
USING (
  store_id = get_user_store_id()
  AND has_any_role(ARRAY['admin','super_admin'])
)
WITH CHECK (
  store_id = get_user_store_id()
);

-- ────────────────────────────────────────────
-- delivery_settlement_items
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS settlement_items_read ON public.delivery_settlement_items;
DROP POLICY IF EXISTS settlement_items_insert ON public.delivery_settlement_items;

CREATE POLICY settlement_items_read ON delivery_settlement_items
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM delivery_settlements ds
    WHERE ds.id = delivery_settlement_items.settlement_id
      AND (is_super_admin() OR ds.store_id = get_user_store_id())
  )
);

CREATE POLICY settlement_items_insert ON delivery_settlement_items
FOR INSERT
WITH CHECK (
  EXISTS (
    SELECT 1 FROM delivery_settlements ds
    WHERE ds.id = delivery_settlement_items.settlement_id
      AND ds.store_id = get_user_store_id()
  )
);

-- ────────────────────────────────────────────
-- menu_recipes
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS "restaurant_isolation" ON public.menu_recipes;

CREATE POLICY "store_isolation" ON menu_recipes
USING (store_id = get_user_store_id() OR has_any_role(ARRAY['super_admin']))
WITH CHECK (store_id = get_user_store_id() OR has_any_role(ARRAY['super_admin']));

-- ────────────────────────────────────────────
-- inventory_transactions
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS "restaurant_isolation" ON public.inventory_transactions;

CREATE POLICY "store_isolation" ON inventory_transactions
USING (store_id = get_user_store_id() OR has_any_role(ARRAY['super_admin']))
WITH CHECK (store_id = get_user_store_id() OR has_any_role(ARRAY['super_admin']));

-- ────────────────────────────────────────────
-- inventory_physical_counts
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS "restaurant_isolation" ON public.inventory_physical_counts;

CREATE POLICY "store_isolation" ON inventory_physical_counts
USING (store_id = get_user_store_id() OR has_any_role(ARRAY['super_admin']))
WITH CHECK (store_id = get_user_store_id() OR has_any_role(ARRAY['super_admin']));

-- ────────────────────────────────────────────
-- qc_templates (4 policies)
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS "qc_templates_select" ON public.qc_templates;
DROP POLICY IF EXISTS "qc_templates_insert" ON public.qc_templates;
DROP POLICY IF EXISTS "qc_templates_update" ON public.qc_templates;
DROP POLICY IF EXISTS "qc_templates_delete" ON public.qc_templates;

CREATE POLICY "qc_templates_select" ON qc_templates
FOR SELECT USING (
  is_global = TRUE OR
  store_id = get_user_store_id() OR
  has_any_role(ARRAY['super_admin'])
);

CREATE POLICY "qc_templates_insert" ON qc_templates
FOR INSERT WITH CHECK (
  has_any_role(ARRAY['super_admin']) OR
  (has_any_role(ARRAY['admin']) AND is_global = FALSE
    AND store_id = get_user_store_id())
);

CREATE POLICY "qc_templates_update" ON qc_templates
FOR UPDATE USING (
  has_any_role(ARRAY['super_admin']) OR
  (has_any_role(ARRAY['admin']) AND is_global = FALSE
    AND store_id = get_user_store_id())
);

CREATE POLICY "qc_templates_delete" ON qc_templates
FOR DELETE USING (
  has_any_role(ARRAY['super_admin']) OR
  (has_any_role(ARRAY['admin']) AND is_global = FALSE
    AND store_id = get_user_store_id())
);

-- ────────────────────────────────────────────
-- qc_checks
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS "restaurant_isolation" ON public.qc_checks;

CREATE POLICY "store_isolation" ON qc_checks
USING (
  store_id = get_user_store_id()
  OR has_any_role(ARRAY['super_admin'])
);

-- ────────────────────────────────────────────
-- qc_followups
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS qc_followups_restaurant_isolation ON public.qc_followups;

CREATE POLICY qc_followups_store_isolation
ON public.qc_followups
USING (
  store_id = get_user_store_id()
  OR has_any_role(ARRAY['super_admin'])
);

-- ────────────────────────────────────────────
-- staff_wage_configs
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS "restaurant_isolation" ON public.staff_wage_configs;

CREATE POLICY "store_isolation" ON staff_wage_configs
USING (store_id = get_user_store_id() OR has_any_role(ARRAY['super_admin']));

-- ────────────────────────────────────────────
-- payroll_records
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS "restaurant_isolation" ON public.payroll_records;

CREATE POLICY "store_isolation" ON payroll_records
USING (store_id = get_user_store_id() OR has_any_role(ARRAY['super_admin']));

-- ────────────────────────────────────────────
-- store_settings (was restaurant_settings)
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS "admin_only" ON public.store_settings;

CREATE POLICY "admin_only" ON store_settings
USING (
  store_id = get_user_store_id()
  AND has_any_role(ARRAY['admin','super_admin'])
)
WITH CHECK (
  store_id = get_user_store_id()
  AND has_any_role(ARRAY['admin','super_admin'])
);

-- ────────────────────────────────────────────
-- fingerprint_templates
-- ────────────────────────────────────────────
-- Note: fingerprint_templates_restaurant_policy was dropped in bundle_a
-- The service_role policy remains untouched.

-- ────────────────────────────────────────────
-- audit_logs (no restaurant_id column — unchanged)
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS audit_logs_admin_read ON public.audit_logs;

CREATE POLICY audit_logs_admin_read
ON audit_logs FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM users u
    WHERE u.auth_id = auth.uid()
      AND u.role IN ('admin', 'super_admin')
  )
);

-- ────────────────────────────────────────────
-- companies (no restaurant_id column — unchanged)
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS companies_scoped_read ON public.companies;

CREATE POLICY companies_scoped_read ON companies
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM users u
    WHERE u.auth_id = auth.uid()
      AND u.role IN ('admin', 'super_admin')
  )
);

-- ────────────────────────────────────────────
-- brands (no restaurant_id column — unchanged)
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS brands_scoped_read ON public.brands;

CREATE POLICY brands_scoped_read ON brands
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM users u
    WHERE u.auth_id = auth.uid()
      AND u.role IN ('admin', 'super_admin')
  )
);

-- ────────────────────────────────────────────
-- office_payroll_reviews
-- ────────────────────────────────────────────
DROP POLICY IF EXISTS office_payroll_reviews_scoped_select ON public.office_payroll_reviews;
DROP POLICY IF EXISTS office_payroll_reviews_pos_update ON public.office_payroll_reviews;

CREATE POLICY office_payroll_reviews_scoped_select
ON office_payroll_reviews FOR SELECT TO authenticated
USING (
  is_super_admin()
  OR store_id = get_user_store_id()
);

CREATE POLICY office_payroll_reviews_pos_update
ON office_payroll_reviews FOR UPDATE TO authenticated
USING (
  has_any_role(ARRAY['admin', 'super_admin'])
  AND (is_super_admin() OR store_id = get_user_store_id())
)
WITH CHECK (
  has_any_role(ARRAY['admin', 'super_admin'])
  AND (is_super_admin() OR store_id = get_user_store_id())
);

-- ============================================================================
-- SECTION 6: Drop and Recreate ALL Views
-- ============================================================================

-- Drop all views (CASCADE for dependencies)
DROP VIEW IF EXISTS public_restaurant_profiles CASCADE;
DROP VIEW IF EXISTS public_menu_items CASCADE;
DROP VIEW IF EXISTS v_store_daily_sales CASCADE;
DROP VIEW IF EXISTS v_store_attendance_summary CASCADE;
DROP VIEW IF EXISTS v_quality_monitoring CASCADE;
DROP VIEW IF EXISTS v_inventory_status CASCADE;
DROP VIEW IF EXISTS v_brand_kpi CASCADE;
DROP VIEW IF EXISTS v_external_store_sales CASCADE;
DROP VIEW IF EXISTS v_external_store_overview CASCADE;
DROP VIEW IF EXISTS v_daily_revenue_by_channel CASCADE;
DROP VIEW IF EXISTS v_settlement_summary CASCADE;

-- ── public_store_profiles (was public_restaurant_profiles) ──
CREATE VIEW public_store_profiles AS
SELECT
  r.id,
  r.slug,
  r.name,
  r.address,
  r.operation_mode,
  r.per_person_charge,
  r.is_active,
  r.store_type,
  r.brand_id,
  b.name AS brand_name,
  r.created_at
FROM stores r
LEFT JOIN brands b ON b.id = r.brand_id
WHERE r.is_active = TRUE;

GRANT SELECT ON public_store_profiles TO anon;
GRANT SELECT ON public_store_profiles TO authenticated;

-- Compatibility alias for public_restaurant_profiles
CREATE VIEW public_restaurant_profiles AS SELECT * FROM public_store_profiles;
COMMENT ON VIEW public_restaurant_profiles IS 'DEPRECATED compatibility alias. Use public_store_profiles instead. This alias will be removed in Stage 2.';

GRANT SELECT ON public_restaurant_profiles TO anon;
GRANT SELECT ON public_restaurant_profiles TO authenticated;

-- ── public_menu_items ──
CREATE VIEW public_menu_items AS
SELECT
  mi.id AS external_menu_item_id,
  mi.store_id,
  r.slug AS restaurant_slug,
  r.store_type,
  mc.name AS category_name,
  mi.name,
  mi.description,
  mi.price,
  r.operation_mode
FROM menu_items mi
JOIN stores r ON r.id = mi.store_id
LEFT JOIN menu_categories mc ON mc.id = mi.category_id
WHERE mi.is_available = TRUE
  AND mi.is_visible_public = TRUE;

GRANT SELECT ON public_menu_items TO anon;
GRANT SELECT ON public_menu_items TO authenticated;

-- ── v_store_daily_sales ──
CREATE OR REPLACE VIEW v_store_daily_sales AS
SELECT
  r.id AS store_id,
  r.brand_id,
  b.name AS brand_name,
  r.name AS store_name,
  DATE(p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh') AS sale_date,
  COUNT(DISTINCT p.order_id) AS order_count,
  SUM(CASE WHEN p.is_revenue THEN p.amount ELSE 0 END) AS revenue,
  SUM(CASE WHEN NOT p.is_revenue THEN p.amount ELSE 0 END) AS service_amount
FROM payments p
JOIN stores r ON r.id = p.store_id
LEFT JOIN brands b ON b.id = r.brand_id
WHERE r.store_type = 'direct'
GROUP BY r.id, r.brand_id, b.name, r.name,
         DATE(p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh');

-- ── v_store_attendance_summary ──
CREATE OR REPLACE VIEW v_store_attendance_summary AS
SELECT
  al.store_id AS store_id,
  r.brand_id,
  al.user_id,
  COALESCE(u.full_name, u.role) AS employee_name,
  u.role AS employee_role,
  DATE(al.logged_at AT TIME ZONE 'Asia/Ho_Chi_Minh') AS work_date,
  MIN(CASE WHEN al.type = 'clock_in' THEN al.logged_at END) AS first_clock_in,
  MAX(CASE WHEN al.type = 'clock_out' THEN al.logged_at END) AS last_clock_out,
  COUNT(CASE WHEN al.type = 'clock_in' THEN 1 END) AS clock_in_count,
  COUNT(CASE WHEN al.type = 'clock_out' THEN 1 END) AS clock_out_count
FROM attendance_logs al
JOIN stores r ON r.id = al.store_id
JOIN users u ON u.id = al.user_id
WHERE r.store_type = 'direct'
GROUP BY al.store_id, r.brand_id, al.user_id, COALESCE(u.full_name, u.role), u.role,
         DATE(al.logged_at AT TIME ZONE 'Asia/Ho_Chi_Minh');

-- ── v_quality_monitoring ──
CREATE OR REPLACE VIEW v_quality_monitoring AS
SELECT
  qc.id AS check_id,
  qc.store_id AS store_id,
  r.brand_id,
  r.name AS store_name,
  qt.category,
  qt.criteria_text,
  qc.check_date,
  qc.result,
  qc.evidence_photo_url,
  qc.note,
  qc.checked_by,
  qc.created_at
FROM qc_checks qc
JOIN qc_templates qt ON qt.id = qc.template_id
JOIN stores r ON r.id = qc.store_id
WHERE r.store_type = 'direct';

-- ── v_inventory_status ──
CREATE OR REPLACE VIEW v_inventory_status AS
SELECT
  ii.id AS item_id,
  ii.store_id AS store_id,
  r.brand_id,
  r.name AS store_name,
  ii.name AS item_name,
  ii.current_stock,
  ii.unit,
  ii.reorder_point,
  ii.cost_per_unit,
  ii.supplier_name,
  CASE WHEN ii.reorder_point IS NOT NULL AND ii.current_stock <= ii.reorder_point
    THEN TRUE ELSE FALSE END AS needs_reorder,
  ii.updated_at AS last_updated
FROM inventory_items ii
JOIN stores r ON r.id = ii.store_id
WHERE r.store_type = 'direct';

-- ── v_brand_kpi ──
CREATE OR REPLACE VIEW v_brand_kpi AS
SELECT
  b.id AS brand_id,
  b.code AS brand_code,
  b.name AS brand_name,
  COUNT(DISTINCT r.id) AS store_count,
  COUNT(DISTINCT u.id) FILTER (WHERE u.is_active = TRUE) AS active_staff_count,
  (
    SELECT COALESCE(SUM(p.amount), 0)
    FROM payments p
    JOIN stores r2 ON r2.id = p.store_id
    WHERE r2.brand_id = b.id
      AND r2.store_type = 'direct'
      AND p.is_revenue = TRUE
      AND p.created_at >= date_trunc('month', now() AT TIME ZONE 'Asia/Ho_Chi_Minh')
  ) AS mtd_revenue,
  (
    SELECT COUNT(DISTINCT p.order_id)
    FROM payments p
    JOIN stores r2 ON r2.id = p.store_id
    WHERE r2.brand_id = b.id
      AND r2.store_type = 'direct'
      AND p.is_revenue = TRUE
      AND p.created_at >= date_trunc('month', now() AT TIME ZONE 'Asia/Ho_Chi_Minh')
  ) AS mtd_order_count
FROM brands b
LEFT JOIN stores r ON r.brand_id = b.id AND r.store_type = 'direct'
LEFT JOIN users u ON u.store_id = r.id
GROUP BY b.id, b.code, b.name;

-- ── v_external_store_sales ──
CREATE OR REPLACE VIEW v_external_store_sales AS
SELECT
  r.id AS store_id,
  r.brand_id,
  b.name AS brand_name,
  r.name AS store_name,
  DATE(p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh') AS sale_date,
  COUNT(DISTINCT p.order_id) AS order_count,
  SUM(CASE WHEN p.is_revenue THEN p.amount ELSE 0 END) AS revenue,
  SUM(CASE WHEN NOT p.is_revenue THEN p.amount ELSE 0 END) AS service_amount
FROM payments p
JOIN stores r ON r.id = p.store_id
LEFT JOIN brands b ON b.id = r.brand_id
WHERE r.store_type = 'external'
GROUP BY r.id, r.brand_id, b.name, r.name,
         DATE(p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh');

-- ── v_external_store_overview ──
CREATE OR REPLACE VIEW v_external_store_overview AS
SELECT
  r.id AS store_id,
  r.name AS store_name,
  b.name AS brand_name,
  r.brand_id,
  r.is_active,
  r.created_at AS registered_at,
  (SELECT COUNT(*) FROM users u
   WHERE u.store_id = r.id AND u.is_active = TRUE) AS active_staff,
  (SELECT COALESCE(SUM(p.amount), 0)
   FROM payments p
   WHERE p.store_id = r.id AND p.is_revenue = TRUE
     AND p.created_at >= date_trunc('month', now())) AS mtd_sales,
  (SELECT COUNT(DISTINCT o.id)
   FROM orders o
   WHERE o.store_id = r.id
     AND o.created_at >= date_trunc('month', now())) AS mtd_order_count
FROM stores r
LEFT JOIN brands b ON b.id = r.brand_id
WHERE r.store_type = 'external';

-- ── v_daily_revenue_by_channel ──
CREATE OR REPLACE VIEW v_daily_revenue_by_channel AS
SELECT
  COALESCE(pos.store_id, del.store_id) AS store_id,
  COALESCE(pos.sale_date, del.sale_date)          AS sale_date,
  COALESCE(pos.dine_in_revenue, 0)                AS dine_in_revenue,
  COALESCE(pos.dine_in_orders, 0)                 AS dine_in_orders,
  COALESCE(pos.takeaway_revenue, 0)               AS takeaway_revenue,
  COALESCE(pos.takeaway_orders, 0)                AS takeaway_orders,
  COALESCE(del.delivery_revenue, 0)               AS delivery_revenue,
  COALESCE(del.delivery_orders, 0)                AS delivery_orders,
  COALESCE(pos.dine_in_revenue, 0)
    + COALESCE(pos.takeaway_revenue, 0)
    + COALESCE(del.delivery_revenue, 0)           AS total_revenue
FROM (
  SELECT
    o.store_id,
    (p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS sale_date,
    SUM(CASE WHEN o.sales_channel = 'dine_in'  THEN p.amount ELSE 0 END) AS dine_in_revenue,
    COUNT(CASE WHEN o.sales_channel = 'dine_in'  THEN 1 END)             AS dine_in_orders,
    SUM(CASE WHEN o.sales_channel = 'takeaway' THEN p.amount ELSE 0 END) AS takeaway_revenue,
    COUNT(CASE WHEN o.sales_channel = 'takeaway' THEN 1 END)             AS takeaway_orders
  FROM orders o
  JOIN payments p ON p.order_id = o.id
  WHERE o.status = 'completed' AND p.is_revenue = true
  GROUP BY o.store_id, (p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
) pos
FULL OUTER JOIN (
  SELECT
    store_id,
    (completed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS sale_date,
    SUM(gross_amount) AS delivery_revenue,
    COUNT(*)          AS delivery_orders
  FROM external_sales
  WHERE is_revenue = true AND order_status = 'completed'
  GROUP BY store_id, (completed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
) del
ON pos.store_id = del.store_id AND pos.sale_date = del.sale_date;

-- ── v_settlement_summary ──
CREATE OR REPLACE VIEW v_settlement_summary AS
SELECT
  ds.id,
  ds.store_id,
  ds.period_label,
  ds.period_start,
  ds.period_end,
  ds.gross_total,
  ds.total_deductions,
  ds.net_settlement,
  ds.status,
  ds.received_at,
  COALESCE(
    (SELECT jsonb_agg(jsonb_build_object(
      'item_type', dsi.item_type,
      'amount', dsi.amount,
      'description', dsi.description,
      'reference_rate', dsi.reference_rate
    ) ORDER BY dsi.item_type)
    FROM delivery_settlement_items dsi
    WHERE dsi.settlement_id = ds.id),
    '[]'::jsonb
  ) AS items,
  (SELECT COUNT(*) FROM external_sales es
   WHERE es.settlement_id = ds.id AND es.is_revenue = true
  ) AS order_count
FROM delivery_settlements ds;

-- Re-grant view access
GRANT SELECT ON v_store_daily_sales TO authenticated;
GRANT SELECT ON v_store_attendance_summary TO authenticated;
GRANT SELECT ON v_quality_monitoring TO authenticated;
GRANT SELECT ON v_inventory_status TO authenticated;
GRANT SELECT ON v_brand_kpi TO authenticated;
GRANT SELECT ON v_external_store_sales TO authenticated;
GRANT SELECT ON v_external_store_overview TO authenticated;

-- ============================================================================
-- SECTION 7: Functions that CHANGE NAME (drop old, create new)
-- ============================================================================

-- ── require_admin_actor_for_restaurant → require_admin_actor_for_store ──
DROP FUNCTION IF EXISTS public.require_admin_actor_for_restaurant(UUID);

CREATE OR REPLACE FUNCTION public.require_admin_actor_for_store(
  p_store_id UUID
) RETURNS public.users AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'ADMIN_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'ADMIN_MUTATION_FORBIDDEN';
  END IF;

  RETURN v_actor;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── admin_create_restaurant → admin_create_store ──
DROP FUNCTION IF EXISTS public.admin_create_restaurant(TEXT, TEXT, TEXT, TEXT, DECIMAL, UUID, TEXT);

CREATE OR REPLACE FUNCTION public.admin_create_store(
  p_name TEXT,
  p_slug TEXT,
  p_operation_mode TEXT,
  p_address TEXT DEFAULT NULL,
  p_per_person_charge DECIMAL(12,2) DEFAULT NULL,
  p_brand_id UUID DEFAULT NULL,
  p_store_type TEXT DEFAULT 'direct'
) RETURNS public.stores AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_created public.stores%ROWTYPE;
BEGIN
  IF NULLIF(btrim(COALESCE(p_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'STORE_NAME_REQUIRED';
  END IF;

  IF NULLIF(btrim(COALESCE(p_operation_mode, '')), '') IS NULL THEN
    RAISE EXCEPTION 'STORE_OPERATION_MODE_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'STORE_CREATE_FORBIDDEN';
  END IF;

  INSERT INTO public.stores (
    name,
    address,
    slug,
    operation_mode,
    per_person_charge,
    brand_id,
    store_type,
    is_active,
    created_at
  )
  VALUES (
    btrim(p_name),
    NULLIF(btrim(COALESCE(p_address, '')), ''),
    NULLIF(btrim(COALESCE(p_slug, '')), ''),
    lower(p_operation_mode),
    p_per_person_charge,
    p_brand_id,
    COALESCE(p_store_type, 'direct'),
    TRUE,
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_create_store',
    'stores',
    v_created.id,
    jsonb_build_object(
      'store_id', v_created.id,
      'created_at_utc', now(),
      'new_values', jsonb_build_object(
        'name', v_created.name,
        'address', v_created.address,
        'slug', v_created.slug,
        'operation_mode', v_created.operation_mode,
        'per_person_charge', v_created.per_person_charge,
        'brand_id', v_created.brand_id,
        'store_type', v_created.store_type,
        'is_active', v_created.is_active
      )
    )
  );

  RETURN v_created;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── admin_update_restaurant → admin_update_store ──
DROP FUNCTION IF EXISTS public.admin_update_restaurant(UUID, TEXT, TEXT, TEXT, TEXT, DECIMAL, UUID, TEXT);

CREATE OR REPLACE FUNCTION public.admin_update_store(
  p_store_id UUID,
  p_name TEXT,
  p_slug TEXT,
  p_operation_mode TEXT,
  p_address TEXT DEFAULT NULL,
  p_per_person_charge DECIMAL(12,2) DEFAULT NULL,
  p_brand_id UUID DEFAULT NULL,
  p_store_type TEXT DEFAULT 'direct'
) RETURNS public.stores AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_existing public.stores%ROWTYPE;
  v_updated public.stores%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_name TEXT := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_slug TEXT := NULLIF(btrim(COALESCE(p_slug, '')), '');
  v_operation_mode TEXT := lower(COALESCE(p_operation_mode, ''));
  v_address TEXT := NULLIF(btrim(COALESCE(p_address, '')), '');
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_ID_REQUIRED';
  END IF;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'STORE_NAME_REQUIRED';
  END IF;

  IF v_operation_mode = '' THEN
    RAISE EXCEPTION 'STORE_OPERATION_MODE_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.stores
  WHERE id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;

  v_actor := public.require_admin_actor_for_store(v_existing.id);

  IF v_name IS DISTINCT FROM v_existing.name THEN
    v_changed_fields := array_append(v_changed_fields, 'name');
    v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
    v_new_values := v_new_values || jsonb_build_object('name', v_name);
  END IF;

  IF v_address IS DISTINCT FROM v_existing.address THEN
    v_changed_fields := array_append(v_changed_fields, 'address');
    v_old_values := v_old_values || jsonb_build_object('address', v_existing.address);
    v_new_values := v_new_values || jsonb_build_object('address', v_address);
  END IF;

  IF v_slug IS DISTINCT FROM v_existing.slug THEN
    v_changed_fields := array_append(v_changed_fields, 'slug');
    v_old_values := v_old_values || jsonb_build_object('slug', v_existing.slug);
    v_new_values := v_new_values || jsonb_build_object('slug', v_slug);
  END IF;

  IF v_operation_mode IS DISTINCT FROM v_existing.operation_mode THEN
    v_changed_fields := array_append(v_changed_fields, 'operation_mode');
    v_old_values := v_old_values || jsonb_build_object('operation_mode', v_existing.operation_mode);
    v_new_values := v_new_values || jsonb_build_object('operation_mode', v_operation_mode);
  END IF;

  IF p_per_person_charge IS DISTINCT FROM v_existing.per_person_charge THEN
    v_changed_fields := array_append(v_changed_fields, 'per_person_charge');
    v_old_values := v_old_values || jsonb_build_object('per_person_charge', v_existing.per_person_charge);
    v_new_values := v_new_values || jsonb_build_object('per_person_charge', p_per_person_charge);
  END IF;

  IF p_brand_id IS DISTINCT FROM v_existing.brand_id THEN
    v_changed_fields := array_append(v_changed_fields, 'brand_id');
    v_old_values := v_old_values || jsonb_build_object('brand_id', v_existing.brand_id);
    v_new_values := v_new_values || jsonb_build_object('brand_id', p_brand_id);
  END IF;

  IF COALESCE(p_store_type, 'direct') IS DISTINCT FROM v_existing.store_type THEN
    v_changed_fields := array_append(v_changed_fields, 'store_type');
    v_old_values := v_old_values || jsonb_build_object('store_type', v_existing.store_type);
    v_new_values := v_new_values || jsonb_build_object('store_type', COALESCE(p_store_type, 'direct'));
  END IF;

  UPDATE public.stores
  SET name = v_name,
      address = v_address,
      slug = v_slug,
      operation_mode = v_operation_mode,
      per_person_charge = p_per_person_charge,
      brand_id = p_brand_id,
      store_type = COALESCE(p_store_type, 'direct')
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_store',
      'stores',
      v_updated.id,
      jsonb_build_object(
        'store_id', v_updated.id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── admin_deactivate_restaurant → admin_deactivate_store ──
DROP FUNCTION IF EXISTS public.admin_deactivate_restaurant(UUID);

CREATE OR REPLACE FUNCTION public.admin_deactivate_store(
  p_store_id UUID
) RETURNS public.stores AS $$
DECLARE
  v_existing public.stores%ROWTYPE;
  v_updated public.stores%ROWTYPE;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.stores
  WHERE id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_store(v_existing.id);

  UPDATE public.stores
  SET is_active = FALSE
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_deactivate_store',
    'stores',
    v_updated.id,
    jsonb_build_object(
      'store_id', v_updated.id,
      'changed_fields', jsonb_build_array('is_active'),
      'old_values', jsonb_build_object('is_active', v_existing.is_active),
      'new_values', jsonb_build_object('is_active', v_updated.is_active),
      'updated_at_utc', now()
    )
  );

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── admin_update_restaurant_settings → admin_update_store_settings ──
DROP FUNCTION IF EXISTS public.admin_update_restaurant_settings(UUID, TEXT, TEXT, TEXT, DECIMAL);

CREATE OR REPLACE FUNCTION public.admin_update_store_settings(
  p_store_id UUID,
  p_name TEXT,
  p_operation_mode TEXT,
  p_address TEXT DEFAULT NULL,
  p_per_person_charge DECIMAL(12,2) DEFAULT NULL
) RETURNS public.stores AS $$
DECLARE
  v_existing public.stores%ROWTYPE;
  v_updated public.stores%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_name TEXT := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_operation_mode TEXT := lower(COALESCE(p_operation_mode, ''));
  v_address TEXT := NULLIF(btrim(COALESCE(p_address, '')), '');
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_ID_REQUIRED';
  END IF;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'STORE_NAME_REQUIRED';
  END IF;

  IF v_operation_mode = '' THEN
    RAISE EXCEPTION 'STORE_OPERATION_MODE_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.stores
  WHERE id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_store(v_existing.id);

  IF v_name IS DISTINCT FROM v_existing.name THEN
    v_changed_fields := array_append(v_changed_fields, 'name');
    v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
    v_new_values := v_new_values || jsonb_build_object('name', v_name);
  END IF;

  IF v_address IS DISTINCT FROM v_existing.address THEN
    v_changed_fields := array_append(v_changed_fields, 'address');
    v_old_values := v_old_values || jsonb_build_object('address', v_existing.address);
    v_new_values := v_new_values || jsonb_build_object('address', v_address);
  END IF;

  IF v_operation_mode IS DISTINCT FROM v_existing.operation_mode THEN
    v_changed_fields := array_append(v_changed_fields, 'operation_mode');
    v_old_values := v_old_values || jsonb_build_object('operation_mode', v_existing.operation_mode);
    v_new_values := v_new_values || jsonb_build_object('operation_mode', v_operation_mode);
  END IF;

  IF p_per_person_charge IS DISTINCT FROM v_existing.per_person_charge THEN
    v_changed_fields := array_append(v_changed_fields, 'per_person_charge');
    v_old_values := v_old_values || jsonb_build_object('per_person_charge', v_existing.per_person_charge);
    v_new_values := v_new_values || jsonb_build_object('per_person_charge', p_per_person_charge);
  END IF;

  UPDATE public.stores
  SET name = v_name,
      address = v_address,
      operation_mode = v_operation_mode,
      per_person_charge = p_per_person_charge
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_store_settings',
      'stores',
      v_updated.id,
      jsonb_build_object(
        'store_id', v_updated.id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ============================================================================
-- SECTION 8: Functions that KEEP NAME but body changes
-- All functions with restaurant_id references in their body need updating.
-- ============================================================================

-- ── create_order ──
CREATE OR REPLACE FUNCTION create_order(
  p_store_id UUID,
  p_table_id UUID,
  p_items JSONB
) RETURNS orders AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_table tables%ROWTYPE;
  v_order orders%ROWTYPE;
  v_item_count INT := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  SELECT *
  INTO v_table
  FROM tables
  WHERE id = p_table_id
    AND store_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  IF v_table.status = 'occupied' THEN
    RAISE EXCEPTION 'TABLE_ALREADY_OCCUPIED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    WHERE NULLIF(item->>'menu_item_id', '') IS NULL
       OR COALESCE((item->>'quantity')::INT, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    LEFT JOIN menu_items m
      ON m.id = (item->>'menu_item_id')::UUID
     AND m.store_id = p_store_id
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  INSERT INTO orders (store_id, table_id, status, created_by)
  VALUES (p_store_id, p_table_id, 'pending', auth.uid())
  RETURNING * INTO v_order;

  INSERT INTO order_items (
    order_id,
    menu_item_id,
    quantity,
    unit_price,
    label,
    store_id,
    item_type
  )
  SELECT
    v_order.id,
    m.id,
    (item->>'quantity')::INT,
    m.price,
    m.name,
    p_store_id,
    'standard'
  FROM jsonb_array_elements(p_items) item
  JOIN menu_items m
    ON m.id = (item->>'menu_item_id')::UUID
   AND m.store_id = p_store_id
   AND m.is_available = TRUE;

  GET DIAGNOSTICS v_item_count = ROW_COUNT;

  UPDATE tables
  SET status = 'occupied',
      updated_at = now()
  WHERE id = p_table_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'create_order',
    'orders',
    v_order.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'table_id', p_table_id,
      'item_count', v_item_count,
      'sales_channel', 'dine_in'
    )
  );

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── create_buffet_order ──
CREATE OR REPLACE FUNCTION create_buffet_order(
  p_store_id UUID,
  p_table_id UUID,
  p_guest_count INT,
  p_extra_items JSONB DEFAULT '[]'
) RETURNS orders AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_table tables%ROWTYPE;
  v_operation_mode TEXT;
  v_per_person_charge DECIMAL(12,2);
  v_order orders%ROWTYPE;
  v_extra_item_count INT := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_table
  FROM tables
  WHERE id = p_table_id
    AND store_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  IF v_table.status = 'occupied' THEN
    RAISE EXCEPTION 'TABLE_ALREADY_OCCUPIED';
  END IF;

  SELECT operation_mode, per_person_charge
  INTO v_operation_mode, v_per_person_charge
  FROM stores
  WHERE id = p_store_id;

  IF v_operation_mode NOT IN ('buffet', 'hybrid') THEN
    RAISE EXCEPTION 'OPERATION_MODE_MISMATCH';
  END IF;

  IF p_guest_count IS NULL OR p_guest_count < 1 THEN
    RAISE EXCEPTION 'BUFFET_GUEST_COUNT_REQUIRED';
  END IF;

  IF jsonb_typeof(p_extra_items) <> 'array' THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_extra_items) item
    WHERE NULLIF(item->>'menu_item_id', '') IS NULL
       OR COALESCE((item->>'quantity')::INT, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_extra_items) item
    LEFT JOIN menu_items m
      ON m.id = (item->>'menu_item_id')::UUID
     AND m.store_id = p_store_id
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  INSERT INTO orders (
    store_id,
    table_id,
    status,
    created_by,
    guest_count
  )
  VALUES (p_store_id, p_table_id, 'pending', auth.uid(), p_guest_count)
  RETURNING * INTO v_order;

  INSERT INTO order_items (
    order_id,
    store_id,
    item_type,
    label,
    unit_price,
    quantity,
    status
  )
  VALUES (
    v_order.id,
    p_store_id,
    'buffet_base',
    '1인 고정 요금',
    v_per_person_charge,
    p_guest_count,
    'served'
  );

  IF jsonb_array_length(p_extra_items) > 0 THEN
    INSERT INTO order_items (
      order_id,
      menu_item_id,
      quantity,
      unit_price,
      label,
      store_id,
      item_type
    )
    SELECT
      v_order.id,
      m.id,
      (item->>'quantity')::INT,
      m.price,
      m.name,
      p_store_id,
      'a_la_carte'
    FROM jsonb_array_elements(p_extra_items) item
    JOIN menu_items m
      ON m.id = (item->>'menu_item_id')::UUID
     AND m.store_id = p_store_id
     AND m.is_available = TRUE;

    GET DIAGNOSTICS v_extra_item_count = ROW_COUNT;
  END IF;

  UPDATE tables
  SET status = 'occupied',
      updated_at = now()
  WHERE id = p_table_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'create_buffet_order',
    'orders',
    v_order.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'table_id', p_table_id,
      'guest_count', p_guest_count,
      'extra_item_count', v_extra_item_count,
      'operation_mode', v_operation_mode
    )
  );

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── add_items_to_order ──
CREATE OR REPLACE FUNCTION add_items_to_order(
  p_order_id UUID,
  p_store_id UUID,
  p_items JSONB
) RETURNS SETOF order_items AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
  v_inserted_count INT := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  SELECT *
  INTO v_order
  FROM orders
  WHERE id = p_order_id
    AND store_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    WHERE NULLIF(item->>'menu_item_id', '') IS NULL
       OR COALESCE((item->>'quantity')::INT, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    LEFT JOIN menu_items m
      ON m.id = (item->>'menu_item_id')::UUID
     AND m.store_id = p_store_id
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  RETURN QUERY
  INSERT INTO order_items (
    order_id,
    menu_item_id,
    quantity,
    unit_price,
    label,
    store_id,
    item_type
  )
  SELECT
    p_order_id,
    m.id,
    (item->>'quantity')::INT,
    m.price,
    m.name,
    p_store_id,
    'standard'
  FROM jsonb_array_elements(p_items) item
  JOIN menu_items m
    ON m.id = (item->>'menu_item_id')::UUID
   AND m.store_id = p_store_id
   AND m.is_available = TRUE
  RETURNING *;

  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

  UPDATE orders
  SET updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'add_items_to_order',
    'orders',
    p_order_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'added_item_count', v_inserted_count
    )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── process_payment ──
CREATE OR REPLACE FUNCTION process_payment(
  p_order_id UUID,
  p_store_id UUID,
  p_amount DECIMAL(12,2),
  p_method TEXT
) RETURNS payments AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
  v_payment payments%ROWTYPE;
  v_table_id UUID;
  v_is_revenue BOOLEAN;
  v_item RECORD;
  v_recipe RECORD;
  v_deduct_qty DECIMAL(12,3);
  v_expected_amount DECIMAL(12,2);
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN';
  END IF;

  IF p_method NOT IN ('cash', 'card', 'pay', 'service') THEN
    RAISE EXCEPTION 'INVALID_PAYMENT_METHOD';
  END IF;

  SELECT *
  INTO v_order
  FROM orders
  WHERE id = p_order_id
    AND store_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_PAYABLE';
  END IF;

  IF EXISTS (SELECT 1 FROM payments WHERE order_id = p_order_id) THEN
    RAISE EXCEPTION 'PAYMENT_ALREADY_EXISTS';
  END IF;

  SELECT COALESCE(SUM(unit_price * quantity), 0)
  INTO v_expected_amount
  FROM order_items
  WHERE order_id = p_order_id
    AND status <> 'cancelled';

  IF v_expected_amount <= 0 THEN
    RAISE EXCEPTION 'ORDER_TOTAL_INVALID';
  END IF;

  IF ROUND(COALESCE(p_amount, 0)::numeric, 2) <> ROUND(v_expected_amount, 2) THEN
    RAISE EXCEPTION 'PAYMENT_AMOUNT_MISMATCH';
  END IF;

  v_is_revenue := (p_method <> 'service');

  INSERT INTO payments (
    order_id,
    store_id,
    amount,
    method,
    processed_by,
    is_revenue
  )
  VALUES (
    p_order_id,
    p_store_id,
    p_amount,
    p_method,
    auth.uid(),
    v_is_revenue
  )
  RETURNING * INTO v_payment;

  UPDATE orders
  SET status = 'completed',
      updated_at = now()
  WHERE id = p_order_id
  RETURNING table_id INTO v_table_id;

  IF v_table_id IS NOT NULL THEN
    UPDATE tables
    SET status = 'available',
        updated_at = now()
    WHERE id = v_table_id;
  END IF;

  -- Inventory deduction EXCLUDING cancelled items
  FOR v_item IN
    SELECT oi.id AS order_item_id, oi.menu_item_id, oi.quantity AS ordered_qty
    FROM order_items oi
    WHERE oi.order_id = p_order_id
      AND oi.menu_item_id IS NOT NULL
      AND oi.status <> 'cancelled'
  LOOP
    FOR v_recipe IN
      SELECT mr.ingredient_id, mr.quantity_g
      FROM menu_recipes mr
      WHERE mr.menu_item_id = v_item.menu_item_id
        AND mr.store_id = p_store_id
    LOOP
      v_deduct_qty := v_item.ordered_qty * v_recipe.quantity_g;
      UPDATE inventory_items
      SET current_stock = current_stock - v_deduct_qty,
          updated_at = now()
      WHERE id = v_recipe.ingredient_id
        AND store_id = p_store_id;

      INSERT INTO inventory_transactions (
        store_id,
        ingredient_id,
        transaction_type,
        quantity_g,
        reference_type,
        reference_id,
        created_by
      )
      VALUES (
        p_store_id,
        v_recipe.ingredient_id,
        'deduct',
        -v_deduct_qty,
        'order_item',
        v_item.order_item_id,
        auth.uid()
      );
    END LOOP;
  END LOOP;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'process_payment',
    'payments',
    v_payment.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', p_order_id,
      'amount', p_amount,
      'method', p_method,
      'is_revenue', v_is_revenue
    )
  );

  RETURN v_payment;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── cancel_order ──
CREATE OR REPLACE FUNCTION cancel_order(
  p_order_id UUID,
  p_store_id UUID
) RETURNS orders AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_order
  FROM orders
  WHERE id = p_order_id
    AND store_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status NOT IN ('pending', 'confirmed') THEN
    RAISE EXCEPTION 'ORDER_NOT_CANCELLABLE';
  END IF;

  UPDATE orders
  SET status = 'cancelled',
      updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  IF v_order.table_id IS NOT NULL THEN
    UPDATE tables
    SET status = 'available',
        updated_at = now()
    WHERE id = v_order.table_id;
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'cancel_order',
    'orders',
    p_order_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'from_status', 'pending_or_confirmed',
      'to_status', 'cancelled'
    )
  );

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── cancel_order_item ──
CREATE OR REPLACE FUNCTION cancel_order_item(
  p_item_id UUID,
  p_store_id UUID
) RETURNS order_items AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_item order_items%ROWTYPE;
  v_order_status TEXT;
  v_from_status TEXT;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_item
  FROM order_items
  WHERE id = p_item_id
    AND store_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  SELECT status
  INTO v_order_status
  FROM orders
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF v_item.status NOT IN ('pending', 'preparing') THEN
    RAISE EXCEPTION 'ITEM_NOT_CANCELLABLE';
  END IF;

  v_from_status := v_item.status;

  UPDATE order_items
  SET status = 'cancelled'
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  UPDATE orders
  SET updated_at = now()
  WHERE id = v_item.order_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'cancel_order_item',
    'order_items',
    p_item_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_item.order_id,
      'from_status', v_from_status,
      'to_status', 'cancelled',
      'label', v_item.label,
      'quantity', v_item.quantity,
      'unit_price', v_item.unit_price
    )
  );

  RETURN v_item;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── edit_order_item_quantity ──
CREATE OR REPLACE FUNCTION edit_order_item_quantity(
  p_item_id UUID,
  p_store_id UUID,
  p_new_quantity INT
) RETURNS order_items AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_item order_items%ROWTYPE;
  v_order_status TEXT;
  v_old_quantity INT;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF p_new_quantity IS NULL OR p_new_quantity < 1 THEN
    RAISE EXCEPTION 'INVALID_QUANTITY';
  END IF;

  SELECT *
  INTO v_item
  FROM order_items
  WHERE id = p_item_id
    AND store_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  SELECT status
  INTO v_order_status
  FROM orders
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF v_item.status <> 'pending' THEN
    RAISE EXCEPTION 'ITEM_NOT_EDITABLE';
  END IF;

  v_old_quantity := v_item.quantity;

  IF v_old_quantity = p_new_quantity THEN
    RETURN v_item;
  END IF;

  UPDATE order_items
  SET quantity = p_new_quantity
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  UPDATE orders
  SET updated_at = now()
  WHERE id = v_item.order_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'edit_order_item_quantity',
    'order_items',
    p_item_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_item.order_id,
      'label', v_item.label,
      'old_quantity', v_old_quantity,
      'new_quantity', p_new_quantity
    )
  );

  RETURN v_item;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── transfer_order_table ──
CREATE OR REPLACE FUNCTION transfer_order_table(
  p_order_id UUID,
  p_store_id UUID,
  p_new_table_id UUID
) RETURNS orders AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
  v_old_table_id UUID;
  v_new_table tables%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_order
  FROM orders
  WHERE id = p_order_id
    AND store_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  v_old_table_id := v_order.table_id;

  IF v_old_table_id = p_new_table_id THEN
    RAISE EXCEPTION 'TRANSFER_SAME_TABLE';
  END IF;

  SELECT *
  INTO v_new_table
  FROM tables
  WHERE id = p_new_table_id
    AND store_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  IF v_new_table.status <> 'available' THEN
    RAISE EXCEPTION 'TABLE_ALREADY_OCCUPIED';
  END IF;

  UPDATE orders
  SET table_id = p_new_table_id,
      updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  UPDATE tables
  SET status = 'occupied',
      updated_at = now()
  WHERE id = p_new_table_id;

  IF v_old_table_id IS NOT NULL THEN
    UPDATE tables
    SET status = 'available',
        updated_at = now()
    WHERE id = v_old_table_id;
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'transfer_order_table',
    'orders',
    p_order_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'old_table_id', v_old_table_id,
      'new_table_id', p_new_table_id,
      'new_table_number', v_new_table.table_number
    )
  );

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── update_order_item_status ──
CREATE OR REPLACE FUNCTION update_order_item_status(
  p_item_id UUID,
  p_store_id UUID,
  p_new_status TEXT
) RETURNS order_items AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_item order_items%ROWTYPE;
  v_order_status TEXT;
  v_from_status TEXT;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin', 'kitchen') THEN
    RAISE EXCEPTION 'ORDER_ITEM_STATUS_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'ORDER_ITEM_STATUS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_item
  FROM order_items
  WHERE id = p_item_id
    AND store_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  SELECT status
  INTO v_order_status
  FROM orders
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF v_item.status = 'cancelled' THEN
    RAISE EXCEPTION 'ITEM_IS_CANCELLED';
  END IF;

  IF NOT (
    (v_item.status = 'pending' AND p_new_status = 'preparing')
    OR (v_item.status = 'preparing' AND p_new_status = 'ready')
    OR (v_item.status = 'ready' AND p_new_status = 'served')
    OR v_item.status = p_new_status
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_STATUS_TRANSITION';
  END IF;

  v_from_status := v_item.status;

  UPDATE order_items
  SET status = p_new_status
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'update_order_item_status',
    'order_items',
    p_item_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'from_status', v_from_status,
      'to_status', p_new_status
    )
  );

  RETURN v_item;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── admin_create_table ──
CREATE OR REPLACE FUNCTION public.admin_create_table(
  p_store_id UUID,
  p_table_number TEXT,
  p_seat_count INT
) RETURNS public.tables AS $$
DECLARE
  v_created public.tables%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_store(p_store_id);

  IF NULLIF(btrim(COALESCE(p_table_number, '')), '') IS NULL THEN
    RAISE EXCEPTION 'TABLE_NUMBER_REQUIRED';
  END IF;

  INSERT INTO public.tables (
    store_id,
    table_number,
    seat_count,
    status,
    created_at,
    updated_at
  )
  VALUES (
    p_store_id,
    btrim(p_table_number),
    p_seat_count,
    'available',
    now(),
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_create_table',
    'tables',
    v_created.id,
    jsonb_build_object(
      'store_id', v_created.store_id,
      'created_at_utc', now(),
      'new_values', jsonb_build_object(
        'table_number', v_created.table_number,
        'seat_count', v_created.seat_count,
        'status', v_created.status
      )
    )
  );

  RETURN v_created;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── admin_update_table ──
CREATE OR REPLACE FUNCTION public.admin_update_table(
  p_table_id UUID,
  p_table_number TEXT DEFAULT NULL,
  p_seat_count INT DEFAULT NULL,
  p_status TEXT DEFAULT NULL
) RETURNS public.tables AS $$
DECLARE
  v_existing public.tables%ROWTYPE;
  v_updated public.tables%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_table_number TEXT := NULLIF(btrim(COALESCE(p_table_number, '')), '');
BEGIN
  IF p_table_id IS NULL THEN
    RAISE EXCEPTION 'TABLE_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.tables
  WHERE id = p_table_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_store(v_existing.store_id);

  IF p_table_number IS NOT NULL THEN
    IF v_table_number IS NULL THEN
      RAISE EXCEPTION 'TABLE_NUMBER_REQUIRED';
    END IF;
    IF v_table_number IS DISTINCT FROM v_existing.table_number THEN
      v_changed_fields := array_append(v_changed_fields, 'table_number');
      v_old_values := v_old_values || jsonb_build_object('table_number', v_existing.table_number);
      v_new_values := v_new_values || jsonb_build_object('table_number', v_table_number);
    END IF;
  ELSE
    v_table_number := v_existing.table_number;
  END IF;

  IF p_seat_count IS NOT NULL AND p_seat_count IS DISTINCT FROM v_existing.seat_count THEN
    v_changed_fields := array_append(v_changed_fields, 'seat_count');
    v_old_values := v_old_values || jsonb_build_object('seat_count', v_existing.seat_count);
    v_new_values := v_new_values || jsonb_build_object('seat_count', p_seat_count);
  END IF;

  IF p_status IS NOT NULL AND p_status IS DISTINCT FROM v_existing.status THEN
    v_changed_fields := array_append(v_changed_fields, 'status');
    v_old_values := v_old_values || jsonb_build_object('status', v_existing.status);
    v_new_values := v_new_values || jsonb_build_object('status', p_status);
  END IF;

  UPDATE public.tables
  SET table_number = v_table_number,
      seat_count = COALESCE(p_seat_count, v_existing.seat_count),
      status = COALESCE(p_status, v_existing.status),
      updated_at = now()
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_table',
      'tables',
      v_updated.id,
      jsonb_build_object(
        'store_id', v_updated.store_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── admin_delete_table ──
CREATE OR REPLACE FUNCTION public.admin_delete_table(
  p_table_id UUID
) RETURNS public.tables AS $$
DECLARE
  v_existing public.tables%ROWTYPE;
BEGIN
  IF p_table_id IS NULL THEN
    RAISE EXCEPTION 'TABLE_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.tables
  WHERE id = p_table_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_store(v_existing.store_id);

  DELETE FROM public.tables
  WHERE id = v_existing.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_delete_table',
    'tables',
    v_existing.id,
    jsonb_build_object(
      'store_id', v_existing.store_id,
      'deleted_at_utc', now(),
      'old_values', jsonb_build_object(
        'table_number', v_existing.table_number,
        'seat_count', v_existing.seat_count,
        'status', v_existing.status
      )
    )
  );

  RETURN v_existing;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── admin_create_menu_category ──
CREATE OR REPLACE FUNCTION public.admin_create_menu_category(
  p_store_id UUID,
  p_name TEXT,
  p_sort_order INT DEFAULT 0
) RETURNS public.menu_categories AS $$
DECLARE
  v_created public.menu_categories%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_store(p_store_id);

  IF NULLIF(btrim(COALESCE(p_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NAME_REQUIRED';
  END IF;

  INSERT INTO public.menu_categories (
    store_id,
    name,
    sort_order,
    is_active,
    created_at
  )
  VALUES (
    p_store_id,
    btrim(p_name),
    COALESCE(p_sort_order, 0),
    TRUE,
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_create_menu_category',
    'menu_categories',
    v_created.id,
    jsonb_build_object(
      'store_id', v_created.store_id,
      'created_at_utc', now(),
      'new_values', jsonb_build_object(
        'name', v_created.name,
        'sort_order', v_created.sort_order,
        'is_active', v_created.is_active
      )
    )
  );

  RETURN v_created;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── admin_update_menu_category ──
CREATE OR REPLACE FUNCTION public.admin_update_menu_category(
  p_category_id UUID,
  p_name TEXT DEFAULT NULL,
  p_sort_order INT DEFAULT NULL,
  p_is_active BOOLEAN DEFAULT NULL
) RETURNS public.menu_categories AS $$
DECLARE
  v_existing public.menu_categories%ROWTYPE;
  v_updated public.menu_categories%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_name TEXT := NULLIF(btrim(COALESCE(p_name, '')), '');
BEGIN
  IF p_category_id IS NULL THEN
    RAISE EXCEPTION 'MENU_CATEGORY_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.menu_categories
  WHERE id = p_category_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_store(v_existing.store_id);

  IF p_name IS NOT NULL THEN
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'MENU_CATEGORY_NAME_REQUIRED';
    END IF;
    IF v_name IS DISTINCT FROM v_existing.name THEN
      v_changed_fields := array_append(v_changed_fields, 'name');
      v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
      v_new_values := v_new_values || jsonb_build_object('name', v_name);
    END IF;
  ELSE
    v_name := v_existing.name;
  END IF;

  IF p_sort_order IS NOT NULL AND p_sort_order IS DISTINCT FROM v_existing.sort_order THEN
    v_changed_fields := array_append(v_changed_fields, 'sort_order');
    v_old_values := v_old_values || jsonb_build_object('sort_order', v_existing.sort_order);
    v_new_values := v_new_values || jsonb_build_object('sort_order', p_sort_order);
  END IF;

  IF p_is_active IS NOT NULL AND p_is_active IS DISTINCT FROM v_existing.is_active THEN
    v_changed_fields := array_append(v_changed_fields, 'is_active');
    v_old_values := v_old_values || jsonb_build_object('is_active', v_existing.is_active);
    v_new_values := v_new_values || jsonb_build_object('is_active', p_is_active);
  END IF;

  UPDATE public.menu_categories
  SET name = v_name,
      sort_order = COALESCE(p_sort_order, v_existing.sort_order),
      is_active = COALESCE(p_is_active, v_existing.is_active)
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_menu_category',
      'menu_categories',
      v_updated.id,
      jsonb_build_object(
        'store_id', v_updated.store_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── admin_delete_menu_category ──
CREATE OR REPLACE FUNCTION public.admin_delete_menu_category(
  p_category_id UUID
) RETURNS public.menu_categories AS $$
DECLARE
  v_existing public.menu_categories%ROWTYPE;
BEGIN
  IF p_category_id IS NULL THEN
    RAISE EXCEPTION 'MENU_CATEGORY_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.menu_categories
  WHERE id = p_category_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_store(v_existing.store_id);

  DELETE FROM public.menu_categories
  WHERE id = v_existing.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_delete_menu_category',
    'menu_categories',
    v_existing.id,
    jsonb_build_object(
      'store_id', v_existing.store_id,
      'deleted_at_utc', now(),
      'old_values', jsonb_build_object(
        'name', v_existing.name,
        'sort_order', v_existing.sort_order,
        'is_active', v_existing.is_active
      )
    )
  );

  RETURN v_existing;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── admin_create_menu_item ──
CREATE OR REPLACE FUNCTION public.admin_create_menu_item(
  p_store_id UUID,
  p_category_id UUID,
  p_name TEXT,
  p_price DECIMAL(12,2),
  p_sort_order INT DEFAULT 0,
  p_description TEXT DEFAULT NULL,
  p_is_available BOOLEAN DEFAULT TRUE,
  p_is_visible_public BOOLEAN DEFAULT FALSE
) RETURNS public.menu_items AS $$
DECLARE
  v_created public.menu_items%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_store(p_store_id);

  IF NULLIF(btrim(COALESCE(p_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_NAME_REQUIRED';
  END IF;

  IF p_category_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.menu_categories
    WHERE id = p_category_id
      AND store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  INSERT INTO public.menu_items (
    store_id,
    category_id,
    name,
    description,
    price,
    is_available,
    is_visible_public,
    sort_order,
    created_at,
    updated_at
  )
  VALUES (
    p_store_id,
    p_category_id,
    btrim(p_name),
    NULLIF(btrim(COALESCE(p_description, '')), ''),
    p_price,
    COALESCE(p_is_available, TRUE),
    COALESCE(p_is_visible_public, FALSE),
    COALESCE(p_sort_order, 0),
    now(),
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_create_menu_item',
    'menu_items',
    v_created.id,
    jsonb_build_object(
      'store_id', v_created.store_id,
      'created_at_utc', now(),
      'new_values', jsonb_build_object(
        'category_id', v_created.category_id,
        'name', v_created.name,
        'description', v_created.description,
        'price', v_created.price,
        'is_available', v_created.is_available,
        'is_visible_public', v_created.is_visible_public,
        'sort_order', v_created.sort_order
      )
    )
  );

  RETURN v_created;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── admin_update_menu_item ──
CREATE OR REPLACE FUNCTION public.admin_update_menu_item(
  p_item_id UUID,
  p_category_id UUID DEFAULT NULL,
  p_name TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_price DECIMAL(12,2) DEFAULT NULL,
  p_is_available BOOLEAN DEFAULT NULL,
  p_is_visible_public BOOLEAN DEFAULT NULL,
  p_sort_order INT DEFAULT NULL
) RETURNS public.menu_items AS $$
DECLARE
  v_existing public.menu_items%ROWTYPE;
  v_updated public.menu_items%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_name TEXT := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_description TEXT := NULLIF(btrim(COALESCE(p_description, '')), '');
BEGIN
  IF p_item_id IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.menu_items
  WHERE id = p_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_store(v_existing.store_id);

  IF p_category_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.menu_categories
    WHERE id = p_category_id
      AND store_id = v_existing.store_id
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  IF p_name IS NOT NULL THEN
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'MENU_ITEM_NAME_REQUIRED';
    END IF;
    IF v_name IS DISTINCT FROM v_existing.name THEN
      v_changed_fields := array_append(v_changed_fields, 'name');
      v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
      v_new_values := v_new_values || jsonb_build_object('name', v_name);
    END IF;
  ELSE
    v_name := v_existing.name;
  END IF;

  IF p_category_id IS NOT NULL AND p_category_id IS DISTINCT FROM v_existing.category_id THEN
    v_changed_fields := array_append(v_changed_fields, 'category_id');
    v_old_values := v_old_values || jsonb_build_object('category_id', v_existing.category_id);
    v_new_values := v_new_values || jsonb_build_object('category_id', p_category_id);
  END IF;

  IF p_description IS NOT NULL AND v_description IS DISTINCT FROM v_existing.description THEN
    v_changed_fields := array_append(v_changed_fields, 'description');
    v_old_values := v_old_values || jsonb_build_object('description', v_existing.description);
    v_new_values := v_new_values || jsonb_build_object('description', v_description);
  END IF;

  IF p_price IS NOT NULL AND p_price IS DISTINCT FROM v_existing.price THEN
    v_changed_fields := array_append(v_changed_fields, 'price');
    v_old_values := v_old_values || jsonb_build_object('price', v_existing.price);
    v_new_values := v_new_values || jsonb_build_object('price', p_price);
  END IF;

  IF p_is_available IS NOT NULL AND p_is_available IS DISTINCT FROM v_existing.is_available THEN
    v_changed_fields := array_append(v_changed_fields, 'is_available');
    v_old_values := v_old_values || jsonb_build_object('is_available', v_existing.is_available);
    v_new_values := v_new_values || jsonb_build_object('is_available', p_is_available);
  END IF;

  IF p_is_visible_public IS NOT NULL AND p_is_visible_public IS DISTINCT FROM v_existing.is_visible_public THEN
    v_changed_fields := array_append(v_changed_fields, 'is_visible_public');
    v_old_values := v_old_values || jsonb_build_object('is_visible_public', v_existing.is_visible_public);
    v_new_values := v_new_values || jsonb_build_object('is_visible_public', p_is_visible_public);
  END IF;

  IF p_sort_order IS NOT NULL AND p_sort_order IS DISTINCT FROM v_existing.sort_order THEN
    v_changed_fields := array_append(v_changed_fields, 'sort_order');
    v_old_values := v_old_values || jsonb_build_object('sort_order', v_existing.sort_order);
    v_new_values := v_new_values || jsonb_build_object('sort_order', p_sort_order);
  END IF;

  UPDATE public.menu_items
  SET category_id = COALESCE(p_category_id, v_existing.category_id),
      name = v_name,
      description = CASE
        WHEN p_description IS NULL THEN v_existing.description
        ELSE v_description
      END,
      price = COALESCE(p_price, v_existing.price),
      is_available = COALESCE(p_is_available, v_existing.is_available),
      is_visible_public = COALESCE(p_is_visible_public, v_existing.is_visible_public),
      sort_order = COALESCE(p_sort_order, v_existing.sort_order),
      updated_at = now()
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_menu_item',
      'menu_items',
      v_updated.id,
      jsonb_build_object(
        'store_id', v_updated.store_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── admin_delete_menu_item ──
CREATE OR REPLACE FUNCTION public.admin_delete_menu_item(
  p_item_id UUID
) RETURNS public.menu_items AS $$
DECLARE
  v_existing public.menu_items%ROWTYPE;
BEGIN
  IF p_item_id IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.menu_items
  WHERE id = p_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_store(v_existing.store_id);

  DELETE FROM public.menu_items
  WHERE id = v_existing.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_delete_menu_item',
    'menu_items',
    v_existing.id,
    jsonb_build_object(
      'store_id', v_existing.store_id,
      'deleted_at_utc', now(),
      'old_values', jsonb_build_object(
        'category_id', v_existing.category_id,
        'name', v_existing.name,
        'description', v_existing.description,
        'price', v_existing.price,
        'is_available', v_existing.is_available,
        'is_visible_public', v_existing.is_visible_public,
        'sort_order', v_existing.sort_order
      )
    )
  );

  RETURN v_existing;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── get_admin_mutation_audit_trace ──
CREATE OR REPLACE FUNCTION public.get_admin_mutation_audit_trace(
  p_store_id UUID,
  p_limit INT DEFAULT 10
) RETURNS TABLE (
  audit_log_id UUID,
  created_at TIMESTAMPTZ,
  action TEXT,
  entity_type TEXT,
  entity_id UUID,
  actor_id UUID,
  actor_name TEXT,
  changed_fields JSONB,
  old_values JSONB,
  new_values JSONB
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_limit INT := LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50);
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'AUDIT_TRACE_STORE_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'AUDIT_TRACE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'AUDIT_TRACE_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    al.id AS audit_log_id,
    al.created_at,
    al.action,
    al.entity_type,
    al.entity_id,
    al.actor_id,
    COALESCE(u.full_name, '알 수 없음') AS actor_name,
    COALESCE(al.details -> 'changed_fields', '[]'::jsonb) AS changed_fields,
    COALESCE(al.details -> 'old_values', '{}'::jsonb) AS old_values,
    COALESCE(al.details -> 'new_values', '{}'::jsonb) AS new_values
  FROM public.audit_logs al
  LEFT JOIN public.users u
    ON u.auth_id = al.actor_id
  WHERE al.entity_type = ANY (
      ARRAY[
        'stores', 'tables', 'menu_categories', 'menu_items',
        'orders', 'order_items', 'payments'
      ]
    )
    AND (
      NULLIF(al.details ->> 'store_id', '')::UUID = p_store_id
      OR NULLIF(al.details ->> 'restaurant_id', '')::UUID = p_store_id
      OR (
        al.entity_type = 'stores'
        AND al.entity_id = p_store_id
      )
    )
    AND al.action = ANY (
      ARRAY[
        -- admin mutations
        'admin_create_store',
        'admin_update_store',
        'admin_deactivate_store',
        'admin_update_store_settings',
        'admin_create_restaurant',
        'admin_update_restaurant',
        'admin_deactivate_restaurant',
        'admin_update_restaurant_settings',
        'admin_create_table',
        'admin_update_table',
        'admin_delete_table',
        'admin_create_menu_category',
        'admin_update_menu_category',
        'admin_delete_menu_category',
        'admin_create_menu_item',
        'admin_update_menu_item',
        'admin_delete_menu_item',
        -- order lifecycle
        'create_order',
        'create_buffet_order',
        'add_items_to_order',
        'cancel_order',
        'cancel_order_item',
        'edit_order_item_quantity',
        'transfer_order_table',
        'process_payment',
        'update_order_item_status'
      ]
    )
  ORDER BY al.created_at DESC
  LIMIT v_limit;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── get_admin_today_summary ──
CREATE OR REPLACE FUNCTION public.get_admin_today_summary(
  p_store_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_today_start TIMESTAMPTZ;
  v_result JSONB;
  v_orders_pending INT;
  v_orders_confirmed INT;
  v_orders_serving INT;
  v_orders_completed INT;
  v_orders_cancelled INT;
  v_items_cancelled INT;
  v_payments_count INT;
  v_payments_total NUMERIC;
  v_payments_cash NUMERIC;
  v_payments_card NUMERIC;
  v_tables_total INT;
  v_tables_occupied INT;
  v_low_stock_count INT;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'TODAY_SUMMARY_STORE_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'TODAY_SUMMARY_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'TODAY_SUMMARY_FORBIDDEN';
  END IF;

  v_today_start := (NOW() AT TIME ZONE 'Asia/Ho_Chi_Minh')::DATE::TIMESTAMPTZ;

  SELECT
    COALESCE(SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'confirmed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'serving' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END), 0)
  INTO v_orders_pending, v_orders_confirmed, v_orders_serving,
       v_orders_completed, v_orders_cancelled
  FROM public.orders
  WHERE store_id = p_store_id
    AND created_at >= v_today_start;

  SELECT COALESCE(COUNT(*), 0)
  INTO v_items_cancelled
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  WHERE o.store_id = p_store_id
    AND oi.status = 'cancelled'
    AND o.created_at >= v_today_start;

  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'cash' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) <> 'cash' THEN amount ELSE 0 END), 0)
  INTO v_payments_count, v_payments_total, v_payments_cash, v_payments_card
  FROM public.payments
  WHERE store_id = p_store_id
    AND is_revenue = TRUE
    AND created_at >= v_today_start;

  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(CASE WHEN status = 'occupied' THEN 1 ELSE 0 END), 0)
  INTO v_tables_total, v_tables_occupied
  FROM public.tables
  WHERE store_id = p_store_id;

  SELECT COALESCE(COUNT(*), 0)
  INTO v_low_stock_count
  FROM public.inventory_items
  WHERE store_id = p_store_id
    AND is_active = TRUE
    AND reorder_point IS NOT NULL
    AND current_stock <= reorder_point;

  v_result := jsonb_build_object(
    'orders_pending', v_orders_pending,
    'orders_confirmed', v_orders_confirmed,
    'orders_serving', v_orders_serving,
    'orders_completed', v_orders_completed,
    'orders_cancelled', v_orders_cancelled,
    'orders_total', v_orders_pending + v_orders_confirmed + v_orders_serving + v_orders_completed + v_orders_cancelled,
    'items_cancelled', v_items_cancelled,
    'payments_count', v_payments_count,
    'payments_total', v_payments_total,
    'payments_cash', v_payments_cash,
    'payments_card', v_payments_card,
    'tables_total', v_tables_total,
    'tables_occupied', v_tables_occupied,
    'low_stock_count', v_low_stock_count
  );

  RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── get_cashier_today_summary ──
CREATE OR REPLACE FUNCTION public.get_cashier_today_summary(
  p_store_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_today_start TIMESTAMPTZ;
  v_result JSONB;
  v_payments_count INT;
  v_payments_total NUMERIC;
  v_payments_cash NUMERIC;
  v_payments_card NUMERIC;
  v_payments_pay NUMERIC;
  v_service_count INT;
  v_service_total NUMERIC;
  v_orders_completed INT;
  v_orders_cancelled INT;
  v_orders_active INT;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'CASHIER_SUMMARY_STORE_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'CASHIER_SUMMARY_FORBIDDEN';
  END IF;

  IF v_actor.role NOT IN ('admin', 'super_admin')
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'CASHIER_SUMMARY_FORBIDDEN';
  END IF;

  v_today_start := (NOW() AT TIME ZONE 'Asia/Ho_Chi_Minh')::DATE::TIMESTAMPTZ;

  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'cash' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'card' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) NOT IN ('cash', 'card') THEN amount ELSE 0 END), 0)
  INTO v_payments_count, v_payments_total, v_payments_cash, v_payments_card, v_payments_pay
  FROM public.payments
  WHERE store_id = p_store_id
    AND is_revenue = TRUE
    AND created_at >= v_today_start;

  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0)
  INTO v_service_count, v_service_total
  FROM public.payments
  WHERE store_id = p_store_id
    AND is_revenue = FALSE
    AND created_at >= v_today_start;

  SELECT
    COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status NOT IN ('completed', 'cancelled') THEN 1 ELSE 0 END), 0)
  INTO v_orders_completed, v_orders_cancelled, v_orders_active
  FROM public.orders
  WHERE store_id = p_store_id
    AND created_at >= v_today_start;

  v_result := jsonb_build_object(
    'payments_count', v_payments_count,
    'payments_total', v_payments_total,
    'payments_cash', v_payments_cash,
    'payments_card', v_payments_card,
    'payments_pay', v_payments_pay,
    'service_count', v_service_count,
    'service_total', v_service_total,
    'orders_completed', v_orders_completed,
    'orders_cancelled', v_orders_cancelled,
    'orders_active', v_orders_active
  );

  RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── create_daily_closing ──
CREATE OR REPLACE FUNCTION public.create_daily_closing(
  p_store_id UUID,
  p_notes TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_closing_date DATE;
  v_existing_id UUID;
  v_orders_total INT;
  v_orders_completed INT;
  v_orders_cancelled INT;
  v_items_cancelled INT;
  v_payments_count INT;
  v_payments_total NUMERIC;
  v_payments_cash NUMERIC;
  v_payments_card NUMERIC;
  v_payments_pay NUMERIC;
  v_service_count INT;
  v_service_total NUMERIC;
  v_low_stock_count INT;
  v_day_start TIMESTAMPTZ;
  v_new_id UUID;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'DAILY_CLOSING_STORE_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'DAILY_CLOSING_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'DAILY_CLOSING_FORBIDDEN';
  END IF;

  v_closing_date := (NOW() AT TIME ZONE 'Asia/Ho_Chi_Minh')::DATE;
  v_day_start := v_closing_date::TIMESTAMPTZ;

  SELECT id INTO v_existing_id
  FROM daily_closings
  WHERE store_id = p_store_id
    AND closing_date = v_closing_date;

  IF FOUND THEN
    RAISE EXCEPTION 'DAILY_CLOSING_ALREADY_EXISTS';
  END IF;

  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END), 0)
  INTO v_orders_total, v_orders_completed, v_orders_cancelled
  FROM public.orders
  WHERE store_id = p_store_id
    AND created_at >= v_day_start;

  SELECT COALESCE(COUNT(*), 0)
  INTO v_items_cancelled
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  WHERE o.store_id = p_store_id
    AND oi.status = 'cancelled'
    AND o.created_at >= v_day_start;

  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'cash' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'card' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) NOT IN ('cash', 'card') THEN amount ELSE 0 END), 0)
  INTO v_payments_count, v_payments_total, v_payments_cash, v_payments_card, v_payments_pay
  FROM public.payments
  WHERE store_id = p_store_id
    AND is_revenue = TRUE
    AND created_at >= v_day_start;

  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0)
  INTO v_service_count, v_service_total
  FROM public.payments
  WHERE store_id = p_store_id
    AND is_revenue = FALSE
    AND created_at >= v_day_start;

  SELECT COALESCE(COUNT(*), 0)
  INTO v_low_stock_count
  FROM public.inventory_items
  WHERE store_id = p_store_id
    AND is_active = TRUE
    AND reorder_point IS NOT NULL
    AND current_stock <= reorder_point;

  INSERT INTO daily_closings (
    store_id, closing_date, closed_by,
    orders_total, orders_completed, orders_cancelled, items_cancelled,
    payments_count, payments_total, payments_cash, payments_card, payments_pay,
    service_count, service_total, low_stock_count, notes
  ) VALUES (
    p_store_id, v_closing_date, auth.uid(),
    v_orders_total, v_orders_completed, v_orders_cancelled, v_items_cancelled,
    v_payments_count, v_payments_total, v_payments_cash, v_payments_card, v_payments_pay,
    v_service_count, v_service_total, v_low_stock_count, p_notes
  ) RETURNING id INTO v_new_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'create_daily_closing',
    'daily_closings',
    v_new_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'closing_date', v_closing_date,
      'orders_total', v_orders_total,
      'payments_total', v_payments_total,
      'low_stock_count', v_low_stock_count
    )
  );

  RETURN jsonb_build_object(
    'id', v_new_id,
    'closing_date', v_closing_date,
    'orders_total', v_orders_total,
    'orders_completed', v_orders_completed,
    'orders_cancelled', v_orders_cancelled,
    'items_cancelled', v_items_cancelled,
    'payments_count', v_payments_count,
    'payments_total', v_payments_total,
    'payments_cash', v_payments_cash,
    'payments_card', v_payments_card,
    'payments_pay', v_payments_pay,
    'service_count', v_service_count,
    'service_total', v_service_total,
    'low_stock_count', v_low_stock_count
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── get_daily_closings ──
DROP FUNCTION IF EXISTS public.get_daily_closings(uuid, integer);

CREATE OR REPLACE FUNCTION public.get_daily_closings(
  p_store_id UUID,
  p_limit INT DEFAULT 30
) RETURNS TABLE (
  closing_id UUID,
  closing_date DATE,
  closed_by_name TEXT,
  orders_total INT,
  orders_completed INT,
  orders_cancelled INT,
  items_cancelled INT,
  payments_count INT,
  payments_total NUMERIC,
  payments_cash NUMERIC,
  payments_card NUMERIC,
  payments_pay NUMERIC,
  service_count INT,
  service_total NUMERIC,
  low_stock_count INT,
  notes TEXT,
  created_at TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_limit INT := LEAST(GREATEST(COALESCE(p_limit, 30), 1), 90);
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'DAILY_CLOSINGS_STORE_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'DAILY_CLOSINGS_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'DAILY_CLOSINGS_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    dc.id AS closing_id,
    dc.closing_date,
    COALESCE(u.full_name, '알 수 없음') AS closed_by_name,
    dc.orders_total,
    dc.orders_completed,
    dc.orders_cancelled,
    dc.items_cancelled,
    dc.payments_count,
    dc.payments_total,
    dc.payments_cash,
    dc.payments_card,
    dc.payments_pay,
    dc.service_count,
    dc.service_total,
    dc.low_stock_count,
    dc.notes,
    dc.created_at
  FROM daily_closings dc
  LEFT JOIN public.users u ON u.auth_id = dc.closed_by
  WHERE dc.store_id = p_store_id
  ORDER BY dc.closing_date DESC
  LIMIT v_limit;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── confirm_delivery_settlement_received ──
CREATE OR REPLACE FUNCTION confirm_delivery_settlement_received(
  p_settlement_id UUID,
  p_store_id UUID
) RETURNS delivery_settlements AS $$
DECLARE
  v_actor_id UUID := auth.uid();
  v_actor users%ROWTYPE;
  v_settlement delivery_settlements%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = v_actor_id
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'SETTLEMENT_CONFIRM_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_settlement
  FROM delivery_settlements
  WHERE id = p_settlement_id
    AND store_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SETTLEMENT_NOT_FOUND';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'SETTLEMENT_CONFIRM_FORBIDDEN';
  END IF;

  IF v_settlement.status <> 'calculated' THEN
    RAISE EXCEPTION 'INVALID_SETTLEMENT_STATUS';
  END IF;

  UPDATE delivery_settlements
  SET status = 'received',
      received_at = now(),
      updated_at = now()
  WHERE id = p_settlement_id
  RETURNING * INTO v_settlement;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    v_actor_id,
    'confirm_delivery_settlement_received',
    'delivery_settlements',
    p_settlement_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'from_status', 'calculated',
      'to_status', 'received'
    )
  );

  RETURN v_settlement;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── get_inventory_ingredient_catalog ──
CREATE OR REPLACE FUNCTION public.get_inventory_ingredient_catalog(
  p_store_id UUID
) RETURNS TABLE (
  id UUID,
  store_id UUID,
  name TEXT,
  unit TEXT,
  current_stock DECIMAL(12,3),
  reorder_point DECIMAL(12,3),
  cost_per_unit DECIMAL(12,2),
  supplier_name TEXT,
  needs_reorder BOOLEAN,
  last_updated TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_CATALOG_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'INVENTORY_CATALOG_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    ii.id,
    ii.store_id,
    ii.name,
    ii.unit,
    ii.current_stock,
    ii.reorder_point,
    ii.cost_per_unit,
    ii.supplier_name,
    CASE
      WHEN ii.reorder_point IS NOT NULL AND ii.current_stock <= ii.reorder_point
        THEN TRUE
      ELSE FALSE
    END AS needs_reorder,
    ii.updated_at AS last_updated
  FROM public.inventory_items ii
  WHERE ii.store_id = p_store_id
  ORDER BY lower(ii.name), ii.created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── create_inventory_item ──
CREATE OR REPLACE FUNCTION public.create_inventory_item(
  p_store_id UUID,
  p_name TEXT,
  p_unit TEXT,
  p_current_stock DECIMAL(12,3) DEFAULT NULL,
  p_reorder_point DECIMAL(12,3) DEFAULT NULL,
  p_cost_per_unit DECIMAL(12,2) DEFAULT NULL,
  p_supplier_name TEXT DEFAULT NULL
) RETURNS public.inventory_items AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_created public.inventory_items%ROWTYPE;
  v_name TEXT := btrim(COALESCE(p_name, ''));
  v_unit TEXT := btrim(COALESCE(p_unit, ''));
  v_current_stock DECIMAL(12,3) := COALESCE(p_current_stock, 0);
  v_reorder_point DECIMAL(12,3) := p_reorder_point;
  v_cost_per_unit DECIMAL(12,2) := p_cost_per_unit;
  v_supplier_name TEXT := NULLIF(btrim(COALESCE(p_supplier_name, '')), '');
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_WRITE_FORBIDDEN';
  END IF;

  IF v_name = '' THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_NAME_REQUIRED';
  END IF;

  IF v_unit NOT IN ('g', 'ml', 'ea') THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_UNIT_INVALID';
  END IF;

  IF v_current_stock < 0 THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_CURRENT_STOCK_INVALID';
  END IF;

  IF v_reorder_point IS NOT NULL AND v_reorder_point < 0 THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_REORDER_POINT_INVALID';
  END IF;

  IF v_cost_per_unit IS NOT NULL AND v_cost_per_unit < 0 THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_COST_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_items ii
    WHERE ii.store_id = p_store_id
      AND lower(btrim(ii.name)) = lower(v_name)
  ) THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_NAME_DUPLICATE';
  END IF;

  INSERT INTO public.inventory_items (
    store_id,
    name,
    unit,
    current_stock,
    reorder_point,
    cost_per_unit,
    supplier_name,
    updated_at
  )
  VALUES (
    p_store_id,
    v_name,
    v_unit,
    v_current_stock,
    v_reorder_point,
    v_cost_per_unit,
    v_supplier_name,
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_item_created',
    'inventory_items',
    v_created.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'new_values', jsonb_build_object(
        'name', v_created.name,
        'unit', v_created.unit,
        'current_stock', v_created.current_stock,
        'reorder_point', v_created.reorder_point,
        'cost_per_unit', v_created.cost_per_unit,
        'supplier_name', v_created.supplier_name
      )
    )
  );

  RETURN v_created;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── update_inventory_item ──
CREATE OR REPLACE FUNCTION public.update_inventory_item(
  p_item_id UUID,
  p_store_id UUID,
  p_patch JSONB
) RETURNS public.inventory_items AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_existing public.inventory_items%ROWTYPE;
  v_updated public.inventory_items%ROWTYPE;
  v_supported_keys CONSTANT TEXT[] := ARRAY[
    'name', 'unit', 'current_stock', 'reorder_point', 'cost_per_unit', 'supplier_name'
  ];
  v_key TEXT;
  v_name TEXT;
  v_unit TEXT;
  v_current_stock DECIMAL(12,3);
  v_reorder_point DECIMAL(12,3);
  v_cost_per_unit DECIMAL(12,2);
  v_supplier_name TEXT;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_WRITE_FORBIDDEN';
  END IF;

  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_PATCH_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM jsonb_object_keys(p_patch) AS k(key)
    WHERE k.key = ANY(v_supported_keys)
  ) THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_PATCH_EMPTY';
  END IF;

  FOR v_key IN
    SELECT key
    FROM jsonb_object_keys(p_patch) AS k(key)
  LOOP
    IF NOT (v_key = ANY(v_supported_keys)) THEN
      RAISE EXCEPTION 'INVENTORY_ITEM_PATCH_UNSUPPORTED';
    END IF;
  END LOOP;

  SELECT *
  INTO v_existing
  FROM public.inventory_items
  WHERE id = p_item_id
    AND store_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_NOT_FOUND';
  END IF;

  v_name := v_existing.name;
  v_unit := v_existing.unit;
  v_current_stock := v_existing.current_stock;
  v_reorder_point := v_existing.reorder_point;
  v_cost_per_unit := v_existing.cost_per_unit;
  v_supplier_name := v_existing.supplier_name;

  IF p_patch ? 'name' THEN
    v_name := btrim(COALESCE(p_patch->>'name', ''));
    IF v_name = '' THEN RAISE EXCEPTION 'INVENTORY_ITEM_NAME_REQUIRED'; END IF;
  END IF;

  IF p_patch ? 'unit' THEN
    v_unit := btrim(COALESCE(p_patch->>'unit', ''));
    IF v_unit NOT IN ('g', 'ml', 'ea') THEN RAISE EXCEPTION 'INVENTORY_ITEM_UNIT_INVALID'; END IF;
  END IF;

  IF p_patch ? 'current_stock' THEN
    IF jsonb_typeof(p_patch->'current_stock') = 'null' THEN RAISE EXCEPTION 'INVENTORY_ITEM_CURRENT_STOCK_REQUIRED'; END IF;
    v_current_stock := (p_patch->>'current_stock')::DECIMAL(12,3);
    IF v_current_stock < 0 THEN RAISE EXCEPTION 'INVENTORY_ITEM_CURRENT_STOCK_INVALID'; END IF;
  END IF;

  IF p_patch ? 'reorder_point' THEN
    IF jsonb_typeof(p_patch->'reorder_point') = 'null' THEN v_reorder_point := NULL;
    ELSE
      v_reorder_point := (p_patch->>'reorder_point')::DECIMAL(12,3);
      IF v_reorder_point < 0 THEN RAISE EXCEPTION 'INVENTORY_ITEM_REORDER_POINT_INVALID'; END IF;
    END IF;
  END IF;

  IF p_patch ? 'cost_per_unit' THEN
    IF jsonb_typeof(p_patch->'cost_per_unit') = 'null' THEN v_cost_per_unit := NULL;
    ELSE
      v_cost_per_unit := (p_patch->>'cost_per_unit')::DECIMAL(12,2);
      IF v_cost_per_unit < 0 THEN RAISE EXCEPTION 'INVENTORY_ITEM_COST_INVALID'; END IF;
    END IF;
  END IF;

  IF p_patch ? 'supplier_name' THEN
    IF jsonb_typeof(p_patch->'supplier_name') = 'null' THEN v_supplier_name := NULL;
    ELSE v_supplier_name := NULLIF(btrim(p_patch->>'supplier_name'), '');
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_items ii
    WHERE ii.store_id = p_store_id
      AND ii.id <> p_item_id
      AND lower(btrim(ii.name)) = lower(v_name)
  ) THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_NAME_DUPLICATE';
  END IF;

  IF v_existing.name IS DISTINCT FROM v_name THEN
    v_changed_fields := array_append(v_changed_fields, 'name');
    v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
    v_new_values := v_new_values || jsonb_build_object('name', v_name);
  END IF;
  IF v_existing.unit IS DISTINCT FROM v_unit THEN
    v_changed_fields := array_append(v_changed_fields, 'unit');
    v_old_values := v_old_values || jsonb_build_object('unit', v_existing.unit);
    v_new_values := v_new_values || jsonb_build_object('unit', v_unit);
  END IF;
  IF v_existing.current_stock IS DISTINCT FROM v_current_stock THEN
    v_changed_fields := array_append(v_changed_fields, 'current_stock');
    v_old_values := v_old_values || jsonb_build_object('current_stock', v_existing.current_stock);
    v_new_values := v_new_values || jsonb_build_object('current_stock', v_current_stock);
  END IF;
  IF v_existing.reorder_point IS DISTINCT FROM v_reorder_point THEN
    v_changed_fields := array_append(v_changed_fields, 'reorder_point');
    v_old_values := v_old_values || jsonb_build_object('reorder_point', v_existing.reorder_point);
    v_new_values := v_new_values || jsonb_build_object('reorder_point', v_reorder_point);
  END IF;
  IF v_existing.cost_per_unit IS DISTINCT FROM v_cost_per_unit THEN
    v_changed_fields := array_append(v_changed_fields, 'cost_per_unit');
    v_old_values := v_old_values || jsonb_build_object('cost_per_unit', v_existing.cost_per_unit);
    v_new_values := v_new_values || jsonb_build_object('cost_per_unit', v_cost_per_unit);
  END IF;
  IF v_existing.supplier_name IS DISTINCT FROM v_supplier_name THEN
    v_changed_fields := array_append(v_changed_fields, 'supplier_name');
    v_old_values := v_old_values || jsonb_build_object('supplier_name', v_existing.supplier_name);
    v_new_values := v_new_values || jsonb_build_object('supplier_name', v_supplier_name);
  END IF;

  IF coalesce(array_length(v_changed_fields, 1), 0) = 0 THEN
    RETURN v_existing;
  END IF;

  UPDATE public.inventory_items
  SET name = v_name,
      unit = v_unit,
      current_stock = v_current_stock,
      reorder_point = v_reorder_point,
      cost_per_unit = v_cost_per_unit,
      supplier_name = v_supplier_name,
      updated_at = now()
  WHERE id = p_item_id
    AND store_id = p_store_id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_item_updated',
    'inventory_items',
    v_updated.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'changed_fields', to_jsonb(v_changed_fields),
      'old_values', v_old_values,
      'new_values', v_new_values
    )
  );

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── restock_inventory_item ──
CREATE OR REPLACE FUNCTION public.restock_inventory_item(
  p_store_id UUID,
  p_ingredient_id UUID,
  p_quantity_g    DECIMAL(10,3),
  p_note          TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor       public.users%ROWTYPE;
  v_ingredient  public.inventory_items%ROWTYPE;
  v_new_stock   DECIMAL(10,3);
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_RESTOCK_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'INVENTORY_RESTOCK_FORBIDDEN';
  END IF;

  IF p_quantity_g IS NULL OR p_quantity_g <= 0 THEN
    RAISE EXCEPTION 'INVENTORY_RESTOCK_QUANTITY_INVALID';
  END IF;

  SELECT *
  INTO v_ingredient
  FROM public.inventory_items
  WHERE id = p_ingredient_id
    AND store_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RESTOCK_INGREDIENT_NOT_FOUND';
  END IF;

  v_new_stock := COALESCE(v_ingredient.current_stock, 0) + p_quantity_g;

  UPDATE public.inventory_items
  SET current_stock = v_new_stock,
      updated_at    = now()
  WHERE id = p_ingredient_id
    AND store_id = p_store_id;

  INSERT INTO public.inventory_transactions (
    store_id, ingredient_id, transaction_type,
    quantity_g, reference_type, note, created_by
  ) VALUES (
    p_store_id, p_ingredient_id, 'restock',
    p_quantity_g, 'manual', p_note, v_actor.id
  );

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_restocked',
    'inventory_items',
    p_ingredient_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'ingredient_name', v_ingredient.name,
      'quantity_g', p_quantity_g,
      'old_stock', COALESCE(v_ingredient.current_stock, 0),
      'new_stock', v_new_stock,
      'note', p_note
    )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── record_inventory_waste ──
CREATE OR REPLACE FUNCTION public.record_inventory_waste(
  p_store_id UUID,
  p_ingredient_id UUID,
  p_quantity_g    DECIMAL(10,3),
  p_note          TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor       public.users%ROWTYPE;
  v_ingredient  public.inventory_items%ROWTYPE;
  v_new_stock   DECIMAL(10,3);
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_WASTE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'INVENTORY_WASTE_FORBIDDEN';
  END IF;

  IF p_quantity_g IS NULL OR p_quantity_g <= 0 THEN
    RAISE EXCEPTION 'INVENTORY_WASTE_QUANTITY_INVALID';
  END IF;

  SELECT *
  INTO v_ingredient
  FROM public.inventory_items
  WHERE id = p_ingredient_id
    AND store_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_WASTE_INGREDIENT_NOT_FOUND';
  END IF;

  v_new_stock := COALESCE(v_ingredient.current_stock, 0) - p_quantity_g;

  UPDATE public.inventory_items
  SET current_stock = v_new_stock,
      updated_at    = now()
  WHERE id = p_ingredient_id
    AND store_id = p_store_id;

  INSERT INTO public.inventory_transactions (
    store_id, ingredient_id, transaction_type,
    quantity_g, reference_type, note, created_by
  ) VALUES (
    p_store_id, p_ingredient_id, 'waste',
    -p_quantity_g, 'manual', p_note, v_actor.id
  );

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_waste_recorded',
    'inventory_items',
    p_ingredient_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'ingredient_name', v_ingredient.name,
      'quantity_g', p_quantity_g,
      'old_stock', COALESCE(v_ingredient.current_stock, 0),
      'new_stock', v_new_stock,
      'note', p_note,
      'went_negative', v_new_stock < 0
    )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── get_inventory_recipe_catalog ──
CREATE OR REPLACE FUNCTION public.get_inventory_recipe_catalog(
  p_store_id UUID,
  p_menu_item_id UUID DEFAULT NULL
) RETURNS TABLE (
  recipe_id UUID,
  store_id UUID,
  menu_item_id UUID,
  menu_item_name TEXT,
  ingredient_id UUID,
  ingredient_name TEXT,
  ingredient_unit TEXT,
  quantity_g DECIMAL(10,3),
  last_updated TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_FORBIDDEN';
  END IF;

  IF p_menu_item_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.menu_items mi
    WHERE mi.id = p_menu_item_id
      AND mi.store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_MENU_ITEM_NOT_FOUND';
  END IF;

  RETURN QUERY
  SELECT
    mr.id AS recipe_id,
    mr.store_id,
    mr.menu_item_id,
    mi.name AS menu_item_name,
    mr.ingredient_id,
    ii.name AS ingredient_name,
    ii.unit AS ingredient_unit,
    mr.quantity_g,
    mr.updated_at AS last_updated
  FROM public.menu_recipes mr
  JOIN public.menu_items mi
    ON mi.id = mr.menu_item_id
   AND mi.store_id = mr.store_id
  JOIN public.inventory_items ii
    ON ii.id = mr.ingredient_id
   AND ii.store_id = mr.store_id
  WHERE mr.store_id = p_store_id
    AND (p_menu_item_id IS NULL OR mr.menu_item_id = p_menu_item_id)
  ORDER BY lower(mi.name), lower(ii.name), mr.created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── upsert_inventory_recipe_line ──
CREATE OR REPLACE FUNCTION public.upsert_inventory_recipe_line(
  p_store_id UUID,
  p_menu_item_id UUID,
  p_ingredient_id UUID,
  p_quantity_g DECIMAL(10,3)
) RETURNS TABLE (
  recipe_id UUID,
  store_id UUID,
  menu_item_id UUID,
  menu_item_name TEXT,
  ingredient_id UUID,
  ingredient_name TEXT,
  ingredient_unit TEXT,
  quantity_g DECIMAL(10,3),
  last_updated TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_menu_item public.menu_items%ROWTYPE;
  v_ingredient public.inventory_items%ROWTYPE;
  v_existing public.menu_recipes%ROWTYPE;
  v_recipe public.menu_recipes%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_WRITE_FORBIDDEN';
  END IF;

  IF p_menu_item_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_MENU_ITEM_REQUIRED';
  END IF;

  IF p_ingredient_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_REQUIRED';
  END IF;

  IF p_quantity_g IS NULL OR p_quantity_g <= 0 THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_QUANTITY_INVALID';
  END IF;

  SELECT mi.*
  INTO v_menu_item
  FROM public.menu_items mi
  WHERE mi.id = p_menu_item_id
    AND mi.store_id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_MENU_ITEM_NOT_FOUND';
  END IF;

  SELECT ii.*
  INTO v_ingredient
  FROM public.inventory_items ii
  WHERE ii.id = p_ingredient_id
    AND ii.store_id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_NOT_FOUND';
  END IF;

  IF v_ingredient.unit <> 'g' THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_UNIT_UNSUPPORTED';
  END IF;

  SELECT mr.*
  INTO v_existing
  FROM public.menu_recipes mr
  WHERE mr.store_id = p_store_id
    AND mr.menu_item_id = p_menu_item_id
    AND mr.ingredient_id = p_ingredient_id
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing.quantity_g IS DISTINCT FROM p_quantity_g THEN
      v_changed_fields := ARRAY['quantity_g'];
      v_old_values := jsonb_build_object('quantity_g', v_existing.quantity_g);
      v_new_values := jsonb_build_object('quantity_g', p_quantity_g);

      UPDATE public.menu_recipes mr
      SET quantity_g = p_quantity_g,
          updated_at = now()
      WHERE mr.id = v_existing.id
      RETURNING mr.* INTO v_recipe;

      INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
      VALUES (
        auth.uid(),
        'inventory_recipe_upserted',
        'menu_recipes',
        v_recipe.id,
        jsonb_build_object(
          'operation', 'update',
          'store_id', p_store_id,
          'menu_item_id', p_menu_item_id,
          'ingredient_id', p_ingredient_id,
          'changed_fields', to_jsonb(v_changed_fields),
          'old_values', v_old_values,
          'new_values', v_new_values
        )
      );
    ELSE
      v_recipe := v_existing;
    END IF;
  ELSE
    INSERT INTO public.menu_recipes (
      store_id,
      menu_item_id,
      ingredient_id,
      quantity_g,
      updated_at
    )
    VALUES (
      p_store_id,
      p_menu_item_id,
      p_ingredient_id,
      p_quantity_g,
      now()
    )
    RETURNING * INTO v_recipe;

    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'inventory_recipe_upserted',
      'menu_recipes',
      v_recipe.id,
      jsonb_build_object(
        'operation', 'create',
        'store_id', p_store_id,
        'menu_item_id', p_menu_item_id,
        'ingredient_id', p_ingredient_id,
        'new_values', jsonb_build_object(
          'quantity_g', v_recipe.quantity_g
        )
      )
    );
  END IF;

  RETURN QUERY
  SELECT
    v_recipe.id AS recipe_id,
    v_recipe.store_id,
    v_recipe.menu_item_id,
    v_menu_item.name AS menu_item_name,
    v_recipe.ingredient_id,
    v_ingredient.name AS ingredient_name,
    v_ingredient.unit AS ingredient_unit,
    v_recipe.quantity_g,
    v_recipe.updated_at AS last_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── get_inventory_physical_count_sheet ──
CREATE OR REPLACE FUNCTION public.get_inventory_physical_count_sheet(
  p_store_id UUID,
  p_count_date DATE
) RETURNS TABLE (
  ingredient_id UUID,
  ingredient_name TEXT,
  ingredient_unit TEXT,
  theoretical_quantity_g DECIMAL(12,3),
  actual_quantity_g DECIMAL(12,3),
  variance_quantity_g DECIMAL(12,3),
  count_date DATE,
  last_updated TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_FORBIDDEN';
  END IF;

  IF p_count_date IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_DATE_REQUIRED';
  END IF;

  RETURN QUERY
  SELECT
    ii.id AS ingredient_id,
    ii.name AS ingredient_name,
    ii.unit AS ingredient_unit,
    ii.current_stock AS theoretical_quantity_g,
    ipc.actual_quantity_g,
    ipc.variance_g AS variance_quantity_g,
    p_count_date AS count_date,
    COALESCE(ipc.updated_at, ipc.created_at, ii.updated_at) AS last_updated
  FROM public.inventory_items ii
  LEFT JOIN public.inventory_physical_counts ipc
    ON ipc.store_id = p_store_id
   AND ipc.ingredient_id = ii.id
   AND ipc.count_date = p_count_date
  WHERE ii.store_id = p_store_id
  ORDER BY lower(ii.name), ii.created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── apply_inventory_physical_count_line ──
CREATE OR REPLACE FUNCTION public.apply_inventory_physical_count_line(
  p_store_id UUID,
  p_count_date DATE,
  p_ingredient_id UUID,
  p_actual_quantity_g DECIMAL(12,3),
  p_note TEXT DEFAULT NULL
) RETURNS TABLE (
  ingredient_id UUID,
  count_date DATE,
  theoretical_quantity_g DECIMAL(12,3),
  actual_quantity_g DECIMAL(12,3),
  variance_quantity_g DECIMAL(12,3),
  inventory_transaction_id UUID,
  last_updated TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_ingredient public.inventory_items%ROWTYPE;
  v_existing_count public.inventory_physical_counts%ROWTYPE;
  v_count_row public.inventory_physical_counts%ROWTYPE;
  v_transaction public.inventory_transactions%ROWTYPE;
  v_old_stock DECIMAL(12,3);
  v_variance DECIMAL(12,3);
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_WRITE_FORBIDDEN';
  END IF;

  IF p_count_date IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_DATE_REQUIRED';
  END IF;

  IF p_ingredient_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_INGREDIENT_REQUIRED';
  END IF;

  IF p_actual_quantity_g IS NULL OR p_actual_quantity_g < 0 THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_ACTUAL_INVALID';
  END IF;

  SELECT ii.*
  INTO v_ingredient
  FROM public.inventory_items ii
  WHERE ii.id = p_ingredient_id
    AND ii.store_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_INGREDIENT_NOT_FOUND';
  END IF;

  v_old_stock := v_ingredient.current_stock;
  v_variance := p_actual_quantity_g - v_old_stock;

  SELECT ipc.*
  INTO v_existing_count
  FROM public.inventory_physical_counts ipc
  WHERE ipc.store_id = p_store_id
    AND ipc.ingredient_id = p_ingredient_id
    AND ipc.count_date = p_count_date
  FOR UPDATE;

  INSERT INTO public.inventory_physical_counts (
    store_id,
    ingredient_id,
    count_date,
    actual_quantity_g,
    theoretical_quantity_g,
    variance_g,
    counted_by,
    updated_at
  )
  VALUES (
    p_store_id,
    p_ingredient_id,
    p_count_date,
    p_actual_quantity_g,
    v_old_stock,
    v_variance,
    auth.uid(),
    now()
  )
  ON CONFLICT ON CONSTRAINT inventory_physical_counts_ingredient_id_count_date_key
  DO UPDATE SET
    actual_quantity_g = EXCLUDED.actual_quantity_g,
    theoretical_quantity_g = EXCLUDED.theoretical_quantity_g,
    variance_g = EXCLUDED.variance_g,
    counted_by = EXCLUDED.counted_by,
    updated_at = now()
  RETURNING * INTO v_count_row;

  UPDATE public.inventory_items ii
  SET current_stock = p_actual_quantity_g,
      updated_at = now()
  WHERE ii.id = p_ingredient_id
    AND ii.store_id = p_store_id;

  INSERT INTO public.inventory_transactions (
    store_id,
    ingredient_id,
    transaction_type,
    quantity_g,
    reference_type,
    reference_id,
    note,
    created_by
  )
  VALUES (
    p_store_id,
    p_ingredient_id,
    'adjust',
    v_variance,
    'physical_count',
    v_count_row.id,
    COALESCE(
      v_note,
      format('실재고 실사 (%s)', to_char(p_count_date, 'YYYY-MM-DD'))
    ),
    auth.uid()
  )
  RETURNING * INTO v_transaction;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_physical_count_applied',
    'inventory_physical_counts',
    v_count_row.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'ingredient_id', p_ingredient_id,
      'count_date', p_count_date,
      'old_stock', v_old_stock,
      'new_stock', p_actual_quantity_g,
      'variance_quantity_g', v_variance,
      'note', v_note,
      'previous_count', CASE
        WHEN v_existing_count.id IS NULL THEN NULL
        ELSE jsonb_build_object(
          'actual_quantity_g', v_existing_count.actual_quantity_g,
          'theoretical_quantity_g', v_existing_count.theoretical_quantity_g,
          'variance_g', v_existing_count.variance_g
        )
      END
    )
  );

  RETURN QUERY
  SELECT
    p_ingredient_id AS ingredient_id,
    p_count_date AS count_date,
    v_old_stock AS theoretical_quantity_g,
    p_actual_quantity_g AS actual_quantity_g,
    v_variance AS variance_quantity_g,
    v_transaction.id AS inventory_transaction_id,
    v_count_row.updated_at AS last_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── get_inventory_transaction_visibility ──
CREATE OR REPLACE FUNCTION public.get_inventory_transaction_visibility(
  p_store_id UUID,
  p_from TIMESTAMPTZ,
  p_to TIMESTAMPTZ
) RETURNS TABLE (
  id UUID,
  store_id UUID,
  ingredient_id UUID,
  ingredient_name TEXT,
  ingredient_unit TEXT,
  transaction_type TEXT,
  quantity_g DECIMAL(12,3),
  reference_type TEXT,
  reference_id UUID,
  note TEXT,
  created_at TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_RANGE_REQUIRED';
  END IF;

  IF p_from > p_to THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_RANGE_INVALID';
  END IF;

  RETURN QUERY
  SELECT
    it.id,
    it.store_id,
    it.ingredient_id,
    ii.name AS ingredient_name,
    ii.unit AS ingredient_unit,
    it.transaction_type,
    it.quantity_g,
    it.reference_type,
    it.reference_id,
    it.note,
    it.created_at
  FROM public.inventory_transactions it
  JOIN public.inventory_items ii
    ON ii.id = it.ingredient_id
   AND ii.store_id = it.store_id
  WHERE it.store_id = p_store_id
    AND it.created_at >= p_from
    AND it.created_at <= p_to
  ORDER BY it.created_at DESC, ii.name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── get_attendance_staff_directory ──
CREATE OR REPLACE FUNCTION public.get_attendance_staff_directory(
  p_store_id UUID
) RETURNS TABLE (
  user_id UUID,
  full_name TEXT,
  role TEXT
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ATTENDANCE_STAFF_DIRECTORY_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'ATTENDANCE_STAFF_DIRECTORY_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    u.id AS user_id,
    u.full_name,
    u.role
  FROM public.users u
  WHERE u.store_id = p_store_id
    AND u.is_active = TRUE
    AND u.role IN ('admin', 'waiter', 'kitchen', 'cashier')
  ORDER BY lower(u.full_name), u.created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── get_attendance_log_view ──
CREATE OR REPLACE FUNCTION public.get_attendance_log_view(
  p_store_id UUID,
  p_from TIMESTAMPTZ,
  p_to TIMESTAMPTZ,
  p_user_id UUID DEFAULT NULL
) RETURNS TABLE (
  attendance_log_id UUID,
  store_id UUID,
  user_id UUID,
  user_full_name TEXT,
  user_role TEXT,
  attendance_type TEXT,
  photo_url TEXT,
  photo_thumbnail_url TEXT,
  logged_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_VIEW_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_VIEW_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_RANGE_REQUIRED';
  END IF;

  IF p_from > p_to THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_RANGE_INVALID';
  END IF;

  IF p_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = p_user_id
      AND u.store_id = p_store_id
      AND u.is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_USER_NOT_FOUND';
  END IF;

  RETURN QUERY
  SELECT
    al.id AS attendance_log_id,
    al.store_id,
    al.user_id,
    u.full_name AS user_full_name,
    u.role AS user_role,
    al.type AS attendance_type,
    al.photo_url,
    al.photo_thumbnail_url,
    al.logged_at,
    al.created_at
  FROM public.attendance_logs al
  JOIN public.users u
    ON u.id = al.user_id
   AND u.store_id = al.store_id
  WHERE al.store_id = p_store_id
    AND al.logged_at >= p_from
    AND al.logged_at <= p_to
    AND (p_user_id IS NULL OR al.user_id = p_user_id)
  ORDER BY al.logged_at DESC, al.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── record_attendance_event ──
CREATE OR REPLACE FUNCTION public.record_attendance_event(
  p_store_id UUID,
  p_user_id UUID,
  p_type TEXT,
  p_photo_url TEXT DEFAULT NULL,
  p_photo_thumbnail_url TEXT DEFAULT NULL
) RETURNS TABLE (
  attendance_log_id UUID,
  store_id UUID,
  user_id UUID,
  attendance_type TEXT,
  photo_url TEXT,
  photo_thumbnail_url TEXT,
  logged_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_target_user public.users%ROWTYPE;
  v_log public.attendance_logs%ROWTYPE;
  v_photo_url TEXT := NULLIF(btrim(COALESCE(p_photo_url, '')), '');
  v_photo_thumbnail_url TEXT := NULLIF(btrim(COALESCE(p_photo_thumbnail_url, '')), '');
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.store_id <> p_store_id THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_FORBIDDEN';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_USER_REQUIRED';
  END IF;

  IF p_type IS NULL OR p_type NOT IN ('clock_in', 'clock_out') THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_TYPE_INVALID';
  END IF;

  SELECT u.*
  INTO v_target_user
  FROM public.users u
  WHERE u.id = p_user_id
    AND u.store_id = p_store_id
    AND u.is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_USER_NOT_FOUND';
  END IF;

  INSERT INTO public.attendance_logs (
    store_id,
    user_id,
    type,
    photo_url,
    photo_thumbnail_url,
    logged_at
  )
  VALUES (
    p_store_id,
    p_user_id,
    p_type,
    v_photo_url,
    COALESCE(v_photo_thumbnail_url, v_photo_url),
    now()
  )
  RETURNING * INTO v_log;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'attendance_event_recorded',
    'attendance_logs',
    v_log.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'user_id', p_user_id,
      'attendance_type', p_type,
      'logged_at', v_log.logged_at,
      'photo_url', v_log.photo_url,
      'photo_thumbnail_url', v_log.photo_thumbnail_url
    )
  );

  RETURN QUERY
  SELECT
    v_log.id AS attendance_log_id,
    v_log.store_id,
    v_log.user_id,
    v_log.type AS attendance_type,
    v_log.photo_url,
    v_log.photo_thumbnail_url,
    v_log.logged_at,
    v_log.created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── QC functions ──

-- get_qc_templates
CREATE OR REPLACE FUNCTION public.get_qc_templates(
  p_store_id UUID DEFAULT NULL,
  p_scope TEXT DEFAULT 'visible'
) RETURNS TABLE (
  id UUID,
  store_id UUID,
  category TEXT,
  criteria_text TEXT,
  criteria_photo_url TEXT,
  sort_order INT,
  is_global BOOLEAN,
  is_active BOOLEAN,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_TEMPLATE_READ_FORBIDDEN';
  END IF;

  IF p_scope NOT IN ('visible', 'global') THEN
    RAISE EXCEPTION 'QC_TEMPLATE_SCOPE_INVALID';
  END IF;

  IF p_scope = 'global' THEN
    IF v_actor.role <> 'super_admin' THEN
      RAISE EXCEPTION 'QC_TEMPLATE_READ_FORBIDDEN';
    END IF;
  ELSE
    IF p_store_id IS NULL THEN
      RAISE EXCEPTION 'QC_TEMPLATE_STORE_REQUIRED';
    END IF;

    IF v_actor.role <> 'super_admin'
       AND v_actor.store_id <> p_store_id THEN
      RAISE EXCEPTION 'QC_TEMPLATE_READ_FORBIDDEN';
    END IF;
  END IF;

  RETURN QUERY
  SELECT
    qt.id,
    qt.store_id,
    qt.category,
    qt.criteria_text,
    qt.criteria_photo_url,
    qt.sort_order,
    qt.is_global,
    qt.is_active,
    qt.created_at,
    qt.updated_at
  FROM public.qc_templates qt
  WHERE qt.is_active = TRUE
    AND (
      (p_scope = 'global' AND qt.is_global = TRUE)
      OR
      (
        p_scope = 'visible'
        AND (
          qt.is_global = TRUE
          OR qt.store_id = p_store_id
        )
      )
    )
  ORDER BY qt.is_global DESC, lower(qt.category), qt.sort_order, qt.created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- create_qc_template
CREATE OR REPLACE FUNCTION public.create_qc_template(
  p_category TEXT,
  p_criteria_text TEXT,
  p_store_id UUID DEFAULT NULL,
  p_criteria_photo_url TEXT DEFAULT NULL,
  p_sort_order INT DEFAULT 0,
  p_is_global BOOLEAN DEFAULT FALSE
) RETURNS public.qc_templates AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_created public.qc_templates%ROWTYPE;
  v_category TEXT := NULLIF(btrim(COALESCE(p_category, '')), '');
  v_criteria TEXT := NULLIF(btrim(COALESCE(p_criteria_text, '')), '');
  v_photo TEXT := NULLIF(btrim(COALESCE(p_criteria_photo_url, '')), '');
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  IF v_category IS NULL THEN RAISE EXCEPTION 'QC_TEMPLATE_CATEGORY_REQUIRED'; END IF;
  IF v_criteria IS NULL THEN RAISE EXCEPTION 'QC_TEMPLATE_TEXT_REQUIRED'; END IF;
  IF p_sort_order IS NULL OR p_sort_order < 0 THEN RAISE EXCEPTION 'QC_TEMPLATE_SORT_INVALID'; END IF;

  IF p_is_global THEN
    IF v_actor.role <> 'super_admin' THEN RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN'; END IF;
  ELSE
    IF p_store_id IS NULL THEN RAISE EXCEPTION 'QC_TEMPLATE_STORE_REQUIRED'; END IF;
    IF v_actor.role <> 'super_admin' AND v_actor.store_id <> p_store_id THEN
      RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
    END IF;
  END IF;

  INSERT INTO public.qc_templates (
    store_id, category, criteria_text, criteria_photo_url,
    sort_order, is_global, updated_at
  )
  VALUES (
    CASE WHEN p_is_global THEN NULL ELSE p_store_id END,
    v_category, v_criteria, v_photo, p_sort_order, p_is_global, now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_template_created',
    'qc_templates',
    v_created.id,
    jsonb_build_object(
      'store_id', v_created.store_id,
      'is_global', v_created.is_global,
      'category', v_created.category,
      'criteria_text', v_created.criteria_text,
      'criteria_photo_url', v_created.criteria_photo_url,
      'sort_order', v_created.sort_order
    )
  );

  RETURN v_created;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- update_qc_template
CREATE OR REPLACE FUNCTION public.update_qc_template(
  p_template_id UUID,
  p_patch JSONB
) RETURNS public.qc_templates AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_existing public.qc_templates%ROWTYPE;
  v_updated public.qc_templates%ROWTYPE;
  v_patch JSONB := COALESCE(p_patch, '{}'::JSONB);
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_key TEXT;
  v_value JSONB;
  v_category TEXT;
  v_text TEXT;
  v_photo TEXT;
  v_sort_order INT;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  IF jsonb_typeof(v_patch) <> 'object' THEN RAISE EXCEPTION 'QC_TEMPLATE_PATCH_INVALID'; END IF;
  IF v_patch = '{}'::JSONB THEN RAISE EXCEPTION 'QC_TEMPLATE_PATCH_EMPTY'; END IF;

  SELECT qt.*
  INTO v_existing
  FROM public.qc_templates qt
  WHERE qt.id = p_template_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'QC_TEMPLATE_NOT_FOUND'; END IF;

  IF v_existing.is_global AND v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  IF NOT v_existing.is_global
     AND v_actor.role <> 'super_admin'
     AND v_existing.store_id <> v_actor.store_id THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  FOR v_key, v_value IN
    SELECT key, value FROM jsonb_each(v_patch)
  LOOP
    IF v_key NOT IN ('category', 'criteria_text', 'criteria_photo_url', 'sort_order') THEN
      RAISE EXCEPTION 'QC_TEMPLATE_PATCH_UNSUPPORTED';
    END IF;
  END LOOP;

  v_category := v_existing.category;
  v_text := v_existing.criteria_text;
  v_photo := v_existing.criteria_photo_url;
  v_sort_order := v_existing.sort_order;

  IF v_patch ? 'category' THEN
    v_category := NULLIF(btrim(v_patch->>'category'), '');
    IF v_category IS NULL THEN RAISE EXCEPTION 'QC_TEMPLATE_CATEGORY_REQUIRED'; END IF;
    IF v_category IS DISTINCT FROM v_existing.category THEN
      v_changed_fields := array_append(v_changed_fields, 'category');
      v_old_values := v_old_values || jsonb_build_object('category', v_existing.category);
      v_new_values := v_new_values || jsonb_build_object('category', v_category);
    END IF;
  END IF;

  IF v_patch ? 'criteria_text' THEN
    v_text := NULLIF(btrim(v_patch->>'criteria_text'), '');
    IF v_text IS NULL THEN RAISE EXCEPTION 'QC_TEMPLATE_TEXT_REQUIRED'; END IF;
    IF v_text IS DISTINCT FROM v_existing.criteria_text THEN
      v_changed_fields := array_append(v_changed_fields, 'criteria_text');
      v_old_values := v_old_values || jsonb_build_object('criteria_text', v_existing.criteria_text);
      v_new_values := v_new_values || jsonb_build_object('criteria_text', v_text);
    END IF;
  END IF;

  IF v_patch ? 'criteria_photo_url' THEN
    v_photo := NULLIF(btrim(COALESCE(v_patch->>'criteria_photo_url', '')), '');
    IF v_photo IS DISTINCT FROM v_existing.criteria_photo_url THEN
      v_changed_fields := array_append(v_changed_fields, 'criteria_photo_url');
      v_old_values := v_old_values || jsonb_build_object('criteria_photo_url', v_existing.criteria_photo_url);
      v_new_values := v_new_values || jsonb_build_object('criteria_photo_url', v_photo);
    END IF;
  END IF;

  IF v_patch ? 'sort_order' THEN
    BEGIN v_sort_order := (v_patch->>'sort_order')::INT;
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'QC_TEMPLATE_SORT_INVALID'; END;
    IF v_sort_order < 0 THEN RAISE EXCEPTION 'QC_TEMPLATE_SORT_INVALID'; END IF;
    IF v_sort_order IS DISTINCT FROM v_existing.sort_order THEN
      v_changed_fields := array_append(v_changed_fields, 'sort_order');
      v_old_values := v_old_values || jsonb_build_object('sort_order', v_existing.sort_order);
      v_new_values := v_new_values || jsonb_build_object('sort_order', v_sort_order);
    END IF;
  END IF;

  UPDATE public.qc_templates
  SET category = v_category, criteria_text = v_text,
      criteria_photo_url = v_photo, sort_order = v_sort_order, updated_at = now()
  WHERE id = p_template_id
  RETURNING * INTO v_updated;

  IF array_length(v_changed_fields, 1) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(), 'qc_template_updated', 'qc_templates', v_updated.id,
      jsonb_build_object(
        'store_id', v_updated.store_id, 'is_global', v_updated.is_global,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values, 'new_values', v_new_values
      )
    );
  END IF;

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- deactivate_qc_template
CREATE OR REPLACE FUNCTION public.deactivate_qc_template(
  p_template_id UUID
) RETURNS public.qc_templates AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_existing public.qc_templates%ROWTYPE;
  v_updated public.qc_templates%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  SELECT qt.*
  INTO v_existing
  FROM public.qc_templates qt
  WHERE qt.id = p_template_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'QC_TEMPLATE_NOT_FOUND'; END IF;

  IF v_existing.is_global AND v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  IF NOT v_existing.is_global
     AND v_actor.role <> 'super_admin'
     AND v_existing.store_id <> v_actor.store_id THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  UPDATE public.qc_templates
  SET is_active = FALSE, updated_at = now()
  WHERE id = p_template_id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'qc_template_deactivated', 'qc_templates', v_updated.id,
    jsonb_build_object('store_id', v_updated.store_id, 'is_global', v_updated.is_global)
  );

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- get_qc_checks
CREATE OR REPLACE FUNCTION public.get_qc_checks(
  p_store_id UUID,
  p_from DATE,
  p_to DATE
) RETURNS TABLE (
  check_id UUID, store_id UUID, template_id UUID, check_date DATE,
  checked_by UUID, result TEXT, evidence_photo_url TEXT, note TEXT,
  created_at TIMESTAMPTZ, template_category TEXT, template_criteria_text TEXT,
  template_criteria_photo_url TEXT, template_is_global BOOLEAN
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_can_check BOOLEAN;
BEGIN
  SELECT u.* INTO v_actor FROM public.users u WHERE u.auth_id = auth.uid() AND u.is_active = TRUE LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'QC_CHECK_READ_FORBIDDEN'; END IF;
  v_can_check := v_actor.role IN ('admin', 'super_admin') OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_check'];
  IF NOT v_can_check THEN RAISE EXCEPTION 'QC_CHECK_READ_FORBIDDEN'; END IF;
  IF v_actor.role <> 'super_admin' AND v_actor.store_id <> p_store_id THEN RAISE EXCEPTION 'QC_CHECK_READ_FORBIDDEN'; END IF;
  IF p_from IS NULL OR p_to IS NULL THEN RAISE EXCEPTION 'QC_CHECK_RANGE_REQUIRED'; END IF;
  IF p_from > p_to THEN RAISE EXCEPTION 'QC_CHECK_RANGE_INVALID'; END IF;

  RETURN QUERY
  SELECT
    qc.id AS check_id, qc.store_id, qc.template_id, qc.check_date,
    qc.checked_by, qc.result, qc.evidence_photo_url, qc.note, qc.created_at,
    qt.category AS template_category, qt.criteria_text AS template_criteria_text,
    qt.criteria_photo_url AS template_criteria_photo_url, qt.is_global AS template_is_global
  FROM public.qc_checks qc
  JOIN public.qc_templates qt ON qt.id = qc.template_id
  WHERE qc.store_id = p_store_id
    AND qc.check_date >= p_from AND qc.check_date <= p_to
  ORDER BY qc.check_date DESC, lower(qt.category), qt.sort_order, qc.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- upsert_qc_check
CREATE OR REPLACE FUNCTION public.upsert_qc_check(
  p_store_id UUID, p_template_id UUID, p_check_date DATE,
  p_result TEXT, p_evidence_photo_url TEXT DEFAULT NULL,
  p_note TEXT DEFAULT NULL, p_checked_by UUID DEFAULT NULL
) RETURNS public.qc_checks AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_can_check BOOLEAN;
  v_template public.qc_templates%ROWTYPE;
  v_existing public.qc_checks%ROWTYPE;
  v_saved public.qc_checks%ROWTYPE;
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_photo TEXT := NULLIF(btrim(COALESCE(p_evidence_photo_url, '')), '');
  v_checked_by UUID := COALESCE(p_checked_by, auth.uid());
BEGIN
  SELECT u.* INTO v_actor FROM public.users u WHERE u.auth_id = auth.uid() AND u.is_active = TRUE LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'QC_CHECK_WRITE_FORBIDDEN'; END IF;
  v_can_check := v_actor.role IN ('admin', 'super_admin') OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_check'];
  IF NOT v_can_check THEN RAISE EXCEPTION 'QC_CHECK_WRITE_FORBIDDEN'; END IF;
  IF v_actor.role <> 'super_admin' AND v_actor.store_id <> p_store_id THEN RAISE EXCEPTION 'QC_CHECK_WRITE_FORBIDDEN'; END IF;
  IF p_template_id IS NULL THEN RAISE EXCEPTION 'QC_CHECK_TEMPLATE_REQUIRED'; END IF;
  IF p_check_date IS NULL THEN RAISE EXCEPTION 'QC_CHECK_DATE_REQUIRED'; END IF;
  IF p_result NOT IN ('pass', 'fail', 'na') THEN RAISE EXCEPTION 'QC_CHECK_RESULT_INVALID'; END IF;
  IF v_checked_by <> auth.uid() THEN RAISE EXCEPTION 'QC_CHECK_ACTOR_INVALID'; END IF;

  SELECT qt.* INTO v_template FROM public.qc_templates qt
  WHERE qt.id = p_template_id AND qt.is_active = TRUE
    AND (qt.is_global = TRUE OR qt.store_id = p_store_id);
  IF NOT FOUND THEN RAISE EXCEPTION 'QC_CHECK_TEMPLATE_NOT_FOUND'; END IF;

  SELECT qc.* INTO v_existing FROM public.qc_checks qc
  WHERE qc.template_id = p_template_id AND qc.check_date = p_check_date FOR UPDATE;

  INSERT INTO public.qc_checks (
    store_id, template_id, check_date, checked_by, result, evidence_photo_url, note
  ) VALUES (
    p_store_id, p_template_id, p_check_date, v_checked_by, p_result, v_photo, v_note
  )
  ON CONFLICT (template_id, check_date)
  DO UPDATE SET
    store_id = EXCLUDED.store_id, checked_by = EXCLUDED.checked_by,
    result = EXCLUDED.result, evidence_photo_url = EXCLUDED.evidence_photo_url,
    note = EXCLUDED.note
  RETURNING * INTO v_saved;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'qc_check_upserted', 'qc_checks', v_saved.id,
    jsonb_build_object(
      'store_id', p_store_id, 'template_id', p_template_id,
      'check_date', p_check_date, 'result', p_result,
      'evidence_photo_url', v_photo, 'note', v_note,
      'previous_check', CASE
        WHEN v_existing.id IS NULL THEN NULL
        ELSE jsonb_build_object('result', v_existing.result, 'evidence_photo_url', v_existing.evidence_photo_url,
          'note', v_existing.note, 'checked_by', v_existing.checked_by)
      END
    )
  );

  RETURN v_saved;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- get_qc_superadmin_summary
CREATE OR REPLACE FUNCTION public.get_qc_superadmin_summary(
  p_week_start DATE
) RETURNS TABLE (
  store_id UUID,
  store_name TEXT,
  coverage NUMERIC,
  fail_count BIGINT,
  latest_check_date DATE
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_week_end DATE;
BEGIN
  SELECT u.* INTO v_actor FROM public.users u WHERE u.auth_id = auth.uid() AND u.is_active = TRUE LIMIT 1;
  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN RAISE EXCEPTION 'QC_SUMMARY_FORBIDDEN'; END IF;
  IF p_week_start IS NULL THEN RAISE EXCEPTION 'QC_SUMMARY_WEEK_REQUIRED'; END IF;

  v_week_end := p_week_start + 6;

  RETURN QUERY
  WITH active_stores AS (
    SELECT r.id, r.name
    FROM public.stores r
    WHERE r.is_active = TRUE
  ),
  template_counts AS (
    SELECT
      ar.id AS store_id,
      COUNT(*) FILTER (
        WHERE qt.is_active = TRUE
          AND (qt.is_global = TRUE OR qt.store_id = ar.id)
      )::INT AS template_count
    FROM active_stores ar
    LEFT JOIN public.qc_templates qt
      ON qt.is_active = TRUE
     AND (qt.is_global = TRUE OR qt.store_id = ar.id)
    GROUP BY ar.id
  ),
  checks AS (
    SELECT
      qc.store_id,
      COUNT(*)::BIGINT AS checked_count,
      COUNT(*) FILTER (WHERE qc.result = 'fail')::BIGINT AS fail_count,
      MAX(qc.check_date) AS latest_check_date
    FROM public.qc_checks qc
    WHERE qc.check_date >= p_week_start
      AND qc.check_date <= v_week_end
    GROUP BY qc.store_id
  )
  SELECT
    ar.id AS store_id,
    ar.name AS store_name,
    CASE
      WHEN COALESCE(tc.template_count, 0) = 0 THEN 0::NUMERIC
      ELSE ROUND(
        COALESCE(ch.checked_count, 0)::NUMERIC
        / (tc.template_count * 7)::NUMERIC * 100,
        2
      )
    END AS coverage,
    COALESCE(ch.fail_count, 0) AS fail_count,
    ch.latest_check_date
  FROM active_stores ar
  LEFT JOIN template_counts tc ON tc.store_id = ar.id
  LEFT JOIN checks ch ON ch.store_id = ar.id
  ORDER BY lower(ar.name);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── QC Follow-up functions ──

-- create_qc_followup
CREATE OR REPLACE FUNCTION public.create_qc_followup(
  p_store_id UUID,
  p_source_check_id UUID,
  p_assigned_to_name TEXT DEFAULT NULL
) RETURNS public.qc_followups AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_check public.qc_checks%ROWTYPE;
  v_created public.qc_followups%ROWTYPE;
BEGIN
  SELECT * INTO v_actor FROM public.users WHERE auth_id = auth.uid() AND is_active = TRUE LIMIT 1;
  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN'; END IF;
  IF v_actor.role <> 'super_admin' AND v_actor.store_id <> p_store_id THEN RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN'; END IF;

  SELECT * INTO v_check FROM public.qc_checks WHERE id = p_source_check_id AND store_id = p_store_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'QC_FOLLOWUP_CHECK_NOT_FOUND'; END IF;
  IF v_check.result <> 'fail' THEN RAISE EXCEPTION 'QC_FOLLOWUP_NOT_FAILED_CHECK'; END IF;
  IF EXISTS (SELECT 1 FROM public.qc_followups WHERE source_check_id = p_source_check_id) THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_ALREADY_EXISTS';
  END IF;

  INSERT INTO public.qc_followups (
    store_id, source_check_id, status, assigned_to_name, created_by
  ) VALUES (
    p_store_id, p_source_check_id, 'open',
    NULLIF(btrim(COALESCE(p_assigned_to_name, '')), ''), auth.uid()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'qc_followup_created', 'qc_followups', v_created.id,
    jsonb_build_object('store_id', p_store_id, 'source_check_id', p_source_check_id,
      'assigned_to_name', v_created.assigned_to_name)
  );

  RETURN v_created;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- update_qc_followup_status
CREATE OR REPLACE FUNCTION public.update_qc_followup_status(
  p_followup_id UUID, p_store_id UUID,
  p_status TEXT, p_resolution_notes TEXT DEFAULT NULL
) RETURNS public.qc_followups AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_existing public.qc_followups%ROWTYPE;
  v_updated public.qc_followups%ROWTYPE;
BEGIN
  SELECT * INTO v_actor FROM public.users WHERE auth_id = auth.uid() AND is_active = TRUE LIMIT 1;
  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN'; END IF;
  IF v_actor.role <> 'super_admin' AND v_actor.store_id <> p_store_id THEN RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN'; END IF;
  IF p_status NOT IN ('open', 'in_progress', 'resolved') THEN RAISE EXCEPTION 'QC_FOLLOWUP_STATUS_INVALID'; END IF;

  SELECT * INTO v_existing FROM public.qc_followups WHERE id = p_followup_id AND store_id = p_store_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'QC_FOLLOWUP_NOT_FOUND'; END IF;

  UPDATE public.qc_followups
  SET status = p_status,
      resolution_notes = CASE WHEN p_resolution_notes IS NOT NULL THEN NULLIF(btrim(p_resolution_notes), '') ELSE resolution_notes END,
      updated_at = now(),
      resolved_at = CASE WHEN p_status = 'resolved' THEN now() ELSE NULL END
  WHERE id = p_followup_id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'qc_followup_status_updated', 'qc_followups', v_updated.id,
    jsonb_build_object('store_id', p_store_id, 'old_status', v_existing.status,
      'new_status', p_status, 'resolution_notes', v_updated.resolution_notes)
  );

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- get_qc_followups
CREATE OR REPLACE FUNCTION public.get_qc_followups(
  p_store_id UUID,
  p_status_filter TEXT DEFAULT NULL
) RETURNS TABLE (
  followup_id UUID, store_id UUID, source_check_id UUID, status TEXT,
  assigned_to_name TEXT, resolution_notes TEXT, created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ, resolved_at TIMESTAMPTZ, check_date DATE,
  check_result TEXT, check_note TEXT, template_category TEXT, template_criteria TEXT
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT * INTO v_actor FROM public.users WHERE auth_id = auth.uid() AND is_active = TRUE LIMIT 1;
  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN RAISE EXCEPTION 'QC_FOLLOWUP_READ_FORBIDDEN'; END IF;
  IF v_actor.role <> 'super_admin' AND v_actor.store_id <> p_store_id THEN RAISE EXCEPTION 'QC_FOLLOWUP_READ_FORBIDDEN'; END IF;

  RETURN QUERY
  SELECT
    f.id AS followup_id, f.store_id, f.source_check_id, f.status,
    f.assigned_to_name, f.resolution_notes, f.created_at, f.updated_at, f.resolved_at,
    qc.check_date, qc.result AS check_result, qc.note AS check_note,
    qt.category AS template_category, qt.criteria_text AS template_criteria
  FROM public.qc_followups f
  JOIN public.qc_checks qc ON qc.id = f.source_check_id
  JOIN public.qc_templates qt ON qt.id = qc.template_id
  WHERE f.store_id = p_store_id
    AND (p_status_filter IS NULL OR f.status = p_status_filter)
  ORDER BY
    CASE f.status WHEN 'open' THEN 0 WHEN 'in_progress' THEN 1 WHEN 'resolved' THEN 2 END,
    f.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- get_qc_analytics
CREATE OR REPLACE FUNCTION public.get_qc_analytics(
  p_store_id UUID, p_from DATE, p_to DATE
) RETURNS TABLE (
  total_checks BIGINT, pass_count BIGINT, fail_count BIGINT, na_count BIGINT,
  pass_rate NUMERIC, template_count BIGINT, coverage NUMERIC, open_followups BIGINT
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_can_check BOOLEAN;
  v_days INT;
BEGIN
  SELECT * INTO v_actor FROM public.users WHERE auth_id = auth.uid() AND is_active = TRUE LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'QC_ANALYTICS_FORBIDDEN'; END IF;
  v_can_check := v_actor.role IN ('admin', 'super_admin') OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_check'];
  IF NOT v_can_check THEN RAISE EXCEPTION 'QC_ANALYTICS_FORBIDDEN'; END IF;
  IF v_actor.role <> 'super_admin' AND v_actor.store_id <> p_store_id THEN RAISE EXCEPTION 'QC_ANALYTICS_FORBIDDEN'; END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN RAISE EXCEPTION 'QC_ANALYTICS_RANGE_INVALID'; END IF;

  v_days := (p_to - p_from) + 1;

  RETURN QUERY
  SELECT
    COUNT(*)::BIGINT AS total_checks,
    COUNT(*) FILTER (WHERE qc.result = 'pass')::BIGINT AS pass_count,
    COUNT(*) FILTER (WHERE qc.result = 'fail')::BIGINT AS fail_count,
    COUNT(*) FILTER (WHERE qc.result = 'na')::BIGINT AS na_count,
    CASE
      WHEN COUNT(*) FILTER (WHERE qc.result IN ('pass','fail')) = 0 THEN 0::NUMERIC
      ELSE ROUND(COUNT(*) FILTER (WHERE qc.result = 'pass')::NUMERIC / COUNT(*) FILTER (WHERE qc.result IN ('pass','fail'))::NUMERIC * 100, 1)
    END AS pass_rate,
    (SELECT COUNT(*) FROM public.qc_templates qt
     WHERE qt.is_active = TRUE AND (qt.is_global = TRUE OR qt.store_id = p_store_id))::BIGINT AS template_count,
    CASE
      WHEN (SELECT COUNT(*) FROM public.qc_templates qt
            WHERE qt.is_active = TRUE AND (qt.is_global = TRUE OR qt.store_id = p_store_id)) = 0
      THEN 0::NUMERIC
      ELSE ROUND(COUNT(*)::NUMERIC / ((SELECT COUNT(*) FROM public.qc_templates qt
            WHERE qt.is_active = TRUE AND (qt.is_global = TRUE OR qt.store_id = p_store_id)) * v_days)::NUMERIC * 100, 1)
    END AS coverage,
    (SELECT COUNT(*) FROM public.qc_followups f
     WHERE f.store_id = p_store_id AND f.status IN ('open', 'in_progress'))::BIGINT AS open_followups
  FROM public.qc_checks qc
  WHERE qc.store_id = p_store_id AND qc.check_date >= p_from AND qc.check_date <= p_to;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── update_my_profile_full_name (body references restaurant_id in audit) ──
CREATE OR REPLACE FUNCTION public.update_my_profile_full_name(
  p_full_name TEXT
) RETURNS public.users AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_updated public.users%ROWTYPE;
  v_full_name TEXT := NULLIF(btrim(COALESCE(p_full_name, '')), '');
BEGIN
  IF v_full_name IS NULL THEN RAISE EXCEPTION 'USER_FULL_NAME_REQUIRED'; END IF;

  SELECT * INTO v_actor FROM public.users WHERE auth_id = auth.uid() AND is_active = TRUE LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'USER_PROFILE_UPDATE_FORBIDDEN'; END IF;

  UPDATE public.users SET full_name = v_full_name WHERE id = v_actor.id RETURNING * INTO v_updated;
  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── admin_update_staff_account ──
CREATE OR REPLACE FUNCTION public.admin_update_staff_account(
  p_user_id UUID,
  p_store_id UUID,
  p_full_name TEXT DEFAULT NULL,
  p_is_active BOOLEAN DEFAULT NULL,
  p_extra_permissions TEXT[] DEFAULT NULL
) RETURNS public.users AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_target public.users%ROWTYPE;
  v_updated public.users%ROWTYPE;
  v_full_name TEXT := NULLIF(btrim(COALESCE(p_full_name, '')), '');
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
BEGIN
  SELECT * INTO v_actor FROM public.users WHERE auth_id = auth.uid() AND is_active = TRUE LIMIT 1;
  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN'; END IF;
  IF p_user_id IS NULL OR p_store_id IS NULL THEN RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_INVALID'; END IF;
  IF v_actor.role <> 'super_admin' AND v_actor.store_id <> p_store_id THEN RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN'; END IF;

  SELECT * INTO v_target FROM public.users WHERE id = p_user_id AND store_id = p_store_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'STAFF_ACCOUNT_NOT_FOUND'; END IF;
  IF v_actor.role = 'admin' AND v_target.role IN ('admin', 'super_admin') THEN RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN'; END IF;

  IF p_full_name IS NOT NULL THEN
    IF v_full_name IS NULL THEN RAISE EXCEPTION 'USER_FULL_NAME_REQUIRED'; END IF;
    IF v_full_name IS DISTINCT FROM v_target.full_name THEN
      v_changed_fields := array_append(v_changed_fields, 'full_name');
      v_old_values := v_old_values || jsonb_build_object('full_name', v_target.full_name);
      v_new_values := v_new_values || jsonb_build_object('full_name', v_full_name);
    END IF;
  ELSE
    v_full_name := v_target.full_name;
  END IF;

  IF p_is_active IS NOT NULL AND p_is_active IS DISTINCT FROM v_target.is_active THEN
    v_changed_fields := array_append(v_changed_fields, 'is_active');
    v_old_values := v_old_values || jsonb_build_object('is_active', v_target.is_active);
    v_new_values := v_new_values || jsonb_build_object('is_active', p_is_active);
  END IF;

  IF p_extra_permissions IS NOT NULL
     AND COALESCE(p_extra_permissions, ARRAY[]::TEXT[]) IS DISTINCT FROM COALESCE(v_target.extra_permissions, ARRAY[]::TEXT[]) THEN
    v_changed_fields := array_append(v_changed_fields, 'extra_permissions');
    v_old_values := v_old_values || jsonb_build_object('extra_permissions', COALESCE(v_target.extra_permissions, ARRAY[]::TEXT[]));
    v_new_values := v_new_values || jsonb_build_object('extra_permissions', COALESCE(p_extra_permissions, ARRAY[]::TEXT[]));
  END IF;

  UPDATE public.users
  SET full_name = v_full_name,
      is_active = COALESCE(p_is_active, v_target.is_active),
      extra_permissions = CASE WHEN p_extra_permissions IS NULL THEN v_target.extra_permissions ELSE COALESCE(p_extra_permissions, ARRAY[]::TEXT[]) END
  WHERE id = v_target.id
  RETURNING * INTO v_updated;

  IF array_length(v_changed_fields, 1) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(), 'admin_update_staff_account', 'users', v_updated.id,
      jsonb_build_object('store_id', v_updated.store_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values, 'new_values', v_new_values)
    );
  END IF;

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── complete_onboarding_account_setup ──
CREATE OR REPLACE FUNCTION public.complete_onboarding_account_setup(
  p_store_id UUID,
  p_full_name TEXT,
  p_role TEXT
) RETURNS public.users AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_updated public.users%ROWTYPE;
  v_full_name TEXT := NULLIF(btrim(COALESCE(p_full_name, '')), '');
BEGIN
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'ONBOARDING_STORE_REQUIRED'; END IF;
  IF v_full_name IS NULL THEN RAISE EXCEPTION 'USER_FULL_NAME_REQUIRED'; END IF;
  IF p_role NOT IN ('admin', 'super_admin') THEN RAISE EXCEPTION 'ONBOARDING_ROLE_INVALID'; END IF;

  SELECT * INTO v_actor FROM public.users WHERE auth_id = auth.uid() AND is_active = TRUE LIMIT 1;
  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN RAISE EXCEPTION 'ONBOARDING_ACCOUNT_UPDATE_FORBIDDEN'; END IF;

  UPDATE public.users
  SET store_id = p_store_id, full_name = v_full_name, role = p_role
  WHERE id = v_actor.id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'complete_onboarding_account_setup', 'users', v_updated.id,
    jsonb_build_object('store_id', p_store_id, 'new_role', p_role)
  );

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── office_confirm_payroll (no restaurant_id references, but search_path fix) ──
CREATE OR REPLACE FUNCTION office_confirm_payroll(p_payroll_id UUID)
RETURNS payroll_records AS $$
DECLARE
  v_actor_id UUID := auth.uid();
  v_payroll payroll_records;
BEGIN
  SELECT * INTO v_payroll FROM payroll_records WHERE id = p_payroll_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYROLL_NOT_FOUND'; END IF;
  IF v_payroll.status <> 'store_submitted' THEN RAISE EXCEPTION 'INVALID_STATUS_TRANSITION'; END IF;

  UPDATE payroll_records SET status = 'office_confirmed', updated_at = now() WHERE id = p_payroll_id RETURNING * INTO v_payroll;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (v_actor_id, 'office_confirm_payroll', 'payroll_records', p_payroll_id,
    jsonb_build_object('from_status', 'store_submitted', 'to_status', 'office_confirmed'));

  RETURN v_payroll;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ── office_return_payroll (no restaurant_id references, but search_path fix) ──
CREATE OR REPLACE FUNCTION office_return_payroll(p_payroll_id UUID)
RETURNS payroll_records AS $$
DECLARE
  v_actor_id UUID := auth.uid();
  v_payroll payroll_records;
BEGIN
  SELECT * INTO v_payroll FROM payroll_records WHERE id = p_payroll_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYROLL_NOT_FOUND'; END IF;
  IF v_payroll.status <> 'store_submitted' THEN RAISE EXCEPTION 'INVALID_STATUS_TRANSITION'; END IF;

  UPDATE payroll_records SET status = 'draft', updated_at = now() WHERE id = p_payroll_id RETURNING * INTO v_payroll;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (v_actor_id, 'office_return_payroll', 'payroll_records', p_payroll_id,
    jsonb_build_object('from_status', 'store_submitted', 'to_status', 'draft'));

  RETURN v_payroll;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ============================================================================
-- SECTION 9: Trigger function updates
-- ============================================================================

-- on_payroll_store_submitted: references restaurants → stores, restaurant_id → store_id
CREATE OR REPLACE FUNCTION on_payroll_store_submitted()
RETURNS TRIGGER AS $$
DECLARE
  v_brand_id UUID;
BEGIN
  SELECT brand_id
  INTO v_brand_id
  FROM stores
  WHERE id = NEW.store_id;

  INSERT INTO office_payroll_reviews (
    source_payroll_id,
    store_id,
    brand_id,
    period_start,
    period_end,
    status
  )
  VALUES (
    NEW.id,
    NEW.store_id,
    v_brand_id,
    NEW.period_start,
    NEW.period_end,
    'pending_review'
  )
  ON CONFLICT (source_payroll_id, period_start, period_end) DO NOTHING;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ============================================================================
-- SECTION 10: Table comments update
-- ============================================================================

COMMENT ON TABLE stores IS 'F&B store tenant (renamed from restaurants)';
COMMENT ON TABLE store_settings IS 'Per-store settings (renamed from restaurant_settings)';
COMMENT ON COLUMN stores.store_type IS
  'direct = 직영(Office 연동), external = 외부(POS super_admin 전용, Office 비노출)';

COMMIT;
