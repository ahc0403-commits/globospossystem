-- ============================================================
-- Inventory Purchase + Office Review Contracts
-- 2026-05-06
--
-- Scope:
-- - New inventory-based purchase domain, separate from existing Office purchases
-- - Supplier/product/order/receipt/recommendation/stock-audit contracts
-- - Office review RPCs for list/detail/update/approve/return/reject/cancel
-- - Store-scoped RLS using user_accessible_stores(auth.uid())
--
-- Non-goals:
-- - Do not change existing general Office purchase flows
-- - Do not rename restaurants or restaurant_id physical columns
-- - Do not apply stock on Office approval; stock changes only on receipt
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.can_access_inventory_purchase_store(
  p_store_id UUID
) RETURNS BOOLEAN AS $$
BEGIN
  IF p_store_id IS NULL THEN
    RETURN FALSE;
  END IF;

  IF auth.role() = 'service_role' THEN
    RETURN TRUE;
  END IF;

  IF public.has_any_role(ARRAY['super_admin']) THEN
    RETURN TRUE;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(auth.uid()) s(store_id)
    WHERE s.store_id = p_store_id
  ) THEN
    RETURN TRUE;
  END IF;

  RETURN FALSE;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.can_office_review_inventory_purchase_store(
  p_store_id UUID
) RETURNS BOOLEAN AS $$
BEGIN
  IF p_store_id IS NULL THEN
    RETURN FALSE;
  END IF;

  IF auth.role() = 'service_role' THEN
    RETURN TRUE;
  END IF;

  IF public.has_any_role(ARRAY['super_admin']) THEN
    RETURN TRUE;
  END IF;

  RETURN FALSE;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth;

-- ─────────────────────────────────────────────────────────────
-- Master data
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.inventory_suppliers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  brand_id UUID REFERENCES public.brands(id),
  supplier_name TEXT NOT NULL,
  supplier_type TEXT,
  contact_name TEXT,
  phone TEXT,
  email TEXT,
  address TEXT,
  business_registration_no TEXT,
  payment_terms TEXT,
  contract_start_date DATE,
  contract_end_date DATE,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'suspended')),
  memo TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.inventory_products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  brand_id UUID REFERENCES public.brands(id),
  inventory_item_id UUID REFERENCES public.inventory_items(id) ON DELETE SET NULL,
  product_code TEXT,
  name TEXT NOT NULL,
  category TEXT,
  stock_unit TEXT NOT NULL DEFAULT 'kg',
  base_unit TEXT NOT NULL DEFAULT 'g' CHECK (base_unit IN ('g', 'ml', 'ea')),
  base_unit_factor NUMERIC(12,3) NOT NULL DEFAULT 1000 CHECK (base_unit_factor > 0),
  image_url TEXT,
  storage_type TEXT,
  shelf_life_days INT CHECK (shelf_life_days IS NULL OR shelf_life_days >= 0),
  is_orderable BOOLEAN NOT NULL DEFAULT TRUE,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (restaurant_id, product_code)
);

CREATE TABLE IF NOT EXISTS public.inventory_supplier_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_id UUID NOT NULL REFERENCES public.inventory_suppliers(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.inventory_products(id) ON DELETE CASCADE,
  supplier_sku TEXT,
  order_unit TEXT NOT NULL,
  order_unit_quantity_base NUMERIC(12,3) NOT NULL CHECK (order_unit_quantity_base > 0),
  min_order_quantity NUMERIC(12,3) NOT NULL DEFAULT 1 CHECK (min_order_quantity > 0),
  unit_price NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (unit_price >= 0),
  tax_rate NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (tax_rate >= 0),
  lead_time_days INT NOT NULL DEFAULT 1 CHECK (lead_time_days >= 0),
  is_preferred BOOLEAN NOT NULL DEFAULT FALSE,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (supplier_id, product_id, order_unit)
);

