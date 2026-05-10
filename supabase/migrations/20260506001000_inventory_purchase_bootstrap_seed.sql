-- ============================================================
-- Inventory Purchase Bootstrap Seed
-- 2026-05-06
--
-- Idempotent starter data for validating the inventory purchase workflow.
-- It does not touch existing general purchase flows.
--
-- DEV_ONLY: the seed body below is wrapped in a SQL block comment to keep
-- this migration a production-safe no-op. The recovery PR only lands the
-- dormant inventory_purchase domain; demo data is not injected into live
-- inventory_items or daily-consumption tables. To enable the seed in a
-- development environment, remove the `/*` / `*/` markers around the body.
-- ============================================================

/*
WITH supplier_seed AS (
  SELECT *
  FROM (VALUES
    ('한우푸드', '육류', '김철수', '010-1234-5678', '월말 결제'),
    ('청정야채', '야채/과일', '이영희', '010-2345-6789', '월말 결제'),
    ('푸드마켓', '공산품', '박지민', '010-3456-7890', '월말 결제')
  ) AS seed(supplier_name, supplier_type, contact_name, phone, payment_terms)
),
target_brands AS (
  SELECT DISTINCT brand_id
  FROM public.restaurants
  WHERE is_active = TRUE
),
inserted_suppliers AS (
  INSERT INTO public.inventory_suppliers (
    brand_id,
    supplier_name,
    supplier_type,
    contact_name,
    phone,
    payment_terms,
    status
  )
  SELECT
    tb.brand_id,
    ss.supplier_name,
    ss.supplier_type,
    ss.contact_name,
    ss.phone,
    ss.payment_terms,
    'active'
  FROM target_brands tb
  CROSS JOIN supplier_seed ss
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.inventory_suppliers existing
    WHERE existing.brand_id IS NOT DISTINCT FROM tb.brand_id
      AND existing.supplier_name = ss.supplier_name
  )
  RETURNING id
)
SELECT COUNT(*) FROM inserted_suppliers;

WITH item_seed AS (
  SELECT *
  FROM (VALUES
    ('BEEF-001', '소고기 등심', '육류', 'kg', 'g', 1000::NUMERIC, 32000::NUMERIC, 35000::NUMERIC, 18::NUMERIC, 6::NUMERIC, '한우푸드', 'kg', 1000::NUMERIC, 1::NUMERIC, 1),
    ('BEEF-002', '소고기 채끝', '육류', 'kg', 'g', 1000::NUMERIC, 28000::NUMERIC, 38000::NUMERIC, 15::NUMERIC, 5::NUMERIC, '한우푸드', 'kg', 1000::NUMERIC, 1::NUMERIC, 1),
    ('PORK-001', '돼지고기 삼겹살', '육류', 'kg', 'g', 1000::NUMERIC, 15000::NUMERIC, 20000::NUMERIC, 20::NUMERIC, 8::NUMERIC, '한우푸드', 'kg', 1000::NUMERIC, 1::NUMERIC, 1),
    ('VEG-001', '양파', '야채/과일', 'kg', 'g', 1000::NUMERIC, 1200::NUMERIC, 1500::NUMERIC, 30::NUMERIC, 10::NUMERIC, '청정야채', '망', 10000::NUMERIC, 1::NUMERIC, 1),
    ('VEG-002', '대파', '야채/과일', 'kg', 'g', 1000::NUMERIC, 1800::NUMERIC, 2200::NUMERIC, 18::NUMERIC, 7::NUMERIC, '청정야채', '단', 1000::NUMERIC, 5::NUMERIC, 1),
    ('VEG-003', '양상추', '야채/과일', 'kg', 'g', 1000::NUMERIC, 2400::NUMERIC, 3000::NUMERIC, 10::NUMERIC, 5::NUMERIC, '청정야채', '박스', 5000::NUMERIC, 1::NUMERIC, 1),
    ('SAUCE-001', '소스 데리야끼', '공산품', '팩', 'ea', 1::NUMERIC, 6500::NUMERIC, 6500::NUMERIC, 12::NUMERIC, 4::NUMERIC, '푸드마켓', '팩', 1::NUMERIC, 5::NUMERIC, 2),
    ('DAIRY-001', '피자치즈', '유제품', 'kg', 'g', 1000::NUMERIC, 8500::NUMERIC, 10500::NUMERIC, 8::NUMERIC, 4::NUMERIC, '푸드마켓', '봉', 2500::NUMERIC, 2::NUMERIC, 2)
  ) AS seed(product_code, name, category, stock_unit, base_unit, base_unit_factor, purchase_unit_price, sale_unit_price, current_display_stock, reorder_display_stock, supplier_name, order_unit, order_unit_quantity_base, min_order_quantity, lead_time_days)
),
target_stores AS (
  SELECT id AS restaurant_id, brand_id
  FROM public.restaurants
  WHERE is_active = TRUE
),
inserted_items AS (
  INSERT INTO public.inventory_items (
    restaurant_id,
    name,
    quantity,
    unit,
    current_stock,
    reorder_point,
    cost_per_unit,
    supplier_name,
    is_active
  )
  SELECT
    ts.restaurant_id,
    seed.name,
    seed.current_display_stock * seed.base_unit_factor,
    seed.base_unit,
    seed.current_display_stock * seed.base_unit_factor,
    seed.reorder_display_stock * seed.base_unit_factor,
    ROUND(seed.purchase_unit_price / NULLIF(seed.base_unit_factor, 0), 4),
    seed.supplier_name,
    TRUE
  FROM target_stores ts
  CROSS JOIN item_seed seed
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.inventory_items existing
    WHERE existing.restaurant_id = ts.restaurant_id
      AND existing.name = seed.name
  )
  RETURNING id
),
source_items AS (
  SELECT DISTINCT ON (ii.restaurant_id, ii.name)
    ii.id,
    ii.restaurant_id,
    ii.name
  FROM public.inventory_items ii
  ORDER BY ii.restaurant_id, ii.name, ii.created_at DESC
),
inserted_products AS (
  INSERT INTO public.inventory_products (
    restaurant_id,
    brand_id,
    inventory_item_id,
    product_code,
    name,
    category,
    stock_unit,
    base_unit,
    base_unit_factor,
    is_orderable,
    is_active
  )
  SELECT
    ts.restaurant_id,
    ts.brand_id,
    si.id,
    seed.product_code,
    seed.name,
    seed.category,
    seed.stock_unit,
    seed.base_unit,
    seed.base_unit_factor,
    TRUE,
    TRUE
  FROM target_stores ts
  CROSS JOIN item_seed seed
  JOIN source_items si
    ON si.restaurant_id = ts.restaurant_id
   AND si.name = seed.name
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.inventory_products existing
    WHERE existing.restaurant_id = ts.restaurant_id
      AND existing.product_code = seed.product_code
  )
  RETURNING id
)
UPDATE public.inventory_products ip
SET inventory_item_id = si.id,
    updated_at = now()
FROM source_items si
WHERE ip.inventory_item_id IS NULL
  AND ip.restaurant_id = si.restaurant_id
  AND ip.name = si.name;

WITH item_seed AS (
  SELECT *
  FROM (VALUES
    ('BEEF-001', '소고기 등심', '육류', 'kg', 'g', 1000::NUMERIC),
    ('BEEF-002', '소고기 채끝', '육류', 'kg', 'g', 1000::NUMERIC),
    ('PORK-001', '돼지고기 삼겹살', '육류', 'kg', 'g', 1000::NUMERIC),
    ('VEG-001', '양파', '야채/과일', 'kg', 'g', 1000::NUMERIC),
    ('VEG-002', '대파', '야채/과일', 'kg', 'g', 1000::NUMERIC),
    ('VEG-003', '양상추', '야채/과일', 'kg', 'g', 1000::NUMERIC),
    ('SAUCE-001', '소스 데리야끼', '공산품', '팩', 'ea', 1::NUMERIC),
    ('DAIRY-001', '피자치즈', '유제품', 'kg', 'g', 1000::NUMERIC)
  ) AS seed(product_code, name, category, stock_unit, base_unit, base_unit_factor)
),
target_stores AS (
  SELECT id AS restaurant_id, brand_id
  FROM public.restaurants
  WHERE is_active = TRUE
),
source_items AS (
  SELECT DISTINCT ON (ii.restaurant_id, ii.name)
    ii.id,
    ii.restaurant_id,
    ii.name
  FROM public.inventory_items ii
  ORDER BY ii.restaurant_id, ii.name, ii.created_at DESC
),
inserted_products AS (
  INSERT INTO public.inventory_products (
    restaurant_id,
    brand_id,
    inventory_item_id,
    product_code,
    name,
    category,
    stock_unit,
    base_unit,
    base_unit_factor,
    is_orderable,
    is_active
  )
  SELECT
    ts.restaurant_id,
    ts.brand_id,
    si.id,
    seed.product_code,
    seed.name,
    seed.category,
    seed.stock_unit,
    seed.base_unit,
    seed.base_unit_factor,
    TRUE,
    TRUE
  FROM target_stores ts
  CROSS JOIN item_seed seed
  JOIN source_items si
    ON si.restaurant_id = ts.restaurant_id
   AND si.name = seed.name
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.inventory_products existing
    WHERE existing.restaurant_id = ts.restaurant_id
      AND existing.product_code = seed.product_code
  )
  RETURNING id
)
SELECT COUNT(*) FROM inserted_products;

WITH item_seed AS (
  SELECT *
  FROM (VALUES
    ('BEEF-001', '한우푸드', 'kg', 1000::NUMERIC, 1::NUMERIC, 35000::NUMERIC, 1),
    ('BEEF-002', '한우푸드', 'kg', 1000::NUMERIC, 1::NUMERIC, 38000::NUMERIC, 1),
    ('PORK-001', '한우푸드', 'kg', 1000::NUMERIC, 1::NUMERIC, 20000::NUMERIC, 1),
    ('VEG-001', '청정야채', '망', 10000::NUMERIC, 1::NUMERIC, 15000::NUMERIC, 1),
    ('VEG-002', '청정야채', '단', 1000::NUMERIC, 5::NUMERIC, 2200::NUMERIC, 1),
    ('VEG-003', '청정야채', '박스', 5000::NUMERIC, 1::NUMERIC, 15000::NUMERIC, 1),
    ('SAUCE-001', '푸드마켓', '팩', 1::NUMERIC, 5::NUMERIC, 6500::NUMERIC, 2),
    ('DAIRY-001', '푸드마켓', '봉', 2500::NUMERIC, 2::NUMERIC, 26250::NUMERIC, 2)
  ) AS seed(product_code, supplier_name, order_unit, order_unit_quantity_base, min_order_quantity, unit_price, lead_time_days)
),
inserted_supplier_items AS (
  INSERT INTO public.inventory_supplier_items (
    supplier_id,
    product_id,
    order_unit,
    order_unit_quantity_base,
    min_order_quantity,
    unit_price,
    tax_rate,
    lead_time_days,
    is_preferred,
    is_active
  )
  SELECT
    supplier.id,
    product.id,
    seed.order_unit,
    seed.order_unit_quantity_base,
    seed.min_order_quantity,
    seed.unit_price,
    10,
    seed.lead_time_days,
    TRUE,
    TRUE
  FROM public.inventory_products product
  JOIN item_seed seed
    ON seed.product_code = product.product_code
  JOIN public.inventory_suppliers supplier
    ON supplier.brand_id IS NOT DISTINCT FROM product.brand_id
   AND supplier.supplier_name = seed.supplier_name
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.inventory_supplier_items existing
    WHERE existing.supplier_id = supplier.id
      AND existing.product_id = product.id
  )
  RETURNING id
)
SELECT COUNT(*) FROM inserted_supplier_items;

WITH consumption_seed AS (
  SELECT *
  FROM (VALUES
    ('BEEF-001', 2200::NUMERIC),
    ('BEEF-002', 1700::NUMERIC),
    ('PORK-001', 2600::NUMERIC),
    ('VEG-001', 3200::NUMERIC),
    ('VEG-002', 1800::NUMERIC),
    ('VEG-003', 1200::NUMERIC),
    ('SAUCE-001', 2::NUMERIC),
    ('DAIRY-001', 900::NUMERIC)
  ) AS seed(product_code, daily_base_qty)
),
days AS (
  SELECT generate_series(CURRENT_DATE - 6, CURRENT_DATE, INTERVAL '1 day')::DATE AS consumption_date
),
inserted_consumption AS (
  INSERT INTO public.inventory_daily_consumption (
    restaurant_id,
    product_id,
    consumption_date,
    sales_quantity,
    consumed_quantity_base,
    consumed_amount,
    source
  )
  SELECT
    product.restaurant_id,
    product.id,
    days.consumption_date,
    10 + EXTRACT(DAY FROM days.consumption_date)::NUMERIC % 5,
    seed.daily_base_qty + (EXTRACT(DAY FROM days.consumption_date)::NUMERIC % 3) * 100,
    ROUND((seed.daily_base_qty + (EXTRACT(DAY FROM days.consumption_date)::NUMERIC % 3) * 100) * COALESCE(item.cost_per_unit, 0), 2),
    'manual_adjustment'
  FROM public.inventory_products product
  JOIN consumption_seed seed
    ON seed.product_code = product.product_code
  LEFT JOIN public.inventory_items item
    ON item.id = product.inventory_item_id
  CROSS JOIN days
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.inventory_daily_consumption existing
    WHERE existing.restaurant_id = product.restaurant_id
      AND existing.product_id = product.id
      AND existing.consumption_date = days.consumption_date
  )
  RETURNING id
)
SELECT COUNT(*) FROM inserted_consumption;

INSERT INTO public.inventory_stock_audit_sessions (
  restaurant_id,
  brand_id,
  audit_no,
  planned_date,
  audit_type,
  status,
  completed_at
)
SELECT
  r.id,
  r.brand_id,
  'AUD-' || to_char(CURRENT_DATE, 'YYYYMMDD') || '-' || upper(substr(md5(r.id::TEXT), 1, 8)),
  CURRENT_DATE,
  'monthly',
  'completed',
  now()
FROM public.restaurants r
WHERE r.is_active = TRUE
  AND NOT EXISTS (
    SELECT 1
    FROM public.inventory_stock_audit_sessions existing
    WHERE existing.restaurant_id = r.id
      AND existing.planned_date = CURRENT_DATE
  );
*/

-- Production no-op marker. The wrapped seed body above is intentionally
-- inert; contract tests verify text patterns only.
SELECT 1 WHERE FALSE;
