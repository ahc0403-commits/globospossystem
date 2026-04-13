-- ============================================================
-- ADR-013: Store Type Classification (direct vs external)
-- 2026-04-05
-- 
-- 직영매장(direct): Office 시스템에 모든 데이터 노출
-- 외부매장(external): POS super_admin만 접근, Office 완전 차단
--
-- Changes:
--   1. restaurants.store_type 컬럼 추가
--   2. 인덱스 2개 (단독 + 복합)
--   3. 연결 뷰 5개 재생성 (store_type='direct' 필터)
--   4. office_get_accessible_store_ids() 함수 수정
--   5. 외부매장 전용 뷰 2개 신규 생성
--
-- Depends on: 20260405000000, 20260405000003, 20260405000009
-- Non-breaking: default 'direct' → 기존 데이터 영향 없음
-- ============================================================

BEGIN;

-- ============================================================
-- 1. restaurants.store_type 컬럼 추가
-- ============================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'restaurants'
      AND column_name = 'store_type'
  ) THEN
    ALTER TABLE restaurants
      ADD COLUMN store_type TEXT NOT NULL DEFAULT 'direct';
    ALTER TABLE restaurants
      ADD CONSTRAINT restaurants_store_type_check
      CHECK (store_type IN ('direct', 'external'));
    RAISE NOTICE 'Added store_type to restaurants';
  ELSE
    RAISE NOTICE 'store_type already exists on restaurants';
  END IF;
END $$;

COMMENT ON COLUMN restaurants.store_type IS
  'direct = 직영(Office 연동), external = 외부(POS super_admin 전용, Office 비노출)';

-- 인덱스: 50+ 외부매장 대규모 확장 대비
CREATE INDEX IF NOT EXISTS idx_restaurants_store_type
  ON restaurants(store_type);
CREATE INDEX IF NOT EXISTS idx_restaurants_brand_store_type
  ON restaurants(brand_id, store_type);

-- ============================================================
-- 2. 연결 뷰 5개 재생성 (store_type = 'direct' 필터 추가)
-- ============================================================

-- v_store_daily_sales
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
WHERE r.store_type = 'direct'
GROUP BY r.id, r.brand_id, b.name, r.name,
         DATE(p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh');

-- v_store_attendance_summary
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
WHERE r.store_type = 'direct'
GROUP BY al.restaurant_id, r.brand_id, al.user_id, COALESCE(u.full_name, u.role), u.role,
         DATE(al.logged_at AT TIME ZONE 'Asia/Ho_Chi_Minh');

-- v_quality_monitoring
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
JOIN restaurants r ON r.id = qc.restaurant_id
WHERE r.store_type = 'direct';

-- v_inventory_status
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
JOIN restaurants r ON r.id = ii.restaurant_id
WHERE r.store_type = 'direct';

-- v_brand_kpi
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
      AND r2.store_type = 'direct'
      AND p.is_revenue = TRUE
      AND p.created_at >= date_trunc('month', now() AT TIME ZONE 'Asia/Ho_Chi_Minh')
  ) AS mtd_revenue,
  (
    SELECT COUNT(DISTINCT p.order_id)
    FROM payments p
    JOIN restaurants r2 ON r2.id = p.restaurant_id
    WHERE r2.brand_id = b.id
      AND r2.store_type = 'direct'
      AND p.is_revenue = TRUE
      AND p.created_at >= date_trunc('month', now() AT TIME ZONE 'Asia/Ho_Chi_Minh')
  ) AS mtd_order_count
FROM brands b
LEFT JOIN restaurants r ON r.brand_id = b.id AND r.store_type = 'direct'
LEFT JOIN users u ON u.restaurant_id = r.id
GROUP BY b.id, b.code, b.name;

