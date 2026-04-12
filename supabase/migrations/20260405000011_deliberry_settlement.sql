-- ============================================================
-- DELIBERRY SETTLEMENT INTEGRATION
-- 2026-04-05
-- 3-Layer: external_sales → delivery_settlements → settlement_items
-- ============================================================

-- ============================================================
-- LAYER 1: EXTERNAL SALES — settlement_id 컬럼 추가
-- external_sales는 initial_schema에서 이미 생성됨
-- 여기서는 정산 연결용 컬럼만 추가
-- ============================================================
ALTER TABLE external_sales
  ADD COLUMN IF NOT EXISTS settlement_id UUID;

-- ============================================================
-- LAYER 2: DELIVERY SETTLEMENTS (2주 정산 헤더)
-- Deliberry가 INSERT, POS가 READ + status UPDATE (입금 확인)
-- ============================================================
CREATE TABLE IF NOT EXISTS delivery_settlements (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id     UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  source_system     TEXT NOT NULL CHECK (source_system IN ('deliberry')),

  -- 기간
  period_start      DATE NOT NULL,
  period_end        DATE NOT NULL,
  period_label      TEXT NOT NULL,  -- '2026-04-A' (1~15일), '2026-04-B' (16~말일)

  -- 합계
  gross_total       DECIMAL(12,2) NOT NULL CHECK (gross_total >= 0),
  total_deductions  DECIMAL(12,2) NOT NULL DEFAULT 0 CHECK (total_deductions >= 0),
  net_settlement    DECIMAL(12,2) NOT NULL,

  -- 상태
  status            TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','calculated','received','disputed','adjusted')),
  received_at       TIMESTAMPTZ,
  notes             TEXT,

  -- 감사
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT unique_settlement_period
    UNIQUE (restaurant_id, source_system, period_label)
);

-- ============================================================
-- LAYER 2-B: DELIVERY SETTLEMENT ITEMS (차감 항목, 무제한 확장)
-- item_type에 CHECK 없음 = 새 비용 항목 추가 시 migration 불필요
-- ============================================================
CREATE TABLE IF NOT EXISTS delivery_settlement_items (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  settlement_id     UUID NOT NULL REFERENCES delivery_settlements(id) ON DELETE CASCADE,

  item_type         TEXT NOT NULL,
  -- 현재:  'platform_commission', 'payment_fee'
  -- 예정:  'advertising', 'insight_report'
  -- 향후:  'promo_subsidy', 'delivery_subsidy', 'photo_service' 등

  amount            DECIMAL(12,2) NOT NULL CHECK (amount >= 0),
  description       TEXT,
  reference_rate    DECIMAL(5,4),   -- 비율 기반 항목: 0.0150 = 1.5%
  reference_base    DECIMAL(12,2),  -- 비율 적용 기준 금액

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_settlement_items_settlement
  ON delivery_settlement_items(settlement_id);

CREATE INDEX IF NOT EXISTS idx_settlement_items_type
  ON delivery_settlement_items(item_type);

-- ============================================================
-- FK: external_sales → delivery_settlements
-- ============================================================
ALTER TABLE external_sales
  ADD CONSTRAINT fk_external_sales_settlement
  FOREIGN KEY (settlement_id) REFERENCES delivery_settlements(id);

CREATE INDEX IF NOT EXISTS idx_external_sales_settlement
  ON external_sales(settlement_id);

-- ============================================================
-- RLS POLICIES
-- ============================================================

-- external_sales: 레스토랑 격리
ALTER TABLE external_sales ENABLE ROW LEVEL SECURITY;

CREATE POLICY external_sales_read ON external_sales
  FOR SELECT
  USING (
    is_super_admin()
    OR restaurant_id = get_user_restaurant_id()
  );

CREATE POLICY external_sales_insert ON external_sales
  FOR INSERT
  WITH CHECK (
    restaurant_id = get_user_restaurant_id()
  );

-- delivery_settlements: 레스토랑 격리
ALTER TABLE delivery_settlements ENABLE ROW LEVEL SECURITY;

CREATE POLICY delivery_settlements_read ON delivery_settlements
  FOR SELECT
  USING (
    is_super_admin()
    OR restaurant_id = get_user_restaurant_id()
  );

CREATE POLICY delivery_settlements_insert ON delivery_settlements
  FOR INSERT
  WITH CHECK (
    restaurant_id = get_user_restaurant_id()
  );

-- POS admin만 입금 확인 가능 (status → received)
CREATE POLICY delivery_settlements_confirm ON delivery_settlements
  FOR UPDATE
  USING (
    restaurant_id = get_user_restaurant_id()
    AND has_any_role(ARRAY['admin','super_admin'])
  )
  WITH CHECK (
    restaurant_id = get_user_restaurant_id()
  );

-- delivery_settlement_items: settlement 통해 간접 격리
ALTER TABLE delivery_settlement_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY settlement_items_read ON delivery_settlement_items
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM delivery_settlements ds
      WHERE ds.id = delivery_settlement_items.settlement_id
        AND (is_super_admin() OR ds.restaurant_id = get_user_restaurant_id())
    )
  );

