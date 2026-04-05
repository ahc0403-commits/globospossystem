-- ============================================================
-- Office Integration Phase 1: Connection views for Office System
-- 2026-04-05
-- Creates: 5 read-only views for Office consumption
-- Depends on: 20260405000000_office_shared_hierarchy.sql
-- Related docs: Governance/OFFICE_INTEGRATION.md
-- ============================================================

-- ============================================================
-- v_store_daily_sales: 매장별 일자별 매출 집계
-- Consumer: Office Sales Dashboard, KPI
-- ============================================================
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
JOIN restaurants r ON r.id = p.restaurant_id
LEFT JOIN brands b ON b.id = r.brand_id
GROUP BY r.id, r.brand_id, b.name, r.name,
         DATE(p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh');

-- ============================================================
-- v_store_attendance_summary: 매장별 직원별 일자별 근태
-- Consumer: Office Payroll Review
-- ============================================================
CREATE OR REPLACE VIEW v_store_attendance_summary AS
SELECT
  al.restaurant_id AS store_id,
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
JOIN restaurants r ON r.id = al.restaurant_id
JOIN users u ON u.id = al.user_id
GROUP BY al.restaurant_id, r.brand_id, al.user_id, COALESCE(u.full_name, u.role), u.role,
         DATE(al.logged_at AT TIME ZONE 'Asia/Ho_Chi_Minh');

-- ============================================================
-- v_quality_monitoring: 품질 점검 결과 + 증빙
-- Consumer: Office Quality Monitoring
-- ============================================================
CREATE OR REPLACE VIEW v_quality_monitoring AS
SELECT
  qc.id AS check_id,
  qc.restaurant_id AS store_id,
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
JOIN restaurants r ON r.id = qc.restaurant_id;

-- ============================================================
-- v_inventory_status: 재고 현황 + 발주 필요 여부
-- Consumer: Office Inventory Monitoring, Purchase
-- ============================================================
CREATE OR REPLACE VIEW v_inventory_status AS
SELECT
  ii.id AS item_id,
  ii.restaurant_id AS store_id,
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
JOIN restaurants r ON r.id = ii.restaurant_id;

-- ============================================================
-- v_brand_kpi: 브랜드별 KPI 요약
-- Consumer: Office KPI Dashboard, Super Admin
-- ============================================================
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
    JOIN restaurants r2 ON r2.id = p.restaurant_id
    WHERE r2.brand_id = b.id
      AND p.is_revenue = TRUE
      AND p.created_at >= date_trunc('month', now() AT TIME ZONE 'Asia/Ho_Chi_Minh')
  ) AS mtd_revenue,
  (
    SELECT COUNT(DISTINCT p.order_id)
    FROM payments p
    JOIN restaurants r2 ON r2.id = p.restaurant_id
    WHERE r2.brand_id = b.id
      AND p.is_revenue = TRUE
      AND p.created_at >= date_trunc('month', now() AT TIME ZONE 'Asia/Ho_Chi_Minh')
  ) AS mtd_order_count
FROM brands b
LEFT JOIN restaurants r ON r.brand_id = b.id
LEFT JOIN users u ON u.restaurant_id = r.id
GROUP BY b.id, b.code, b.name;

-- ============================================================
-- Grant SELECT on all views to authenticated users
-- (RLS on underlying tables still applies)
-- ============================================================
GRANT SELECT ON v_store_daily_sales TO authenticated;
GRANT SELECT ON v_store_attendance_summary TO authenticated;
GRANT SELECT ON v_quality_monitoring TO authenticated;
GRANT SELECT ON v_inventory_status TO authenticated;
GRANT SELECT ON v_brand_kpi TO authenticated;