-- ─────────────────────────────────────────────────────────────
-- Purchase order and receipt
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.inventory_purchase_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_order_no TEXT NOT NULL UNIQUE,
  restaurant_id UUID NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  brand_id UUID REFERENCES public.brands(id),
  supplier_id UUID NOT NULL REFERENCES public.inventory_suppliers(id),
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'submitted', 'office_approved', 'office_returned', 'office_rejected', 'ordered', 'partially_received', 'received', 'cancelled')),
  order_type TEXT NOT NULL DEFAULT 'recommended' CHECK (order_type IN ('recommended', 'manual', 'repeat')),
  source TEXT NOT NULL DEFAULT 'pos' CHECK (source IN ('pos', 'mobile', 'office')),
  requested_delivery_date DATE,
  ordered_at TIMESTAMPTZ,
  submitted_by UUID REFERENCES auth.users(id),
  office_reviewed_by UUID REFERENCES auth.users(id),
  office_reviewed_at TIMESTAMPTZ,
  office_rejection_reason TEXT,
  office_review_comment TEXT,
  total_supply_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
  tax_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
  total_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
  pdf_url TEXT,
  memo TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.inventory_purchase_order_lines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_order_id UUID NOT NULL REFERENCES public.inventory_purchase_orders(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.inventory_products(id),
  supplier_item_id UUID REFERENCES public.inventory_supplier_items(id),
  recommended_quantity_base NUMERIC(12,3) NOT NULL DEFAULT 0 CHECK (recommended_quantity_base >= 0),
  ordered_quantity_base NUMERIC(12,3) NOT NULL DEFAULT 0 CHECK (ordered_quantity_base >= 0),
  ordered_quantity_unit NUMERIC(12,3) NOT NULL DEFAULT 0 CHECK (ordered_quantity_unit >= 0),
  order_unit TEXT NOT NULL,
  unit_price NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (unit_price >= 0),
  supply_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (supply_amount >= 0),
  tax_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
  memo TEXT,
  recommendation_snapshot JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.inventory_receipts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_order_id UUID NOT NULL REFERENCES public.inventory_purchase_orders(id) ON DELETE CASCADE,
  restaurant_id UUID NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  supplier_id UUID NOT NULL REFERENCES public.inventory_suppliers(id),
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  received_by UUID REFERENCES auth.users(id),
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'confirmed', 'cancelled')),
  memo TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.inventory_receipt_lines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id UUID NOT NULL REFERENCES public.inventory_receipts(id) ON DELETE CASCADE,
  purchase_order_line_id UUID REFERENCES public.inventory_purchase_order_lines(id) ON DELETE SET NULL,
  product_id UUID NOT NULL REFERENCES public.inventory_products(id),
  received_quantity_base NUMERIC(12,3) NOT NULL DEFAULT 0 CHECK (received_quantity_base >= 0),
  accepted_quantity_base NUMERIC(12,3) NOT NULL DEFAULT 0 CHECK (accepted_quantity_base >= 0),
  rejected_quantity_base NUMERIC(12,3) NOT NULL DEFAULT 0 CHECK (rejected_quantity_base >= 0),
  memo TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ─────────────────────────────────────────────────────────────
-- Recommendation and stock audit
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.inventory_daily_consumption (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  brand_id UUID REFERENCES public.brands(id),
  product_id UUID NOT NULL REFERENCES public.inventory_products(id) ON DELETE CASCADE,
  consumption_date DATE NOT NULL,
  sales_quantity NUMERIC(12,3) NOT NULL DEFAULT 0,
  consumed_quantity_base NUMERIC(12,3) NOT NULL DEFAULT 0,
  consumed_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT 'pos' CHECK (source IN ('pos', 'daily_close', 'manual_adjustment')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (restaurant_id, product_id, consumption_date, source)
);

CREATE TABLE IF NOT EXISTS public.inventory_recommendation_runs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  brand_id UUID REFERENCES public.brands(id),
  run_date DATE NOT NULL DEFAULT CURRENT_DATE,
  target_stock_days NUMERIC(8,2) NOT NULL DEFAULT 3 CHECK (target_stock_days > 0),
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.inventory_recommendation_lines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id UUID NOT NULL REFERENCES public.inventory_recommendation_runs(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.inventory_products(id),
  supplier_id UUID REFERENCES public.inventory_suppliers(id),
  current_stock_base NUMERIC(12,3) NOT NULL DEFAULT 0,
  avg_daily_consumption_base NUMERIC(12,3) NOT NULL DEFAULT 0,
  target_stock_days NUMERIC(8,2) NOT NULL DEFAULT 3,
  recommended_quantity_base NUMERIC(12,3) NOT NULL DEFAULT 0,
  recommended_order_units NUMERIC(12,3) NOT NULL DEFAULT 0,
  estimated_days_remaining NUMERIC(8,2),
  risk_status TEXT NOT NULL DEFAULT 'stable' CHECK (risk_status IN ('danger', 'warning', 'normal', 'stable')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.inventory_stock_audit_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  brand_id UUID REFERENCES public.brands(id),
  audit_no TEXT NOT NULL UNIQUE,
  audit_type TEXT NOT NULL DEFAULT 'daily' CHECK (audit_type IN ('daily', 'weekly', 'monthly', 'ad_hoc')),
  status TEXT NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'in_progress', 'completed', 'cancelled')),
  planned_date DATE,
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  created_by UUID REFERENCES auth.users(id),
  assigned_to UUID REFERENCES auth.users(id),
  memo TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.inventory_stock_audit_lines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES public.inventory_stock_audit_sessions(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.inventory_products(id),
  theoretical_quantity_base NUMERIC(12,3) NOT NULL DEFAULT 0,
  actual_quantity_base NUMERIC(12,3),
  variance_quantity_base NUMERIC(12,3),
  variance_amount NUMERIC(12,2),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'counted', 'skipped')),
  photo_url TEXT,
  memo TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ─────────────────────────────────────────────────────────────