CREATE POLICY settlement_items_insert ON delivery_settlement_items
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM delivery_settlements ds
      WHERE ds.id = delivery_settlement_items.settlement_id
        AND ds.restaurant_id = get_user_restaurant_id()
    )
  );

-- ============================================================
-- HELPER VIEW: 채널별 일매출 (POS 리포트용)
-- orders.sales_channel + payments.amount 기반
-- ============================================================
CREATE OR REPLACE VIEW v_daily_revenue_by_channel AS
SELECT
  COALESCE(pos.restaurant_id, del.restaurant_id) AS restaurant_id,
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
    o.restaurant_id,
    (p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS sale_date,
    SUM(CASE WHEN o.sales_channel = 'dine_in'  THEN p.amount ELSE 0 END) AS dine_in_revenue,
    COUNT(CASE WHEN o.sales_channel = 'dine_in'  THEN 1 END)             AS dine_in_orders,
    SUM(CASE WHEN o.sales_channel = 'takeaway' THEN p.amount ELSE 0 END) AS takeaway_revenue,
    COUNT(CASE WHEN o.sales_channel = 'takeaway' THEN 1 END)             AS takeaway_orders
  FROM orders o
  JOIN payments p ON p.order_id = o.id
  WHERE o.status = 'completed' AND p.is_revenue = true
  GROUP BY o.restaurant_id, (p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
) pos
FULL OUTER JOIN (
  SELECT
    restaurant_id,
    (completed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS sale_date,
    SUM(gross_amount) AS delivery_revenue,
    COUNT(*)          AS delivery_orders
  FROM external_sales
  WHERE is_revenue = true AND order_status = 'completed'
  GROUP BY restaurant_id, (completed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
) del
ON pos.restaurant_id = del.restaurant_id AND pos.sale_date = del.sale_date;

-- ============================================================
-- HELPER VIEW: 정산 요약 (POS 정산 화면용)
-- ============================================================
CREATE OR REPLACE VIEW v_settlement_summary AS
SELECT
  ds.id,
  ds.restaurant_id,
  ds.period_label,
  ds.period_start,
  ds.period_end,
  ds.gross_total,
  ds.total_deductions,
  ds.net_settlement,
  ds.status,
  ds.received_at,
  -- 차감 항목 JSON 배열
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
  -- 해당 기간 주문 수
  (SELECT COUNT(*) FROM external_sales es
   WHERE es.settlement_id = ds.id AND es.is_revenue = true
  ) AS order_count
FROM delivery_settlements ds;

-- ============================================================
-- VIEW RLS (뷰는 기반 테이블 RLS를 상속하므로 별도 불필요)
-- ============================================================
-- v_daily_revenue_by_channel: orders + external_sales RLS 상속
-- v_settlement_summary: delivery_settlements RLS 상속

-- ============================================================
-- DONE
-- ============================================================