-- ============================================================
-- 3. office_get_accessible_store_ids() 수정
--    Office 사용자가 접근 가능한 매장 목록에서 external 제외
--    (벨트 앤 서스펜더: 뷰 필터 + 함수 필터 이중 방어)
-- ============================================================
CREATE OR REPLACE FUNCTION public.office_get_accessible_store_ids()
RETURNS uuid[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_scope_type text;
  v_scope_ids uuid[];
  v_store_ids uuid[];
BEGIN
  SELECT scope_type, scope_ids
    INTO v_scope_type, v_scope_ids
  FROM public.office_user_profiles
  WHERE auth_id = auth.uid()
  LIMIT 1;

  IF v_scope_type IS NULL THEN
    RETURN array[]::uuid[];
  END IF;

  IF v_scope_type = 'global' THEN
    SELECT array_agg(r.id) INTO v_store_ids
    FROM public.restaurants r
    WHERE r.store_type = 'direct';  -- ★ external 제외
    RETURN COALESCE(v_store_ids, array[]::uuid[]);
  END IF;

  IF v_scope_type = 'brand' THEN
    SELECT array_agg(r.id) INTO v_store_ids
    FROM public.restaurants r
    WHERE r.brand_id = ANY(v_scope_ids)
      AND r.store_type = 'direct';  -- ★ external 제외
    RETURN COALESCE(v_store_ids, array[]::uuid[]);
  END IF;

  -- store scope: 직접 할당된 매장 중 direct만
  SELECT array_agg(r.id) INTO v_store_ids
  FROM public.restaurants r
  WHERE r.id = ANY(v_scope_ids)
    AND r.store_type = 'direct';  -- ★ external 제외
  RETURN COALESCE(v_store_ids, array[]::uuid[]);
END;
$$;

-- ============================================================
-- 4. POS super_admin 전용: 외부매장 뷰
-- ============================================================

-- 외부매장 매출 요약
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
JOIN restaurants r ON r.id = p.restaurant_id
LEFT JOIN brands b ON b.id = r.brand_id
WHERE r.store_type = 'external'
GROUP BY r.id, r.brand_id, b.name, r.name,
         DATE(p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh');

-- 외부매장 통합 현황
CREATE OR REPLACE VIEW v_external_store_overview AS
SELECT
  r.id AS store_id,
  r.name AS store_name,
  b.name AS brand_name,
  r.brand_id,
  r.is_active,
  r.created_at AS registered_at,
  (SELECT COUNT(*) FROM users u
   WHERE u.restaurant_id = r.id AND u.is_active = TRUE) AS active_staff,
  (SELECT COALESCE(SUM(p.amount), 0)
   FROM payments p
   WHERE p.restaurant_id = r.id AND p.is_revenue = TRUE
     AND p.created_at >= date_trunc('month', now())) AS mtd_sales,
  (SELECT COUNT(DISTINCT o.id)
   FROM orders o
   WHERE o.restaurant_id = r.id
     AND o.created_at >= date_trunc('month', now())) AS mtd_order_count
FROM restaurants r
LEFT JOIN brands b ON b.id = r.brand_id
WHERE r.store_type = 'external';

-- ============================================================
-- 5. GRANT: 외부매장 뷰는 authenticated만 (POS super_admin이 RLS로 걸러짐)
-- ============================================================
GRANT SELECT ON v_external_store_sales TO authenticated;
GRANT SELECT ON v_external_store_overview TO authenticated;

-- ============================================================
-- 6. 기존 뷰 GRANT 재확인 (CREATE OR REPLACE 후 유지 확인)
-- ============================================================
GRANT SELECT ON v_store_daily_sales TO authenticated;
GRANT SELECT ON v_store_attendance_summary TO authenticated;
GRANT SELECT ON v_quality_monitoring TO authenticated;
GRANT SELECT ON v_inventory_status TO authenticated;
GRANT SELECT ON v_brand_kpi TO authenticated;

COMMIT;

-- ============================================================
-- ROLLBACK SQL (비상시 수동 실행)
-- ============================================================
-- BEGIN;
-- DROP VIEW IF EXISTS v_external_store_overview;
-- DROP VIEW IF EXISTS v_external_store_sales;
-- DROP INDEX IF EXISTS idx_restaurants_brand_store_type;
-- DROP INDEX IF EXISTS idx_restaurants_store_type;
-- ALTER TABLE restaurants DROP CONSTRAINT IF EXISTS restaurants_store_type_check;
-- ALTER TABLE restaurants DROP COLUMN IF EXISTS store_type;
-- -- 그 후 20260405000003_office_connection_views.sql 원본으로 뷰 5개 복원
-- -- 그 후 20260405000009_office_view_rls.sql 원본으로 함수 복원
-- COMMIT;