-- Indexes
-- ─────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_inventory_suppliers_brand ON public.inventory_suppliers(brand_id);
CREATE INDEX IF NOT EXISTS idx_inventory_products_store ON public.inventory_products(restaurant_id);
CREATE INDEX IF NOT EXISTS idx_inventory_products_brand ON public.inventory_products(brand_id);
CREATE INDEX IF NOT EXISTS idx_inventory_supplier_items_supplier ON public.inventory_supplier_items(supplier_id);
CREATE INDEX IF NOT EXISTS idx_inventory_supplier_items_product ON public.inventory_supplier_items(product_id);
CREATE INDEX IF NOT EXISTS idx_inventory_po_store_status ON public.inventory_purchase_orders(restaurant_id, status);
CREATE INDEX IF NOT EXISTS idx_inventory_po_brand_status ON public.inventory_purchase_orders(brand_id, status);
CREATE INDEX IF NOT EXISTS idx_inventory_po_supplier ON public.inventory_purchase_orders(supplier_id);
CREATE INDEX IF NOT EXISTS idx_inventory_po_lines_order ON public.inventory_purchase_order_lines(purchase_order_id);
CREATE INDEX IF NOT EXISTS idx_inventory_receipts_order ON public.inventory_receipts(purchase_order_id);
CREATE INDEX IF NOT EXISTS idx_inventory_daily_consumption_store_date ON public.inventory_daily_consumption(restaurant_id, consumption_date);
CREATE INDEX IF NOT EXISTS idx_inventory_daily_consumption_product_date ON public.inventory_daily_consumption(product_id, consumption_date);
CREATE INDEX IF NOT EXISTS idx_inventory_reco_runs_store_date ON public.inventory_recommendation_runs(restaurant_id, run_date);
CREATE INDEX IF NOT EXISTS idx_inventory_audit_sessions_store_status ON public.inventory_stock_audit_sessions(restaurant_id, status);

-- ─────────────────────────────────────────────────────────────
-- RLS
-- ─────────────────────────────────────────────────────────────

ALTER TABLE public.inventory_suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_supplier_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_purchase_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_purchase_order_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_receipt_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_daily_consumption ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_recommendation_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_recommendation_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_stock_audit_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_stock_audit_lines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS inventory_products_store_read ON public.inventory_products;
CREATE POLICY inventory_products_store_read
ON public.inventory_products
FOR SELECT
TO authenticated
USING (public.can_access_inventory_purchase_store(restaurant_id));

DROP POLICY IF EXISTS inventory_purchase_orders_store_read ON public.inventory_purchase_orders;
CREATE POLICY inventory_purchase_orders_store_read
ON public.inventory_purchase_orders
FOR SELECT
TO authenticated
USING (public.can_access_inventory_purchase_store(restaurant_id));

DROP POLICY IF EXISTS inventory_purchase_order_lines_store_read ON public.inventory_purchase_order_lines;
CREATE POLICY inventory_purchase_order_lines_store_read
ON public.inventory_purchase_order_lines
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.inventory_purchase_orders po
    WHERE po.id = inventory_purchase_order_lines.purchase_order_id
      AND public.can_access_inventory_purchase_store(po.restaurant_id)
  )
);

DROP POLICY IF EXISTS inventory_receipts_store_read ON public.inventory_receipts;
CREATE POLICY inventory_receipts_store_read
ON public.inventory_receipts
FOR SELECT
TO authenticated
USING (public.can_access_inventory_purchase_store(restaurant_id));

DROP POLICY IF EXISTS inventory_receipt_lines_store_read ON public.inventory_receipt_lines;
CREATE POLICY inventory_receipt_lines_store_read
ON public.inventory_receipt_lines
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.inventory_receipts ir
    WHERE ir.id = inventory_receipt_lines.receipt_id
      AND public.can_access_inventory_purchase_store(ir.restaurant_id)
  )
);

DROP POLICY IF EXISTS inventory_recommendation_runs_store_read ON public.inventory_recommendation_runs;
DROP POLICY IF EXISTS inventory_daily_consumption_store_read ON public.inventory_daily_consumption;
CREATE POLICY inventory_daily_consumption_store_read
ON public.inventory_daily_consumption
FOR SELECT
TO authenticated
USING (public.can_access_inventory_purchase_store(restaurant_id));

CREATE POLICY inventory_recommendation_runs_store_read
ON public.inventory_recommendation_runs
FOR SELECT
TO authenticated
USING (public.can_access_inventory_purchase_store(restaurant_id));

DROP POLICY IF EXISTS inventory_recommendation_lines_store_read ON public.inventory_recommendation_lines;
CREATE POLICY inventory_recommendation_lines_store_read
ON public.inventory_recommendation_lines
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.inventory_recommendation_runs rr
    WHERE rr.id = inventory_recommendation_lines.run_id
      AND public.can_access_inventory_purchase_store(rr.restaurant_id)
  )
);

