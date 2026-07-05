-- order_lifecycle_contract_test.sql
-- Gate 2 (PILOT_SMOKE_GATE_TEST_PLAN_2026_07_03.md): order lifecycle state
-- contract test against ORDER_LIFECYCLE_STATE_CONTRACT_2026_07_03.md.
--
-- Run against a FULLY MIGRATED database (local supabase db / staging) with a
-- superuser or service connection:
--   psql "$DB_URL" -f supabase/tests/order_lifecycle_contract_test.sql
--
-- Everything runs inside one transaction and is rolled back — no data
-- persists. Exit code is non-zero if any scenario fails (ON_ERROR_STOP +
-- final RAISE EXCEPTION).
--
-- Expected on pre-contract main (2026-07-03):
--   Scenario 1..3  PASS  (existing update_order_item_status derivation)
--   Scenario 4     FAIL  (C1 — add_items_to_order does not recalc status)
--   Scenario 5     FAIL  (C2 — cancel_order leaves items un-cancelled)
--   Scenario 6     FAIL  (H3 — process_payment accepts pending items)
-- After the recalc_order_status migration all six must PASS.

\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE _gate2_results (
  scenario text,
  ok boolean,
  detail text
);

-- ---------------------------------------------------------------------------
-- Fixtures: isolated store, staff (waiter/kitchen/cashier), menu, tables.
-- auth context is faked per-actor via request.jwt.claims (what auth.uid()
-- reads); transaction-local so nothing leaks.
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.act_as(p_auth uuid) RETURNS void
LANGUAGE sql AS $$
  SELECT set_config(
    'request.jwt.claims',
    json_build_object('sub', p_auth, 'role', 'authenticated')::text,
    true
  );
$$;

-- fixed fixture ids
\set store_id    '''e2e00000-0000-4000-8000-000000000001'''
\set waiter_auth '''e2e00000-0000-4000-8000-0000000000a1'''
\set kitchen_auth '''e2e00000-0000-4000-8000-0000000000a2'''
\set cashier_auth '''e2e00000-0000-4000-8000-0000000000a3'''
\set menu_a      '''e2e00000-0000-4000-8000-0000000000f1'''
\set menu_b      '''e2e00000-0000-4000-8000-0000000000f2'''

INSERT INTO restaurants (id, name, address, is_active)
VALUES (:store_id, 'Gate2 Contract Test Store', 'test', true);

INSERT INTO auth.users (id, email)
VALUES
  (:waiter_auth,  'gate2.waiter@globos.test'),
  (:kitchen_auth, 'gate2.kitchen@globos.test'),
  (:cashier_auth, 'gate2.cashier@globos.test');

INSERT INTO public.users (auth_id, restaurant_id, role, full_name, is_active)
VALUES
  (:waiter_auth,  :store_id, 'waiter',  'Gate2 Waiter',  true),
  (:kitchen_auth, :store_id, 'kitchen', 'Gate2 Kitchen', true),
  (:cashier_auth, :store_id, 'cashier', 'Gate2 Cashier', true);

INSERT INTO public.user_store_access (user_id, store_id, is_primary, is_active, source_type)
SELECT u.id, :store_id, true, true, 'direct'
FROM public.users u
WHERE u.auth_id IN (:waiter_auth, :kitchen_auth, :cashier_auth);

INSERT INTO menu_items (id, restaurant_id, name, price, is_available)
VALUES
  (:menu_a, :store_id, 'Gate2 Dish A', 75000, true),
  (:menu_b, :store_id, 'Gate2 Dish B', 65000, true);

-- one table per scenario, T91..T96
INSERT INTO tables (restaurant_id, table_number, seat_count, status)
SELECT :store_id, 'T9' || n, 4, 'available' FROM generate_series(1, 6) n;

-- Scenario runner helpers -----------------------------------------------------
CREATE FUNCTION pg_temp.fixture_table(p_no text) RETURNS uuid
LANGUAGE sql AS $$
  SELECT id FROM tables
  WHERE restaurant_id = 'e2e00000-0000-4000-8000-000000000001'
    AND table_number = p_no;
$$;

