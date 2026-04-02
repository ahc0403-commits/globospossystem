-- ============================================================
-- PILOT DATA — 전체 화면 테스트용 v2
-- 2026-04-02
-- ============================================================
-- R1: aaaaaaaa-0000-0000-0000-000000000001 (GLOBOS Test Restaurant)

-- ============================================================
-- WAITER 화면: T01/T02/T03 occupied 상태
-- ============================================================
UPDATE tables SET status = 'occupied'
WHERE restaurant_id = 'aaaaaaaa-0000-0000-0000-000000000001'
  AND table_number IN ('T01','T02','T03');

-- ============================================================
-- KITCHEN 화면: T01 주문 (preparing/ready/pending 혼합)
-- ============================================================
INSERT INTO orders (id, restaurant_id, table_id, status, sales_channel, created_by)
SELECT '4197a376-b2ff-44b0-ad6e-69577dfaad83',
  'aaaaaaaa-0000-0000-0000-000000000001', t.id, 'confirmed', 'dine_in',
  (SELECT auth_id FROM users WHERE role='waiter' AND restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' LIMIT 1)
FROM tables t WHERE t.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND t.table_number='T01'
ON CONFLICT DO NOTHING;

INSERT INTO order_items (order_id, restaurant_id, menu_item_id, unit_price, quantity, status, item_type)
SELECT '4197a376-b2ff-44b0-ad6e-69577dfaad83','aaaaaaaa-0000-0000-0000-000000000001',mi.id,mi.price,2,'preparing','standard'
FROM menu_items mi WHERE mi.name='불고기밥' AND mi.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' ON CONFLICT DO NOTHING;

INSERT INTO order_items (order_id, restaurant_id, menu_item_id, unit_price, quantity, status, item_type)
SELECT '4197a376-b2ff-44b0-ad6e-69577dfaad83','aaaaaaaa-0000-0000-0000-000000000001',mi.id,mi.price,1,'ready','standard'
FROM menu_items mi WHERE mi.name='김치찌개' AND mi.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' ON CONFLICT DO NOTHING;

INSERT INTO order_items (order_id, restaurant_id, menu_item_id, unit_price, quantity, status, item_type)
SELECT '4197a376-b2ff-44b0-ad6e-69577dfaad83','aaaaaaaa-0000-0000-0000-000000000001',mi.id,mi.price,2,'pending','standard'
FROM menu_items mi WHERE mi.name='막걸리' AND mi.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' ON CONFLICT DO NOTHING;

-- T03 주문 (all pending — 신규 주문)
INSERT INTO orders (id, restaurant_id, table_id, status, sales_channel, created_by)
SELECT 'a32abd7a-f7f3-4d7c-a5dc-8c1ae4234aa8',
  'aaaaaaaa-0000-0000-0000-000000000001', t.id, 'pending', 'dine_in',
  (SELECT auth_id FROM users WHERE role='waiter' AND restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' LIMIT 1)
FROM tables t WHERE t.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND t.table_number='T03'
ON CONFLICT DO NOTHING;

INSERT INTO order_items (order_id, restaurant_id, menu_item_id, unit_price, quantity, status, item_type)
SELECT 'a32abd7a-f7f3-4d7c-a5dc-8c1ae4234aa8','aaaaaaaa-0000-0000-0000-000000000001',mi.id,mi.price,4,'pending','standard'
FROM menu_items mi WHERE mi.name='떡볶이' AND mi.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' ON CONFLICT DO NOTHING;

INSERT INTO order_items (order_id, restaurant_id, menu_item_id, unit_price, quantity, status, item_type)
SELECT 'a32abd7a-f7f3-4d7c-a5dc-8c1ae4234aa8','aaaaaaaa-0000-0000-0000-000000000001',mi.id,mi.price,2,'pending','standard'
FROM menu_items mi WHERE mi.name='보리차' AND mi.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' ON CONFLICT DO NOTHING;

-- ============================================================
-- CASHIER 화면: T02 주문 (serving 상태 — 결제 대기)
-- ============================================================
INSERT INTO orders (id, restaurant_id, table_id, status, sales_channel, created_by)
SELECT '809b68b4-16ff-4415-90c3-20b236ac9359',
  'aaaaaaaa-0000-0000-0000-000000000001', t.id, 'serving', 'dine_in',
  (SELECT auth_id FROM users WHERE role='waiter' AND restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' LIMIT 1)
FROM tables t WHERE t.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND t.table_number='T02'
ON CONFLICT DO NOTHING;

INSERT INTO order_items (order_id, restaurant_id, menu_item_id, unit_price, quantity, status, item_type)
SELECT '809b68b4-16ff-4415-90c3-20b236ac9359','aaaaaaaa-0000-0000-0000-000000000001',mi.id,mi.price,3,'served','standard'
FROM menu_items mi WHERE mi.name='비빔밥' AND mi.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' ON CONFLICT DO NOTHING;

INSERT INTO order_items (order_id, restaurant_id, menu_item_id, unit_price, quantity, status, item_type)
SELECT '809b68b4-16ff-4415-90c3-20b236ac9359','aaaaaaaa-0000-0000-0000-000000000001',mi.id,mi.price,2,'served','standard'
FROM menu_items mi WHERE mi.name='식혜' AND mi.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' ON CONFLICT DO NOTHING;

-- ============================================================
-- REPORTS 화면: 완료된 주문 + 결제 이력 (어제 + 오늘)
-- ============================================================
INSERT INTO orders (id, restaurant_id, table_id, status, sales_channel, created_at, updated_at)
SELECT 'f509be1c-ee2c-4135-84d4-7627b1911b49',
  'aaaaaaaa-0000-0000-0000-000000000001', t.id, 'completed', 'dine_in',
  now()-interval '1 day', now()-interval '1 day'
FROM tables t WHERE t.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND t.table_number='T04'
ON CONFLICT DO NOTHING;

INSERT INTO order_items (order_id, restaurant_id, menu_item_id, unit_price, quantity, status, item_type)
SELECT 'f509be1c-ee2c-4135-84d4-7627b1911b49','aaaaaaaa-0000-0000-0000-000000000001',mi.id,mi.price,2,'served','standard'
FROM menu_items mi WHERE mi.name='불고기밥' AND mi.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' ON CONFLICT DO NOTHING;

INSERT INTO payments (id, restaurant_id, order_id, amount, method, is_revenue, created_at)
VALUES ('04c55748-6381-458f-ac19-d800109785a5','aaaaaaaa-0000-0000-0000-000000000001',
  'f509be1c-ee2c-4135-84d4-7627b1911b49', 178000,'cash',true, now()-interval '1 day')
ON CONFLICT DO NOTHING;

INSERT INTO orders (id, restaurant_id, table_id, status, sales_channel, created_at, updated_at)
SELECT '3d5da721-0771-435c-b501-4a7cd5c92a46',
  'aaaaaaaa-0000-0000-0000-000000000001', t.id, 'completed', 'dine_in',
  now()-interval '2 hours', now()-interval '2 hours'
FROM tables t WHERE t.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND t.table_number='T05'
ON CONFLICT DO NOTHING;

INSERT INTO order_items (order_id, restaurant_id, menu_item_id, unit_price, quantity, status, item_type)
SELECT '3d5da721-0771-435c-b501-4a7cd5c92a46','aaaaaaaa-0000-0000-0000-000000000001',mi.id,mi.price,3,'served','standard'
FROM menu_items mi WHERE mi.name='비빔밥' AND mi.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' ON CONFLICT DO NOTHING;

INSERT INTO payments (id, restaurant_id, order_id, amount, method, is_revenue, created_at)
VALUES ('79fce16a-874a-423b-a212-4bf82eabd2de','aaaaaaaa-0000-0000-0000-000000000001',
  '3d5da721-0771-435c-b501-4a7cd5c92a46', 225000,'card',true, now()-interval '2 hours')
ON CONFLICT DO NOTHING;

-- 서비스 결제 (매출 제외 케이스)
INSERT INTO orders (id, restaurant_id, table_id, status, sales_channel, created_at)
SELECT '26ef5bb9-f70a-4591-b21c-76d6af0d6ee8',
  'aaaaaaaa-0000-0000-0000-000000000001', t.id, 'completed', 'dine_in', now()-interval '3 hours'
FROM tables t WHERE t.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND t.table_number='T06'
ON CONFLICT DO NOTHING;

INSERT INTO payments (id, restaurant_id, order_id, amount, method, is_revenue, created_at)
VALUES ('fe13be40-68d4-42a0-bcee-8bdd7e147dea','aaaaaaaa-0000-0000-0000-000000000001',
  '26ef5bb9-f70a-4591-b21c-76d6af0d6ee8', 89000,'service',false, now()-interval '3 hours')
ON CONFLICT DO NOTHING;

-- ============================================================
-- ATTENDANCE 화면: 근태 기록 (오늘)
-- ============================================================
INSERT INTO attendance_logs (restaurant_id, user_id, type, logged_at)
SELECT 'aaaaaaaa-0000-0000-0000-000000000001', u.id, 'clock_in', now()-interval '8 hours'
FROM users u WHERE u.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND u.role='waiter';

INSERT INTO attendance_logs (restaurant_id, user_id, type, logged_at)
SELECT 'aaaaaaaa-0000-0000-0000-000000000001', u.id, 'clock_in', now()-interval '7 hours 30 minutes'
FROM users u WHERE u.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND u.role='kitchen';

INSERT INTO attendance_logs (restaurant_id, user_id, type, logged_at)
SELECT 'aaaaaaaa-0000-0000-0000-000000000001', u.id, 'clock_in', now()-interval '7 hours'
FROM users u WHERE u.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND u.role='cashier';

INSERT INTO attendance_logs (restaurant_id, user_id, type, logged_at)
SELECT 'aaaaaaaa-0000-0000-0000-000000000001', u.id, 'clock_out', now()-interval '30 minutes'
FROM users u WHERE u.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND u.role='waiter';

-- ============================================================
-- EXTERNAL SALES (배달 매출 — Deliberry 시뮬)
-- ============================================================
INSERT INTO external_sales (
  restaurant_id, source_system, external_order_id,
  sales_channel, gross_amount, discount_amount, delivery_fee, net_amount,
  order_status, is_revenue, completed_at
) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001','deliberry','DLV-20260402-0001','delivery',
   150000,10000,20000,120000,'completed',true, now()-interval '4 hours'),
  ('aaaaaaaa-0000-0000-0000-000000000001','deliberry','DLV-20260402-0002','delivery',
   200000,0,20000,180000,'completed',true, now()-interval '1 hour')
ON CONFLICT DO NOTHING;