DROP POLICY IF EXISTS inventory_stock_audit_sessions_store_read ON public.inventory_stock_audit_sessions;
CREATE POLICY inventory_stock_audit_sessions_store_read
ON public.inventory_stock_audit_sessions
FOR SELECT
TO authenticated
USING (public.can_access_inventory_purchase_store(restaurant_id));

DROP POLICY IF EXISTS inventory_stock_audit_lines_store_read ON public.inventory_stock_audit_lines;
CREATE POLICY inventory_stock_audit_lines_store_read
ON public.inventory_stock_audit_lines
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.inventory_stock_audit_sessions s
    WHERE s.id = inventory_stock_audit_lines.session_id
      AND public.can_access_inventory_purchase_store(s.restaurant_id)
  )
);

DROP POLICY IF EXISTS inventory_suppliers_authenticated_read ON public.inventory_suppliers;
DROP POLICY IF EXISTS inventory_suppliers_scoped_read ON public.inventory_suppliers;
CREATE POLICY inventory_suppliers_scoped_read
ON public.inventory_suppliers
FOR SELECT
TO authenticated
USING (
  auth.role() = 'service_role'
  OR public.has_any_role(ARRAY['super_admin'])
  OR EXISTS (
    SELECT 1
    FROM public.restaurants r
    WHERE r.brand_id = inventory_suppliers.brand_id
      AND public.can_access_inventory_purchase_store(r.id)
  )
);

DROP POLICY IF EXISTS inventory_supplier_items_authenticated_read ON public.inventory_supplier_items;
DROP POLICY IF EXISTS inventory_supplier_items_scoped_read ON public.inventory_supplier_items;
CREATE POLICY inventory_supplier_items_scoped_read
ON public.inventory_supplier_items
FOR SELECT
TO authenticated
USING (
  auth.role() = 'service_role'
  OR public.has_any_role(ARRAY['super_admin'])
  OR EXISTS (
    SELECT 1
    FROM public.inventory_products ip
    JOIN public.inventory_suppliers s
      ON s.id = inventory_supplier_items.supplier_id
    WHERE ip.id = inventory_supplier_items.product_id
      AND (s.brand_id IS NULL OR s.brand_id = ip.brand_id)
      AND public.can_access_inventory_purchase_store(ip.restaurant_id)
  )
);

