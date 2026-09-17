\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE
  company uuid := gen_random_uuid();
  master uuid := gen_random_uuid();
  brand uuid := gen_random_uuid();
  tax uuid := gen_random_uuid();
  store uuid := gen_random_uuid();
  actor uuid := gen_random_uuid();
  staff uuid;
  menu uuid := gen_random_uuid();
  food uuid := gen_random_uuid();
  drink uuid := gen_random_uuid();
  order_id_test uuid := gen_random_uuid();
  item uuid := gen_random_uuid();
  seat uuid := gen_random_uuid();
  session uuid := gen_random_uuid();
  result public.orders;
BEGIN
  INSERT INTO public.companies(id, name) VALUES (company, 'KDS cancellation fixture');
  INSERT INTO public.brand_master(id, company_id, name, type)
    VALUES (master, company, 'KDS fixture', 'internal');
  INSERT INTO public.brands(id, code, name, brand_master_id)
    VALUES (brand, 'kds_cancel_fixture', 'KDS fixture', master);
  INSERT INTO public.tax_entity(id, tax_code, name, owner_type)
    VALUES (tax, 'KDS-CANCEL-FIXTURE', 'KDS fixture', 'internal');
  INSERT INTO public.restaurants(id, name, brand_id, tax_entity_id)
    VALUES (store, 'KDS cancellation fixture', brand, tax);
  INSERT INTO public.restaurant_settings(restaurant_id, fulfillment_mode) VALUES (store, 'paperless');
  INSERT INTO auth.users(id, email) VALUES (actor, 'kds-cancel-fixture@example.test');
  INSERT INTO public.users(auth_id, restaurant_id, role, is_active)
    VALUES (actor, store, 'cashier', true) RETURNING id INTO staff;
  INSERT INTO public.user_store_access(user_id, store_id, is_primary, is_active, source_type)
    VALUES (staff, store, true, true, 'direct');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', actor, 'role', 'authenticated')::text, true);
  INSERT INTO public.tables(id, restaurant_id, table_number, floor_label, seat_count)
    VALUES (seat, store, '101', '2F', 4);
  INSERT INTO public.menu_items(id, restaurant_id, name, price)
    VALUES (menu, store, 'KDS fixture dish', 10000);
  INSERT INTO public.emergency_fulfillment_sessions(id, restaurant_id, reason)
    VALUES (session, store, 'KDS cancellation test');
  INSERT INTO public.orders(id, restaurant_id, table_id, status, fulfillment_mode_snapshot)
    VALUES (order_id_test, store, seat, 'serving', 'paperless');
  INSERT INTO public.order_items(id, restaurant_id, order_id, menu_item_id,
    display_name, label, quantity, unit_price, status, fulfillment_mode_snapshot)
    VALUES (item, store, order_id_test, menu, 'KDS fixture dish', 'KDS fixture dish',
      2, 10000, 'ready', 'paperless');
  IF NOT EXISTS (SELECT 1 FROM public.emergency_fulfillment_items WHERE order_item_id = item) THEN
    RAISE EXCEPTION 'Fixture did not create KDS line';
  END IF;
  UPDATE public.emergency_fulfillment_items SET kitchen_started_quantity = 2,
    kitchen_done_quantity = 2, tray_received_quantity = 2,
    tray_dispatched_quantity = 2, floor_served_quantity = 2 WHERE order_item_id = item;
  UPDATE public.order_items SET status = 'served' WHERE id = item;

  -- The waiter cannot override a served check.
  UPDATE public.users SET role = 'waiter' WHERE id = staff;
  BEGIN
    PERFORM public.cancel_order(order_id_test, store);
    RAISE EXCEPTION 'Waiter unexpectedly cancelled served food';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT IN ('ORDER_MUTATION_FORBIDDEN', 'ORDER_SERVING_CANCEL_ADMIN_REQUIRED') THEN RAISE; END IF;
  END;
  UPDATE public.users SET role = 'cashier' WHERE id = staff;
  BEGIN
    PERFORM public.cancel_order(order_id_test, gen_random_uuid());
    RAISE EXCEPTION 'Cross-store cancellation unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ORDER_MUTATION_FORBIDDEN' THEN RAISE; END IF;
  END;

  UPDATE public.users SET role = 'kitchen' WHERE id = staff;
  BEGIN
    PERFORM public.cancel_order(order_id_test, store, true);
    RAISE EXCEPTION 'Kitchen unexpectedly cancelled order';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ORDER_MUTATION_FORBIDDEN' THEN RAISE; END IF;
  END;
  UPDATE public.users SET role = 'waiter' WHERE id = staff;
  UPDATE public.orders SET status = 'confirmed' WHERE id = order_id_test;
  BEGIN
    PERFORM public.cancel_order(order_id_test, store, true);
    RAISE EXCEPTION 'Waiter flag bypass unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ORDER_HAS_SERVED_ITEMS' THEN RAISE; END IF;
  END;
  UPDATE public.users SET role = 'cashier' WHERE id = staff;
  UPDATE public.orders SET status = 'serving' WHERE id = order_id_test;
  SELECT * INTO result FROM public.cancel_order(order_id_test, store);
  IF result.status <> 'cancelled' THEN RAISE EXCEPTION 'Cancellation failed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.emergency_fulfillment_items
    WHERE order_item_id = item AND is_cancelled AND floor_served_quantity = 2) THEN
    RAISE EXCEPTION 'KDS cancellation lost historical served progress';
  END IF;
  IF (SELECT count(*) FROM public.order_cancellation_ledger WHERE order_id = order_id_test AND cancellation_scope = 'order') <> 1 THEN
    RAISE EXCEPTION 'Cancellation ledger missing';
  END IF;
  BEGIN
    PERFORM public.cancel_order(order_id_test, store);
    RAISE EXCEPTION 'Duplicate cancellation unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ORDER_NOT_CANCELLABLE' THEN RAISE; END IF;
  END;
  PERFORM public.restore_cancelled_order(order_id_test, store);
  IF NOT EXISTS (SELECT 1 FROM public.order_items WHERE id = item AND status = 'served') THEN
    RAISE EXCEPTION 'Undo did not restore original served status';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.emergency_fulfillment_items
    WHERE order_item_id = item AND NOT is_cancelled AND floor_served_quantity = 2) THEN
    RAISE EXCEPTION 'Undo did not restore KDS progress';
  END IF;

  -- A missed worker check must also allow the same whole-menu cancellation.
  UPDATE public.emergency_fulfillment_items SET floor_served_quantity = 0 WHERE order_item_id = item;
  UPDATE public.order_items SET status = 'ready' WHERE id = item;
  PERFORM public.cancel_order(order_id_test, store);
  PERFORM public.restore_cancelled_order(order_id_test, store);

  -- Combo food and floor-direct drink checks must not disable menu cancellation.
  INSERT INTO public.menu_items(id, restaurant_id, name, price)
    VALUES (food, store, 'Combo food fixture', 10000),
           (drink, store, 'Combo drink fixture', 5000);
  UPDATE public.menu_items SET is_combo = true WHERE id = menu;
  UPDATE public.order_items SET combo_components = jsonb_build_array(
    jsonb_build_object('menu_item_id', food, 'name_vi', 'Combo food', 'quantity', 1,
      'is_total_quantity', false, 'fulfillment_route', 'kitchen_tray_floor'),
    jsonb_build_object('menu_item_id', drink, 'name_vi', 'Combo drink', 'quantity', 1,
      'is_total_quantity', false, 'fulfillment_route', 'floor_direct')
  ) WHERE id = item;
  UPDATE public.emergency_combo_component_items SET kitchen_started_quantity = 2,
    kitchen_done_quantity = 2, tray_received_quantity = 2,
    tray_dispatched_quantity = 2, floor_served_quantity = 2 WHERE order_item_id = item;
  UPDATE public.emergency_floor_direct_items SET floor_served_quantity = 2 WHERE order_item_id = item;
  IF NOT EXISTS (SELECT 1 FROM public.emergency_combo_component_items WHERE order_item_id = item)
    OR NOT EXISTS (SELECT 1 FROM public.emergency_floor_direct_items WHERE order_item_id = item) THEN
    RAISE EXCEPTION 'Combo fixture did not create operational lines';
  END IF;
  PERFORM public.cancel_order(order_id_test, store);
  IF EXISTS (SELECT 1 FROM public.emergency_combo_component_items WHERE order_item_id = item AND NOT is_cancelled)
    OR EXISTS (SELECT 1 FROM public.emergency_floor_direct_items WHERE order_item_id = item AND NOT is_cancelled) THEN
    RAISE EXCEPTION 'Combo cancellation left active food or drinks';
  END IF;
  PERFORM public.restore_cancelled_order(order_id_test, store);
  IF NOT EXISTS (SELECT 1 FROM public.emergency_combo_component_items
    WHERE order_item_id = item AND NOT is_cancelled AND floor_served_quantity = 2)
    OR NOT EXISTS (SELECT 1 FROM public.emergency_floor_direct_items
    WHERE order_item_id = item AND NOT is_cancelled AND floor_served_quantity = 2) THEN
    RAISE EXCEPTION 'Combo undo failed to preserve progress';
  END IF;

  INSERT INTO public.payments(restaurant_id, order_id, amount, amount_portion, method)
    VALUES (store, order_id_test, 1000, 1000, 'CASH');
  BEGIN
    PERFORM public.cancel_order(order_id_test, store);
    RAISE EXCEPTION 'Paid order cancellation unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ORDER_HAS_PAYMENTS_USE_ADJUSTMENT' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS: checked/unchecked whole-order cancellation, ledger, KDS sync, undo, roles, scope, payment guard';
END;
$$;
ROLLBACK;
