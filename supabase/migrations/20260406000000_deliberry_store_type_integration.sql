-- ============================================================
-- ADR-013 Phase 3: Deliberry store_type Integration
-- 2026-04-06
--
-- Deliberry는 직영+외부 모두 배달 주문 가능 (필터 없음)
-- store_type을 public 뷰에 노출하여 직영점 뱃지 표시 가능
--
-- Depends on: 20260405000012_store_type_classification
-- Non-breaking: 기존 쿼리 호환 유지 (컬럼 추가만)
-- ============================================================

BEGIN;

-- ============================================================
-- 1. public_restaurant_profiles: DROP → CREATE (컬럼 추가)
--    기존 컬럼: id, slug, name, address, operation_mode,
--              per_person_charge, is_active, created_at
--    추가: store_type, brand_id, brand_name
-- ============================================================
DROP VIEW IF EXISTS public_restaurant_profiles;

CREATE VIEW public_restaurant_profiles AS
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
FROM restaurants r
LEFT JOIN brands b ON b.id = r.brand_id
WHERE r.is_active = TRUE;

GRANT SELECT ON public_restaurant_profiles TO anon;
GRANT SELECT ON public_restaurant_profiles TO authenticated;

-- ============================================================
-- 2. public_menu_items: DROP → CREATE (store_type 추가)
-- ============================================================
DROP VIEW IF EXISTS public_menu_items;

CREATE VIEW public_menu_items AS
SELECT
  mi.id AS external_menu_item_id,
  mi.restaurant_id,
  r.slug AS restaurant_slug,
  r.store_type,
  mc.name AS category_name,
  mi.name,
  mi.description,
  mi.price,
  r.operation_mode
FROM menu_items mi
JOIN restaurants r ON r.id = mi.restaurant_id
LEFT JOIN menu_categories mc ON mc.id = mi.category_id
WHERE mi.is_available = TRUE
  AND mi.is_visible_public = TRUE;

GRANT SELECT ON public_menu_items TO anon;
GRANT SELECT ON public_menu_items TO authenticated;

COMMIT;