-- ─────────────────────────────────────────────────────────────
-- Recommendation RPCs
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_inventory_stock_status(
  p_store_id UUID,
  p_as_of_date DATE DEFAULT CURRENT_DATE
) RETURNS TABLE (
  product_id UUID,
  product_name TEXT,
  category TEXT,
  stock_unit TEXT,
  base_unit TEXT,
  current_stock_base NUMERIC(12,3),
  current_stock_display NUMERIC(12,3),
  recent_4_day_avg NUMERIC(12,3),
  recent_7_day_avg NUMERIC(12,3),
  avg_daily_consumption_base NUMERIC(12,3),
  estimated_days_remaining NUMERIC(8,2),
  risk_status TEXT
) AS $$
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;

  RETURN QUERY
  WITH consumption AS (
    SELECT
      ip.id AS product_id,
      COALESCE(SUM(idc.consumed_quantity_base) FILTER (
        WHERE idc.consumption_date > p_as_of_date - 4
          AND idc.consumption_date <= p_as_of_date
      ), 0) / 4.0 AS recent_4_day_avg,
      COALESCE(SUM(idc.consumed_quantity_base) FILTER (
        WHERE idc.consumption_date > p_as_of_date - 7
          AND idc.consumption_date <= p_as_of_date
      ), 0) / 7.0 AS recent_7_day_avg
    FROM public.inventory_products ip
    LEFT JOIN public.inventory_daily_consumption idc
      ON idc.product_id = ip.id
     AND idc.restaurant_id = ip.restaurant_id
     AND idc.consumption_date > p_as_of_date - 7
     AND idc.consumption_date <= p_as_of_date
    WHERE ip.restaurant_id = p_store_id
      AND ip.is_active = TRUE
    GROUP BY ip.id
  ), stock AS (
    SELECT
      ip.id,
      ip.name,
      ip.category,
      ip.stock_unit,
      ip.base_unit,
      ip.base_unit_factor,
      COALESCE(ii.current_stock, 0) AS current_stock_base,
      c.recent_4_day_avg,
      c.recent_7_day_avg,
      -- Recommendation formula: recent_4_day_avg * 0.7 + recent_7_day_avg * 0.3
      (c.recent_4_day_avg * 0.7 + c.recent_7_day_avg * 0.3) AS avg_daily_consumption_base
    FROM public.inventory_products ip
    LEFT JOIN public.inventory_items ii
      ON ii.id = ip.inventory_item_id
     AND ii.restaurant_id = ip.restaurant_id
    JOIN consumption c
      ON c.product_id = ip.id
    WHERE ip.restaurant_id = p_store_id
      AND ip.is_active = TRUE
  )
  SELECT
    stock.id AS product_id,
    stock.name AS product_name,
    stock.category,
    stock.stock_unit,
    stock.base_unit,
    stock.current_stock_base,
    ROUND(stock.current_stock_base / NULLIF(stock.base_unit_factor, 0), 3) AS current_stock_display,
    ROUND(stock.recent_4_day_avg, 3) AS recent_4_day_avg,
    ROUND(stock.recent_7_day_avg, 3) AS recent_7_day_avg,
    ROUND(stock.avg_daily_consumption_base, 3) AS avg_daily_consumption_base,
    CASE
      WHEN stock.avg_daily_consumption_base <= 0 THEN NULL
      ELSE ROUND(stock.current_stock_base / stock.avg_daily_consumption_base, 2)
    END AS estimated_days_remaining,
    CASE
      WHEN stock.avg_daily_consumption_base <= 0 THEN 'stable'
      WHEN stock.current_stock_base / stock.avg_daily_consumption_base < 2 THEN 'danger'
      WHEN stock.current_stock_base / stock.avg_daily_consumption_base < 4 THEN 'warning'
      WHEN stock.current_stock_base / stock.avg_daily_consumption_base < 7 THEN 'normal'
      ELSE 'stable'
    END AS risk_status
  FROM stock
  ORDER BY risk_status, product_name;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.get_inventory_purchase_dashboard(
  p_store_id UUID DEFAULT NULL,
  p_brand_id UUID DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_scope_store_ids UUID[];
  v_total_inventory_amount NUMERIC(12,2);
  v_submitted_purchase_amount NUMERIC(12,2);
  v_approved_purchase_amount NUMERIC(12,2);
  v_low_stock_count INT;
BEGIN
  SELECT ARRAY_AGG(r.id)
  INTO v_scope_store_ids
  FROM public.restaurants r
  WHERE (p_store_id IS NULL OR r.id = p_store_id)
    AND (p_brand_id IS NULL OR r.brand_id = p_brand_id)
    AND public.can_access_inventory_purchase_store(r.id);

  IF v_scope_store_ids IS NULL OR array_length(v_scope_store_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;

  SELECT COALESCE(SUM(COALESCE(ii.current_stock, 0) * COALESCE(ii.cost_per_unit, 0)), 0)
  INTO v_total_inventory_amount
  FROM public.inventory_products ip
  LEFT JOIN public.inventory_items ii
    ON ii.id = ip.inventory_item_id
   AND ii.restaurant_id = ip.restaurant_id
  WHERE ip.restaurant_id = ANY(v_scope_store_ids)
    AND ip.is_active = TRUE;

  SELECT COALESCE(SUM(total_amount) FILTER (WHERE status = 'submitted'), 0),
         COALESCE(SUM(total_amount) FILTER (WHERE status = 'office_approved'), 0)
  INTO v_submitted_purchase_amount, v_approved_purchase_amount
  FROM public.inventory_purchase_orders
  WHERE restaurant_id = ANY(v_scope_store_ids);

  SELECT COUNT(*)::INT
  INTO v_low_stock_count
  FROM unnest(v_scope_store_ids) AS scoped(store_id)
  CROSS JOIN LATERAL public.get_inventory_stock_status(scoped.store_id, CURRENT_DATE) status
  WHERE status.risk_status IN ('danger', 'warning');

  RETURN jsonb_build_object(
    'store_count', array_length(v_scope_store_ids, 1),
    'total_inventory_amount', v_total_inventory_amount,
    'submitted_purchase_amount', v_submitted_purchase_amount,
    'approved_purchase_amount', v_approved_purchase_amount,
    'low_stock_count', v_low_stock_count
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.run_inventory_purchase_recommendation(
  p_store_id UUID,
  p_target_stock_days NUMERIC DEFAULT 3,
  p_as_of_date DATE DEFAULT CURRENT_DATE
) RETURNS UUID AS $$
DECLARE
  v_brand_id UUID;
  v_run_id UUID;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;

  IF p_target_stock_days IS NULL OR p_target_stock_days <= 0 THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_TARGET_DAYS_INVALID';
  END IF;

  SELECT brand_id
  INTO v_brand_id
  FROM public.restaurants
  WHERE id = p_store_id;

  INSERT INTO public.inventory_recommendation_runs (
    restaurant_id,
    brand_id,
    run_date,
    target_stock_days,
    created_by
  )
  VALUES (
    p_store_id,
    v_brand_id,
    p_as_of_date,
    p_target_stock_days,
    auth.uid()
  )
  RETURNING id INTO v_run_id;

  INSERT INTO public.inventory_recommendation_lines (
    run_id,
    product_id,
    supplier_id,
    current_stock_base,
    avg_daily_consumption_base,
    target_stock_days,
    recommended_quantity_base,
    recommended_order_units,
    estimated_days_remaining,
    risk_status
  )
  SELECT
    v_run_id,
    status.product_id,
    supplier_pick.supplier_id,
    status.current_stock_base,
    status.avg_daily_consumption_base,
    p_target_stock_days,
    GREATEST(0, ROUND((p_target_stock_days * status.avg_daily_consumption_base) - status.current_stock_base, 3)) AS recommended_quantity_base,
    CASE
      WHEN supplier_pick.order_unit_quantity_base IS NULL THEN 0
      ELSE GREATEST(
        COALESCE(supplier_pick.min_order_quantity, 1),
        CEIL(
          GREATEST(0, (p_target_stock_days * status.avg_daily_consumption_base) - status.current_stock_base)
          / supplier_pick.order_unit_quantity_base
        )
      )
    END AS recommended_order_units,
    status.estimated_days_remaining,
    status.risk_status
  FROM public.get_inventory_stock_status(p_store_id, p_as_of_date) status
  LEFT JOIN LATERAL (
    SELECT
      isi.supplier_id,
      isi.order_unit_quantity_base,
      isi.min_order_quantity
    FROM public.inventory_supplier_items isi
    WHERE isi.product_id = status.product_id
      AND isi.is_active = TRUE
    ORDER BY isi.is_preferred DESC, isi.updated_at DESC
    LIMIT 1
  ) supplier_pick ON TRUE
  WHERE status.avg_daily_consumption_base > 0;

  RETURN v_run_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.create_purchase_orders_from_recommendation(
  p_run_id UUID,
  p_requested_delivery_date DATE DEFAULT NULL
) RETURNS SETOF public.inventory_purchase_orders AS $$
DECLARE
  v_run public.inventory_recommendation_runs%ROWTYPE;
  v_supplier_id UUID;
  v_order public.inventory_purchase_orders%ROWTYPE;
BEGIN
  SELECT *
  INTO v_run
  FROM public.inventory_recommendation_runs
  WHERE id = p_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECOMMENDATION_RUN_NOT_FOUND';
  END IF;

  IF NOT public.can_access_inventory_purchase_store(v_run.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;

  FOR v_supplier_id IN
    SELECT DISTINCT supplier_id
    FROM public.inventory_recommendation_lines
    WHERE run_id = p_run_id
      AND supplier_id IS NOT NULL
      AND recommended_order_units > 0
  LOOP
    INSERT INTO public.inventory_purchase_orders (
      purchase_order_no,
      restaurant_id,
      brand_id,
      supplier_id,
      status,
      order_type,
      source,
      requested_delivery_date,
      submitted_by
    )
    VALUES (
      'PO-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || upper(substr(replace(gen_random_uuid()::TEXT, '-', ''), 1, 6)),
      v_run.restaurant_id,
      v_run.brand_id,
      v_supplier_id,
      'submitted',
      'recommended',
      'pos',
      p_requested_delivery_date,
      auth.uid()
    )
    RETURNING * INTO v_order;

    INSERT INTO public.inventory_purchase_order_lines (
      purchase_order_id,
      product_id,
      supplier_item_id,
      recommended_quantity_base,
      ordered_quantity_base,
      ordered_quantity_unit,
      order_unit,
      unit_price,
      supply_amount,
      tax_amount,
      recommendation_snapshot
    )
    SELECT
      v_order.id,
      rl.product_id,
      isi.id,
      rl.recommended_quantity_base,
      rl.recommended_order_units * isi.order_unit_quantity_base,
      rl.recommended_order_units,
      isi.order_unit,
      isi.unit_price,
      ROUND(rl.recommended_order_units * isi.unit_price, 2),
      ROUND(rl.recommended_order_units * isi.unit_price * COALESCE(isi.tax_rate, 0) / 100, 2),
      jsonb_build_object(
        'run_id', p_run_id,
        'current_stock_base', rl.current_stock_base,
        'avg_daily_consumption_base', rl.avg_daily_consumption_base,
        'target_stock_days', rl.target_stock_days,
        'recommended_quantity_base', rl.recommended_quantity_base,
        'recommended_order_units', rl.recommended_order_units,
        'estimated_days_remaining', rl.estimated_days_remaining,
        'risk_status', rl.risk_status
      )
    FROM public.inventory_recommendation_lines rl
    JOIN public.inventory_supplier_items isi
      ON isi.product_id = rl.product_id
     AND isi.supplier_id = rl.supplier_id
     AND isi.is_active = TRUE
    WHERE rl.run_id = p_run_id
      AND rl.supplier_id = v_supplier_id
      AND rl.recommended_order_units > 0;

    PERFORM public.recalculate_inventory_purchase_order_totals(v_order.id);

    SELECT *
    INTO v_order
    FROM public.inventory_purchase_orders
    WHERE id = v_order.id;

    RETURN NEXT v_order;
  END LOOP;

  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ─────────────────────────────────────────────────────────────
-- Office RPCs
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.office_get_inventory_purchase_orders(
  p_brand_id UUID DEFAULT NULL,
  p_store_id UUID DEFAULT NULL,
  p_status TEXT DEFAULT NULL
) RETURNS TABLE (
  id UUID,
  purchase_order_no TEXT,
  restaurant_id UUID,
  brand_id UUID,
  supplier_id UUID,
  supplier_name TEXT,
  status TEXT,
  requested_delivery_date DATE,
  total_supply_amount NUMERIC(12,2),
  tax_amount NUMERIC(12,2),
  total_amount NUMERIC(12,2),
  office_reviewed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    po.id,
    po.purchase_order_no,
    po.restaurant_id,
    po.brand_id,
    po.supplier_id,
    s.supplier_name,
    po.status,
    po.requested_delivery_date,
    po.total_supply_amount,
    po.tax_amount,
    po.total_amount,
    po.office_reviewed_at,
    po.created_at,
    po.updated_at
  FROM public.inventory_purchase_orders po
  JOIN public.inventory_suppliers s
    ON s.id = po.supplier_id
  WHERE public.can_access_inventory_purchase_store(po.restaurant_id)
    AND (p_brand_id IS NULL OR po.brand_id = p_brand_id)
    AND (p_store_id IS NULL OR po.restaurant_id = p_store_id)
    AND (p_status IS NULL OR po.status = p_status)
  ORDER BY po.created_at DESC, po.purchase_order_no DESC;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.office_get_inventory_purchase_order_detail(
  p_purchase_order_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_lines JSONB;
BEGIN
  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  IF NOT public.can_access_inventory_purchase_store(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_OFFICE_FORBIDDEN';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(line_row) ORDER BY line_row.created_at), '[]'::JSONB)
  INTO v_lines
  FROM (
    SELECT
      pol.id,
      pol.product_id,
      ip.name AS product_name,
      pol.supplier_item_id,
      pol.recommended_quantity_base,
      pol.ordered_quantity_base,
      pol.ordered_quantity_unit,
      pol.order_unit,
      pol.unit_price,
      pol.supply_amount,
      pol.tax_amount,
      pol.memo,
      pol.recommendation_snapshot,
      pol.created_at,
      pol.updated_at
    FROM public.inventory_purchase_order_lines pol
    JOIN public.inventory_products ip
      ON ip.id = pol.product_id
    WHERE pol.purchase_order_id = p_purchase_order_id
  ) line_row;

  RETURN jsonb_build_object(
    'order', to_jsonb(v_order),
    'lines', v_lines
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.recalculate_inventory_purchase_order_totals(
  p_purchase_order_id UUID
) RETURNS VOID AS $$
DECLARE
  v_supply NUMERIC(12,2);
  v_tax NUMERIC(12,2);
BEGIN
  SELECT
    COALESCE(SUM(supply_amount), 0),
    COALESCE(SUM(tax_amount), 0)
  INTO v_supply, v_tax
  FROM public.inventory_purchase_order_lines
  WHERE purchase_order_id = p_purchase_order_id;

  UPDATE public.inventory_purchase_orders
  SET total_supply_amount = v_supply,
      tax_amount = v_tax,
      total_amount = v_supply + v_tax,
      updated_at = now()
  WHERE id = p_purchase_order_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.office_update_inventory_purchase_order(
  p_purchase_order_id UUID,
  p_requested_delivery_date DATE DEFAULT NULL,
  p_memo TEXT DEFAULT NULL,
  p_office_review_comment TEXT DEFAULT NULL,
  p_lines JSONB DEFAULT '[]'::JSONB
) RETURNS public.inventory_purchase_orders AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_line JSONB;
  v_line_id UUID;
  v_ordered_quantity_base NUMERIC(12,3);
  v_line_memo TEXT;
  v_existing_line public.inventory_purchase_order_lines%ROWTYPE;
BEGIN
  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  IF NOT public.can_office_review_inventory_purchase_store(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_OFFICE_FORBIDDEN';
  END IF;

  IF v_order.status NOT IN ('submitted', 'office_returned') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_EDITABLE';
  END IF;

  UPDATE public.inventory_purchase_orders
  SET requested_delivery_date = COALESCE(p_requested_delivery_date, requested_delivery_date),
      memo = COALESCE(NULLIF(btrim(COALESCE(p_memo, '')), ''), memo),
      office_review_comment = COALESCE(NULLIF(btrim(COALESCE(p_office_review_comment, '')), ''), office_review_comment),
      updated_at = now()
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_order;

  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
      v_line_id := NULLIF(v_line->>'line_id', '')::UUID;
      v_ordered_quantity_base := NULLIF(v_line->>'ordered_quantity_base', '')::NUMERIC;
      v_line_memo := NULLIF(btrim(COALESCE(v_line->>'memo', '')), '');

      SELECT *
      INTO v_existing_line
      FROM public.inventory_purchase_order_lines
      WHERE id = v_line_id
        AND purchase_order_id = p_purchase_order_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'INVENTORY_PURCHASE_LINE_NOT_FOUND';
      END IF;

      IF v_ordered_quantity_base IS NULL OR v_ordered_quantity_base < 0 THEN
        RAISE EXCEPTION 'INVENTORY_PURCHASE_LINE_QUANTITY_INVALID';
      END IF;

      UPDATE public.inventory_purchase_order_lines
      SET ordered_quantity_base = v_ordered_quantity_base,
          ordered_quantity_unit = CASE
            WHEN v_existing_line.ordered_quantity_base = 0 THEN 0
            WHEN v_existing_line.ordered_quantity_unit = 0 THEN v_existing_line.ordered_quantity_unit
            ELSE ROUND(
              v_ordered_quantity_base
              / (v_existing_line.ordered_quantity_base / NULLIF(v_existing_line.ordered_quantity_unit, 0)),
              3
            )
          END,
          supply_amount = ROUND(v_ordered_quantity_base * v_existing_line.unit_price, 2),
          tax_amount = ROUND(v_ordered_quantity_base * v_existing_line.unit_price * 0, 2),
          memo = COALESCE(v_line_memo, memo),
          updated_at = now()
      WHERE id = v_line_id;
    END LOOP;
  END IF;

  PERFORM public.recalculate_inventory_purchase_order_totals(p_purchase_order_id);

  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id;

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.office_approve_inventory_purchase_order(
  p_purchase_order_id UUID,
  p_office_review_comment TEXT DEFAULT NULL
) RETURNS public.inventory_purchase_orders AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
BEGIN
  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  IF NOT public.can_office_review_inventory_purchase_store(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_OFFICE_FORBIDDEN';
  END IF;

  IF v_order.status NOT IN ('submitted', 'office_returned') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_EDITABLE';
  END IF;

  UPDATE public.inventory_purchase_orders
  SET status = 'office_approved',
      office_reviewed_by = auth.uid(),
      office_reviewed_at = now(),
      office_review_comment = NULLIF(btrim(COALESCE(p_office_review_comment, '')), ''),
      updated_at = now()
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_order;

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.office_return_inventory_purchase_order(
  p_purchase_order_id UUID,
  p_office_review_comment TEXT
) RETURNS public.inventory_purchase_orders AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
BEGIN
  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  IF NOT public.can_office_review_inventory_purchase_store(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_OFFICE_FORBIDDEN';
  END IF;

  IF v_order.status <> 'submitted' THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_EDITABLE';
  END IF;

  UPDATE public.inventory_purchase_orders
  SET status = 'office_returned',
      office_reviewed_by = auth.uid(),
      office_reviewed_at = now(),
      office_review_comment = NULLIF(btrim(COALESCE(p_office_review_comment, '')), ''),
      updated_at = now()
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_order;

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.office_reject_inventory_purchase_order(
  p_purchase_order_id UUID,
  p_office_rejection_reason TEXT
) RETURNS public.inventory_purchase_orders AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_reason TEXT := NULLIF(btrim(COALESCE(p_office_rejection_reason, '')), '');
BEGIN
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_REJECTION_REASON_REQUIRED';
  END IF;

  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  IF NOT public.can_office_review_inventory_purchase_store(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_OFFICE_FORBIDDEN';
  END IF;

  IF v_order.status NOT IN ('submitted', 'office_returned') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_EDITABLE';
  END IF;

  UPDATE public.inventory_purchase_orders
  SET status = 'office_rejected',
      office_reviewed_by = auth.uid(),
      office_reviewed_at = now(),
      office_rejection_reason = v_reason,
      updated_at = now()
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_order;

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.office_cancel_inventory_purchase_order(
  p_purchase_order_id UUID,
  p_office_review_comment TEXT DEFAULT NULL
) RETURNS public.inventory_purchase_orders AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
BEGIN
  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  IF NOT public.can_office_review_inventory_purchase_store(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_OFFICE_FORBIDDEN';
  END IF;

  IF v_order.status IN ('received', 'partially_received') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_EDITABLE';
  END IF;

  UPDATE public.inventory_purchase_orders
  SET status = 'cancelled',
      office_reviewed_by = auth.uid(),
      office_reviewed_at = now(),
      office_review_comment = NULLIF(btrim(COALESCE(p_office_review_comment, '')), ''),
      updated_at = now()
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_order;

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

GRANT EXECUTE ON FUNCTION public.office_get_inventory_purchase_orders(UUID, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.office_get_inventory_purchase_order_detail(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_inventory_purchase_dashboard(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_inventory_stock_status(UUID, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.run_inventory_purchase_recommendation(UUID, NUMERIC, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_purchase_orders_from_recommendation(UUID, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.office_update_inventory_purchase_order(UUID, DATE, TEXT, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.office_approve_inventory_purchase_order(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.office_return_inventory_purchase_order(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.office_reject_inventory_purchase_order(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.office_cancel_inventory_purchase_order(UUID, TEXT) TO authenticated;