CREATE FUNCTION pg_temp.new_order(p_table_no text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_order orders;
BEGIN
  PERFORM pg_temp.act_as('e2e00000-0000-4000-8000-0000000000a1');
  v_order := create_order(
    'e2e00000-0000-4000-8000-000000000001',
    pg_temp.fixture_table(p_table_no),
    jsonb_build_array(
      jsonb_build_object('menu_item_id', 'e2e00000-0000-4000-8000-0000000000f1', 'quantity', 1),
      jsonb_build_object('menu_item_id', 'e2e00000-0000-4000-8000-0000000000f2', 'quantity', 2)
    )
  );
  RETURN v_order.id;
END;
$$;

CREATE FUNCTION pg_temp.advance_all_items(p_order uuid, p_to text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_item record;
  v_path text[];
  v_step text;
BEGIN
  PERFORM pg_temp.act_as('e2e00000-0000-4000-8000-0000000000a2'); -- kitchen
  FOR v_item IN
    SELECT id, status FROM order_items
    WHERE order_id = p_order AND status <> 'cancelled'
  LOOP
    v_path := CASE p_to
      WHEN 'preparing' THEN ARRAY['preparing']
      WHEN 'ready'     THEN ARRAY['preparing','ready']
      WHEN 'served'    THEN ARRAY['preparing','ready','served']
    END;
    FOREACH v_step IN ARRAY v_path LOOP
      IF (SELECT status FROM order_items WHERE id = v_item.id) <> v_step THEN
        PERFORM update_order_item_status(
          v_item.id, 'e2e00000-0000-4000-8000-000000000001', v_step);
      END IF;
    END LOOP;
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Scenario 1: create_order → order 'pending', items 'pending', table occupied
-- ---------------------------------------------------------------------------
DO $s1$
DECLARE
  v_order uuid;
  v_status text;
  v_bad int;
  v_table_status text;
BEGIN
  v_order := pg_temp.new_order('T91');
  SELECT status INTO v_status FROM orders WHERE id = v_order;
  SELECT count(*) INTO v_bad FROM order_items WHERE order_id = v_order AND status <> 'pending';
  SELECT t.status INTO v_table_status
  FROM tables t JOIN orders o ON o.table_id = t.id WHERE o.id = v_order;

  IF v_status <> 'pending' THEN
    RAISE EXCEPTION 'order status % (expected pending)', v_status;
  END IF;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION '% items not pending after create', v_bad;
  END IF;
  IF v_table_status <> 'occupied' THEN
    RAISE EXCEPTION 'table status % (expected occupied)', v_table_status;
  END IF;
  INSERT INTO _gate2_results VALUES ('S1 create_order → pending', true, 'order pending, items pending, table occupied');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _gate2_results VALUES ('S1 create_order → pending', false, SQLERRM);
END;
$s1$;

-- ---------------------------------------------------------------------------
-- Scenario 2: all items preparing → order 'confirmed'
-- ---------------------------------------------------------------------------
DO $s2$
DECLARE
  v_order uuid;
  v_status text;
BEGIN
  v_order := pg_temp.new_order('T92');
  PERFORM pg_temp.advance_all_items(v_order, 'preparing');
  SELECT status INTO v_status FROM orders WHERE id = v_order;
  IF v_status <> 'confirmed' THEN
    RAISE EXCEPTION 'order status % (expected confirmed)', v_status;
  END IF;
  INSERT INTO _gate2_results VALUES ('S2 all preparing → confirmed', true, 'order confirmed');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _gate2_results VALUES ('S2 all preparing → confirmed', false, SQLERRM);
END;
$s2$;

-- ---------------------------------------------------------------------------
-- Scenario 3: all items ready → order 'serving'
-- ---------------------------------------------------------------------------
DO $s3$
DECLARE
  v_order uuid;
  v_status text;
BEGIN
  v_order := pg_temp.new_order('T93');
  PERFORM pg_temp.advance_all_items(v_order, 'ready');
  SELECT status INTO v_status FROM orders WHERE id = v_order;
  IF v_status <> 'serving' THEN
    RAISE EXCEPTION 'order status % (expected serving)', v_status;
  END IF;
  INSERT INTO _gate2_results VALUES ('S3 all ready → serving', true, 'order serving (payable)');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _gate2_results VALUES ('S3 all ready → serving', false, SQLERRM);
END;
$s3$;

-- ---------------------------------------------------------------------------
-- Scenario 4 (C1): add items to a 'serving' order → order must demote to
-- 'confirmed' (new pending item ⇒ not payable). Contract §recalc.
-- ---------------------------------------------------------------------------
DO $s4$
DECLARE
  v_order uuid;
  v_status text;
  v_new_item_status text;
  v_existing uuid[];
BEGIN
  v_order := pg_temp.new_order('T94');
  PERFORM pg_temp.advance_all_items(v_order, 'ready');

  -- created_at is now() = transaction start for every row in this test
  -- transaction, so identify the added item by id set difference.
  SELECT array_agg(id) INTO v_existing FROM order_items WHERE order_id = v_order;

  PERFORM pg_temp.act_as('e2e00000-0000-4000-8000-0000000000a1'); -- waiter
  PERFORM add_items_to_order(
    v_order,
    'e2e00000-0000-4000-8000-000000000001',
    jsonb_build_array(
      jsonb_build_object('menu_item_id', 'e2e00000-0000-4000-8000-0000000000f1', 'quantity', 1)
    )
  );

  SELECT status INTO v_status FROM orders WHERE id = v_order;
  SELECT status INTO v_new_item_status
  FROM order_items WHERE order_id = v_order AND id <> ALL(v_existing);

  IF v_new_item_status <> 'pending' THEN
    RAISE EXCEPTION 'new item status % (expected pending)', v_new_item_status;
  END IF;
  IF v_status <> 'confirmed' THEN
    RAISE EXCEPTION 'C1: order stayed ''%'' after mid-service item add (expected demotion to confirmed — recalc_order_status missing)', v_status;
  END IF;
  INSERT INTO _gate2_results VALUES ('S4 add during serving → confirmed (C1)', true, 'order demoted, new item pending');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _gate2_results VALUES ('S4 add during serving → confirmed (C1)', false, SQLERRM);
END;
$s4$;

-- ---------------------------------------------------------------------------
-- Scenario 5 (C2): cancel_order must cancel all unfinished items and release
-- the table. Contract §cancel_order.
-- ---------------------------------------------------------------------------
DO $s5$
DECLARE
  v_order uuid;
  v_first_item uuid;
  v_uncancelled int;
  v_order_status text;
  v_table_status text;
BEGIN
  v_order := pg_temp.new_order('T95');
  -- one item into the kitchen, one still pending → order 'confirmed'
  SELECT id INTO v_first_item FROM order_items
  WHERE order_id = v_order ORDER BY created_at LIMIT 1;
  PERFORM pg_temp.act_as('e2e00000-0000-4000-8000-0000000000a2');
  PERFORM update_order_item_status(
    v_first_item, 'e2e00000-0000-4000-8000-000000000001', 'preparing');

  PERFORM pg_temp.act_as('e2e00000-0000-4000-8000-0000000000a1');
  PERFORM cancel_order(v_order, 'e2e00000-0000-4000-8000-000000000001');

  SELECT status INTO v_order_status FROM orders WHERE id = v_order;
  SELECT count(*) INTO v_uncancelled
  FROM order_items WHERE order_id = v_order AND status <> 'cancelled';
  SELECT t.status INTO v_table_status
  FROM tables t JOIN orders o ON o.table_id = t.id WHERE o.id = v_order;

  IF v_order_status <> 'cancelled' THEN
    RAISE EXCEPTION 'order status % (expected cancelled)', v_order_status;
  END IF;
  IF v_uncancelled <> 0 THEN
    RAISE EXCEPTION 'C2: % item(s) left un-cancelled after cancel_order (kitchen keeps cooking a dead order)', v_uncancelled;
  END IF;
  IF v_table_status <> 'available' THEN
    RAISE EXCEPTION 'table status % (expected available)', v_table_status;
  END IF;
  INSERT INTO _gate2_results VALUES ('S5 cancel_order cancels items (C2)', true, 'order+items cancelled, table released');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _gate2_results VALUES ('S5 cancel_order cancels items (C2)', false, SQLERRM);
END;
$s5$;

-- ---------------------------------------------------------------------------
-- Scenario 6 (H3): process_payment must reject an order that still has a
-- pending item (ORDER_NOT_PAYABLE). Contract invariant I3.
-- ---------------------------------------------------------------------------
DO $s6$
DECLARE
  v_order uuid;
  v_first_item uuid;
  v_payment_made boolean := false;
BEGIN
  v_order := pg_temp.new_order('T96');
  -- first item fully ready, second stays pending → order NOT payable
  SELECT id INTO v_first_item FROM order_items
  WHERE order_id = v_order ORDER BY created_at LIMIT 1;
  PERFORM pg_temp.act_as('e2e00000-0000-4000-8000-0000000000a2');
  PERFORM update_order_item_status(v_first_item, 'e2e00000-0000-4000-8000-000000000001', 'preparing');
  PERFORM update_order_item_status(v_first_item, 'e2e00000-0000-4000-8000-000000000001', 'ready');

  PERFORM pg_temp.act_as('e2e00000-0000-4000-8000-0000000000a3'); -- cashier
  BEGIN
    PERFORM process_payment(
      v_order, 'e2e00000-0000-4000-8000-000000000001', 100000, 'CASH');
    v_payment_made := true;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ORDER_NOT_PAYABLE%' THEN
      RAISE; -- unexpected error, surface it
    END IF;
    -- expected rejection
  END;

  IF v_payment_made THEN
    RAISE EXCEPTION 'H3: process_payment SUCCEEDED with a pending item (expected ORDER_NOT_PAYABLE)';
  END IF;
  INSERT INTO _gate2_results VALUES ('S6 payment blocked while item pending (H3)', true, 'ORDER_NOT_PAYABLE raised');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _gate2_results VALUES ('S6 payment blocked while item pending (H3)', false, SQLERRM);
END;
$s6$;

-- ---------------------------------------------------------------------------
-- Summary + verdict (before rollback so the temp table still exists)
-- ---------------------------------------------------------------------------
DO $summary$
DECLARE
  r record;
  v_fail int := 0;
  v_total int := 0;
BEGIN
  RAISE NOTICE '==== Gate 2 — Order Lifecycle Contract ====';
  FOR r IN SELECT * FROM _gate2_results LOOP
    v_total := v_total + 1;
    IF r.ok THEN
      RAISE NOTICE 'PASS  %  — %', r.scenario, r.detail;
    ELSE
      v_fail := v_fail + 1;
      RAISE NOTICE 'FAIL  %  — %', r.scenario, r.detail;
    END IF;
  END LOOP;
  RAISE NOTICE '==== % scenarios, % failed ====', v_total, v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'GATE2_FAILED: % of % scenarios failed', v_fail, v_total;
  END IF;
END;
$summary$;

ROLLBACK;
