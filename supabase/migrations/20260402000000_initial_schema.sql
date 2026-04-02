-- ============================================================
-- GLOBOS POS SYSTEM - Initial Schema Migration
-- 2026-04-02
-- ============================================================

-- ============================================================
-- RESTAURANTS
-- ============================================================
CREATE TABLE IF NOT EXISTS restaurants (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name              TEXT NOT NULL,
  address           TEXT,
  slug              TEXT UNIQUE,
  operation_mode    TEXT NOT NULL DEFAULT 'standard'
                      CHECK (operation_mode IN ('standard','buffet','hybrid')),
  per_person_charge DECIMAL(12,2)
                      CHECK (
                        (operation_mode = 'standard' AND per_person_charge IS NULL)
                        OR (operation_mode IN ('buffet','hybrid')
                            AND per_person_charge IS NOT NULL
                            AND per_person_charge > 0)
                      ),
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- USERS
-- ============================================================
CREATE TABLE IF NOT EXISTS users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_id       UUID NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  role          TEXT NOT NULL
                  CHECK (role IN ('super_admin','admin','waiter','kitchen','cashier')),
  full_name     TEXT,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- TABLES (레스토랑 테이블)
-- ============================================================
CREATE TABLE IF NOT EXISTS tables (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  table_number  TEXT NOT NULL,
  seat_count    INT,
  status        TEXT NOT NULL DEFAULT 'available'
                  CHECK (status IN ('available','occupied')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (restaurant_id, table_number)
);

-- ============================================================
-- MENU CATEGORIES
-- ============================================================
CREATE TABLE IF NOT EXISTS menu_categories (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  sort_order    INT NOT NULL DEFAULT 0,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- MENU ITEMS
-- ============================================================
CREATE TABLE IF NOT EXISTS menu_items (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  category_id   UUID REFERENCES menu_categories(id) ON DELETE SET NULL,
  name          TEXT NOT NULL,
  description   TEXT,
  price         DECIMAL(12,2) NOT NULL CHECK (price >= 0),
  is_available  BOOLEAN NOT NULL DEFAULT TRUE,
  is_visible_public BOOLEAN NOT NULL DEFAULT FALSE,
  sort_order    INT NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- ORDERS
-- ============================================================
CREATE TABLE IF NOT EXISTS orders (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  table_id      UUID REFERENCES tables(id) ON DELETE SET NULL,
  sales_channel TEXT NOT NULL DEFAULT 'dine_in'
                  CHECK (sales_channel IN ('dine_in','takeaway','delivery')),
  status        TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','confirmed','serving','completed','cancelled')),
  guest_count   INT CHECK (guest_count IS NULL OR guest_count > 0),
  created_by    UUID REFERENCES auth.users(id),
  notes         TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- ORDER ITEMS
-- ============================================================
CREATE TABLE IF NOT EXISTS order_items (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  order_id      UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  menu_item_id  UUID REFERENCES menu_items(id) ON DELETE SET NULL,
  item_type     TEXT NOT NULL DEFAULT 'standard'
                  CHECK (item_type IN ('standard','buffet_base','a_la_carte')),
  label         TEXT,
  unit_price    DECIMAL(12,2) NOT NULL CHECK (unit_price >= 0),
  quantity      INT NOT NULL DEFAULT 1 CHECK (quantity > 0),
  status        TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','preparing','ready','served')),
  notes         TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- PAYMENTS
-- ============================================================
CREATE TABLE IF NOT EXISTS payments (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  order_id      UUID NOT NULL REFERENCES orders(id),
  amount        DECIMAL(12,2) NOT NULL CHECK (amount > 0),
  method        TEXT NOT NULL
                  CHECK (method IN ('cash','card','pay','service')),
  is_revenue    BOOLEAN NOT NULL DEFAULT TRUE,
  processed_by  UUID REFERENCES auth.users(id),
  notes         TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT unique_payment_per_order UNIQUE (order_id),
  CONSTRAINT service_payment_not_revenue
    CHECK (method != 'service' OR is_revenue = FALSE)
);

-- ============================================================
-- ATTENDANCE LOGS
-- ============================================================
CREATE TABLE IF NOT EXISTS attendance_logs (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type          TEXT NOT NULL CHECK (type IN ('clock_in','clock_out')),
  logged_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- INVENTORY ITEMS
-- ============================================================
CREATE TABLE IF NOT EXISTS inventory_items (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  quantity      DECIMAL(12,2) NOT NULL DEFAULT 0 CHECK (quantity >= 0),
  unit          TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- EXTERNAL SALES (Deliberry 배달 연동)
-- ============================================================
CREATE TABLE IF NOT EXISTS external_sales (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id     UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  source_system     TEXT NOT NULL CHECK (source_system IN ('deliberry')),
  external_order_id TEXT NOT NULL,
  sales_channel     TEXT NOT NULL DEFAULT 'delivery'
                      CHECK (sales_channel IN ('delivery')),
  gross_amount      DECIMAL(12,2) NOT NULL CHECK (gross_amount >= 0),
  discount_amount   DECIMAL(12,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  delivery_fee      DECIMAL(12,2) NOT NULL DEFAULT 0 CHECK (delivery_fee >= 0),
  net_amount        DECIMAL(12,2) NOT NULL CHECK (net_amount >= 0),
  currency          TEXT NOT NULL DEFAULT 'VND',
  order_status      TEXT NOT NULL
                      CHECK (order_status IN ('completed','cancelled','refunded','partially_refunded')),
  is_revenue        BOOLEAN NOT NULL DEFAULT TRUE,
  completed_at      TIMESTAMPTZ,
  payload           JSONB NOT NULL DEFAULT '{}',
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT unique_external_order UNIQUE (source_system, external_order_id)
);

-- ============================================================
-- PUBLIC PROJECTIONS (globos.world 노출용 뷰)
-- ============================================================
CREATE OR REPLACE VIEW public_restaurant_profiles AS
SELECT
  r.id,
  r.slug,
  r.name,
  r.address,
  r.operation_mode,
  r.per_person_charge,
  r.is_active,
  r.created_at
FROM restaurants r
WHERE r.is_active = TRUE;

CREATE OR REPLACE VIEW public_menu_items AS
SELECT
  mi.id           AS external_menu_item_id,
  mi.restaurant_id,
  r.slug          AS restaurant_slug,
  mc.name         AS category_name,
  mi.name,
  mi.description,
  mi.price,
  r.operation_mode
FROM menu_items mi
JOIN restaurants r ON r.id = mi.restaurant_id
LEFT JOIN menu_categories mc ON mc.id = mi.category_id
WHERE mi.is_available = TRUE
  AND mi.is_visible_public = TRUE;

-- ============================================================
-- RLS HELPER FUNCTIONS
-- ============================================================
CREATE OR REPLACE FUNCTION get_user_restaurant_id()
RETURNS UUID AS $$
  SELECT restaurant_id FROM users WHERE auth_id = auth.uid()
$$ LANGUAGE sql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION get_user_role()
RETURNS TEXT AS $$
  SELECT role FROM users WHERE auth_id = auth.uid()
$$ LANGUAGE sql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION has_any_role(required_roles TEXT[])
RETURNS BOOLEAN AS $$
  SELECT role = ANY(required_roles)
  FROM users WHERE auth_id = auth.uid()
$$ LANGUAGE sql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION is_super_admin()
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM users WHERE auth_id = auth.uid() AND role = 'super_admin'
  )
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
ALTER TABLE restaurants    ENABLE ROW LEVEL SECURITY;
ALTER TABLE users          ENABLE ROW LEVEL SECURITY;
ALTER TABLE tables         ENABLE ROW LEVEL SECURITY;
ALTER TABLE menu_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE menu_items     ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders         ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items    ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments       ENABLE ROW LEVEL SECURITY;
ALTER TABLE attendance_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE external_sales ENABLE ROW LEVEL SECURITY;

-- restaurants: super_admin 전체, 나머지 본인 레스토랑만
CREATE POLICY restaurants_policy ON restaurants
  USING (is_super_admin() OR id = get_user_restaurant_id());

-- users: super_admin 전체, 나머지 같은 레스토랑만
CREATE POLICY users_policy ON users
  USING (is_super_admin() OR restaurant_id = get_user_restaurant_id());

-- 나머지 테이블: 같은 레스토랑만 접근
CREATE POLICY tables_policy ON tables
  USING (restaurant_id = get_user_restaurant_id());

CREATE POLICY menu_categories_policy ON menu_categories
  USING (restaurant_id = get_user_restaurant_id());

CREATE POLICY menu_items_policy ON menu_items
  USING (restaurant_id = get_user_restaurant_id());

CREATE POLICY orders_policy ON orders
  USING (restaurant_id = get_user_restaurant_id());

CREATE POLICY order_items_policy ON order_items
  USING (restaurant_id = get_user_restaurant_id());

CREATE POLICY payments_policy ON payments
  USING (restaurant_id = get_user_restaurant_id());

CREATE POLICY attendance_logs_policy ON attendance_logs
  USING (restaurant_id = get_user_restaurant_id());

CREATE POLICY inventory_items_policy ON inventory_items
  USING (restaurant_id = get_user_restaurant_id());

CREATE POLICY external_sales_policy ON external_sales
  USING (restaurant_id = get_user_restaurant_id());

-- public views: anon 읽기 허용
GRANT SELECT ON public_restaurant_profiles TO anon;
GRANT SELECT ON public_menu_items TO anon;

-- ============================================================
-- INDEXES
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_users_auth_id ON users(auth_id);
CREATE INDEX IF NOT EXISTS idx_users_restaurant ON users(restaurant_id);
CREATE INDEX IF NOT EXISTS idx_tables_restaurant ON tables(restaurant_id);
CREATE INDEX IF NOT EXISTS idx_menu_items_restaurant ON menu_items(restaurant_id);
CREATE INDEX IF NOT EXISTS idx_menu_items_category ON menu_items(category_id);
CREATE INDEX IF NOT EXISTS idx_orders_restaurant ON orders(restaurant_id);
CREATE INDEX IF NOT EXISTS idx_orders_table ON orders(table_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(restaurant_id, status);
CREATE INDEX IF NOT EXISTS idx_order_items_order ON order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_payments_restaurant ON payments(restaurant_id);
CREATE INDEX IF NOT EXISTS idx_payments_order ON payments(order_id);
CREATE INDEX IF NOT EXISTS idx_attendance_user ON attendance_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_external_sales_restaurant ON external_sales(restaurant_id, completed_at);

-- ============================================================
-- CORE RPCs
-- ============================================================

-- create_order: 신규 주문 (standard)
CREATE OR REPLACE FUNCTION create_order(
  p_restaurant_id UUID,
  p_table_id      UUID,
  p_items         JSONB
) RETURNS orders AS $$
DECLARE
  v_table_status TEXT;
  v_order        orders;
BEGIN
  SELECT status INTO v_table_status
  FROM tables
  WHERE id = p_table_id AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF v_table_status = 'occupied' THEN
    RAISE EXCEPTION 'TABLE_ALREADY_OCCUPIED';
  END IF;

  INSERT INTO orders (restaurant_id, table_id, status, created_by)
  VALUES (p_restaurant_id, p_table_id, 'pending', auth.uid())
  RETURNING * INTO v_order;

  INSERT INTO order_items
    (order_id, menu_item_id, quantity, unit_price, restaurant_id, item_type)
  SELECT v_order.id,
         (item->>'menu_item_id')::UUID,
         (item->>'quantity')::INT,
         m.price,
         p_restaurant_id,
         'standard'
  FROM jsonb_array_elements(p_items) AS item
  JOIN menu_items m ON m.id = (item->>'menu_item_id')::UUID;

  UPDATE tables SET status = 'occupied', updated_at = now()
  WHERE id = p_table_id;

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- create_buffet_order: 신규 주문 (buffet/hybrid)
CREATE OR REPLACE FUNCTION create_buffet_order(
  p_restaurant_id UUID,
  p_table_id      UUID,
  p_guest_count   INT,
  p_extra_items   JSONB DEFAULT '[]'
) RETURNS orders AS $$
DECLARE
  v_table_status       TEXT;
  v_operation_mode     TEXT;
  v_per_person_charge  DECIMAL(12,2);
  v_order              orders;
BEGIN
  SELECT status INTO v_table_status
  FROM tables WHERE id = p_table_id AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF v_table_status = 'occupied' THEN
    RAISE EXCEPTION 'TABLE_ALREADY_OCCUPIED';
  END IF;

  SELECT operation_mode, per_person_charge
  INTO v_operation_mode, v_per_person_charge
  FROM restaurants WHERE id = p_restaurant_id;

  IF v_operation_mode NOT IN ('buffet','hybrid') THEN
    RAISE EXCEPTION 'OPERATION_MODE_MISMATCH';
  END IF;

  IF p_guest_count IS NULL OR p_guest_count < 1 THEN
    RAISE EXCEPTION 'BUFFET_GUEST_COUNT_REQUIRED';
  END IF;

  INSERT INTO orders (restaurant_id, table_id, status, created_by, guest_count)
  VALUES (p_restaurant_id, p_table_id, 'pending', auth.uid(), p_guest_count)
  RETURNING * INTO v_order;

  INSERT INTO order_items
    (order_id, restaurant_id, item_type, label, unit_price, quantity, status)
  VALUES
    (v_order.id, p_restaurant_id, 'buffet_base', '1인 고정 요금',
     v_per_person_charge, p_guest_count, 'served');

  IF jsonb_array_length(p_extra_items) > 0 THEN
    INSERT INTO order_items
      (order_id, menu_item_id, quantity, unit_price, restaurant_id, item_type)
    SELECT v_order.id,
           (item->>'menu_item_id')::UUID,
           (item->>'quantity')::INT,
           m.price,
           p_restaurant_id,
           'a_la_carte'
    FROM jsonb_array_elements(p_extra_items) AS item
    JOIN menu_items m ON m.id = (item->>'menu_item_id')::UUID;
  END IF;

  UPDATE tables SET status = 'occupied', updated_at = now()
  WHERE id = p_table_id;

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- add_items_to_order: 추가 주문
CREATE OR REPLACE FUNCTION add_items_to_order(
  p_order_id      UUID,
  p_restaurant_id UUID,
  p_items         JSONB
) RETURNS SETOF order_items AS $$
DECLARE
  v_order_status TEXT;
BEGIN
  SELECT status INTO v_order_status
  FROM orders
  WHERE id = p_order_id AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF v_order_status IN ('completed','cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_PAYABLE';
  END IF;

  RETURN QUERY
  INSERT INTO order_items
    (order_id, menu_item_id, quantity, unit_price, restaurant_id, item_type)
  SELECT p_order_id,
         (item->>'menu_item_id')::UUID,
         (item->>'quantity')::INT,
         m.price,
         p_restaurant_id,
         'standard'
  FROM jsonb_array_elements(p_items) AS item
  JOIN menu_items m ON m.id = (item->>'menu_item_id')::UUID
  RETURNING *;

  UPDATE orders SET updated_at = now() WHERE id = p_order_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- process_payment: 결제 + 테이블 해제
CREATE OR REPLACE FUNCTION process_payment(
  p_order_id      UUID,
  p_restaurant_id UUID,
  p_amount        DECIMAL(12,2),
  p_method        TEXT
) RETURNS payments AS $$
DECLARE
  v_payment    payments;
  v_table_id   UUID;
  v_is_revenue BOOLEAN;
BEGIN
  IF EXISTS (SELECT 1 FROM payments WHERE order_id = p_order_id) THEN
    RAISE EXCEPTION 'PAYMENT_ALREADY_EXISTS';
  END IF;

  v_is_revenue := (p_method != 'service');

  INSERT INTO payments
    (order_id, restaurant_id, amount, method, processed_by, is_revenue)
  VALUES
    (p_order_id, p_restaurant_id, p_amount, p_method, auth.uid(), v_is_revenue)
  RETURNING * INTO v_payment;

  UPDATE orders SET status = 'completed', updated_at = now()
  WHERE id = p_order_id
  RETURNING table_id INTO v_table_id;

  IF v_table_id IS NOT NULL THEN
    UPDATE tables SET status = 'available', updated_at = now()
    WHERE id = v_table_id;
  END IF;

  RETURN v_payment;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- COMMENTS
-- ============================================================
COMMENT ON TABLE restaurants    IS 'F&B 레스토랑 테넌트';
COMMENT ON TABLE users          IS 'POS 사용자 (Supabase Auth 연동)';
COMMENT ON TABLE tables         IS '레스토랑 테이블';
COMMENT ON TABLE menu_categories IS '메뉴 카테고리';
COMMENT ON TABLE menu_items     IS '메뉴 아이템 (가격 포함)';
COMMENT ON TABLE orders         IS '주문 (dine_in/takeaway)';
COMMENT ON TABLE order_items    IS '주문 아이템 (가격 스냅샷)';
COMMENT ON TABLE payments       IS '결제 내역';
COMMENT ON TABLE attendance_logs IS '스태프 근태 기록';
COMMENT ON TABLE inventory_items IS '재고 항목';
COMMENT ON TABLE external_sales IS 'Deliberry 배달 매출 연동';
