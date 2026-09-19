\set ON_ERROR_STOP on

BEGIN;

DO $test$
DECLARE
  v_store uuid;
  v_auth uuid := gen_random_uuid();
  v_user uuid;
  v_session uuid := gen_random_uuid();
  v_assignment uuid := gen_random_uuid();
  v_menu uuid := gen_random_uuid();
  v_order uuid := gen_random_uuid();
  v_order_item uuid := gen_random_uuid();
  v_item uuid;
  v_queue uuid;
  v_floor text;
  v_tray_request uuid := gen_random_uuid();
  v_customer_request uuid := gen_random_uuid();
  v_allocations jsonb;
  v_result jsonb;
BEGIN
  SELECT id INTO v_store FROM public.restaurants
  WHERE is_active = true ORDER BY created_at, id LIMIT 1;
  IF v_store IS NULL THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_TEST_NEEDS_SEEDED_STORE';
  END IF;

  INSERT INTO auth.users(id, email)
  VALUES (v_auth, 'kds-tray-floor-customer@example.test');
  INSERT INTO public.users(auth_id, restaurant_id, role, full_name, is_active)
  VALUES (v_auth, v_store, 'emergency_station', 'KDS batch test', true)
  RETURNING id INTO v_user;
  INSERT INTO public.user_store_access(
    user_id, store_id, is_primary, is_active, source_type
  ) VALUES (v_user, v_store, true, true, 'direct');
  INSERT INTO public.restaurant_settings(restaurant_id, fulfillment_mode)
  VALUES (v_store, 'paperless')
  ON CONFLICT (restaurant_id) DO UPDATE SET fulfillment_mode = 'paperless';
  INSERT INTO public.emergency_fulfillment_sessions(
    id, restaurant_id, reason
  ) VALUES (v_session, v_store, 'KDS tray floor customer batch contract');
  INSERT INTO public.emergency_station_assignments(
    id, restaurant_id, user_id, station_type, is_active
  ) VALUES (v_assignment, v_store, v_user, 'kitchen', true);
  INSERT INTO public.menu_items(
    id, restaurant_id, name, name_ko, name_vi, name_en, price
  ) VALUES (
    v_menu, v_store, 'Gimbap batch fixture', '김밥', 'Cơm cuộn', 'Gimbap', 10000
  );
  INSERT INTO public.orders(
    id, restaurant_id, status, fulfillment_mode_snapshot, created_at
  ) VALUES (v_order, v_store, 'serving', 'paperless', now());
  INSERT INTO public.order_items(
    id, restaurant_id, order_id, menu_item_id, display_name, label,
    quantity, unit_price, status, fulfillment_mode_snapshot, created_at
  ) VALUES (
    v_order_item, v_store, v_order, v_menu, '김밥', '김밥',
    2, 10000, 'ready', 'paperless', now()
  );

  SELECT item.id, item.queue_id, queue.floor_label
  INTO v_item, v_queue, v_floor
  FROM public.emergency_fulfillment_items item
  JOIN public.emergency_order_queue queue ON queue.id = item.queue_id
  WHERE item.order_item_id = v_order_item;
  IF v_item IS NULL OR v_queue IS NULL OR upper(btrim(v_floor)) NOT IN ('1F', '2F') THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_FIXTURE_CAPTURE_FAILED';
  END IF;

  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_auth, 'role', 'authenticated')::text,
    true
  );
  PERFORM public.kds_complete_kitchen_batch_v1(
    gen_random_uuid(),
    jsonb_build_array(jsonb_build_object(
      'item_id', v_item, 'source_kind', 'base', 'quantity', 2
    ))
  );

  UPDATE public.emergency_station_assignments
  SET station_type = 'tray', floor_label = NULL WHERE id = v_assignment;
  BEGIN
    PERFORM public.kds_dispatch_tray_floor_batch_v1(
      gen_random_uuid(), v_floor,
      jsonb_build_array(jsonb_build_object(
        'item_id', v_item, 'queue_id', v_queue,
        'source_kind', 'base', 'quantity', 1
      ))
    );
    RAISE EXCEPTION 'KDS_TRAY_EXACT_SNAPSHOT_UNEXPECTEDLY_SUCCEEDED';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'KDS_TRAY_FLOOR_BATCH_STALE' THEN RAISE; END IF;
  END;

  v_allocations := jsonb_build_array(jsonb_build_object(
    'item_id', v_item, 'queue_id', v_queue,
    'source_kind', 'base', 'quantity', 2
  ));
  v_result := public.kds_dispatch_tray_floor_batch_v1(
    v_tray_request, v_floor, v_allocations
  );
  IF (v_result->>'changed_quantity')::integer <> 2
     OR v_result->>'deduplicated' <> 'false'
     OR NOT EXISTS (
       SELECT 1 FROM public.emergency_fulfillment_items
       WHERE id = v_item AND tray_received_quantity = 2
         AND tray_dispatched_quantity = 2
     ) THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_BATCH_RESULT_INVALID';
  END IF;
  v_result := public.kds_dispatch_tray_floor_batch_v1(
    v_tray_request, v_floor, v_allocations
  );
  IF v_result->>'deduplicated' <> 'true'
     OR (SELECT count(*) FROM public.emergency_floor_ready_lots
         WHERE source_kind = 'base' AND source_id = v_item) <> 2 THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_BATCH_IDEMPOTENCY_INVALID';
  END IF;

  UPDATE public.emergency_station_assignments
  SET station_type = 'floor', floor_label = v_floor WHERE id = v_assignment;
  v_allocations := jsonb_build_array(jsonb_build_object(
    'item_id', v_item, 'queue_id', v_queue,
    'source_kind', 'base', 'quantity', 1
  ));
  v_result := public.kds_complete_customer_delivery_batch_v1(
    v_customer_request, v_allocations
  );
  IF (v_result->>'changed_quantity')::integer <> 1
     OR v_result->>'deduplicated' <> 'false'
     OR NOT EXISTS (
       SELECT 1 FROM public.emergency_fulfillment_items
       WHERE id = v_item AND floor_served_quantity = 1
     ) THEN
    RAISE EXCEPTION 'KDS_CUSTOMER_DELIVERY_PARTIAL_RESULT_INVALID';
  END IF;
  v_result := public.kds_complete_customer_delivery_batch_v1(
    v_customer_request, v_allocations
  );
  IF v_result->>'deduplicated' <> 'true'
     OR NOT EXISTS (
       SELECT 1 FROM public.emergency_fulfillment_items
       WHERE id = v_item AND floor_served_quantity = 1
     ) THEN
    RAISE EXCEPTION 'KDS_CUSTOMER_DELIVERY_IDEMPOTENCY_INVALID';
  END IF;

  BEGIN
    PERFORM public.kds_complete_customer_delivery_batch_v1(
      gen_random_uuid(),
      jsonb_build_array(jsonb_build_object(
        'item_id', v_item, 'queue_id', v_queue,
        'source_kind', 'base', 'quantity', 2
      ))
    );
    RAISE EXCEPTION 'KDS_CUSTOMER_STALE_SELECTION_UNEXPECTEDLY_SUCCEEDED';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'KDS_CUSTOMER_DELIVERY_BATCH_STALE' THEN RAISE; END IF;
  END;

  IF NOT EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_items item
    WHERE item.id = v_item
      AND item.floor_served_quantity = 1
      AND item.floor_served_quantity <= item.tray_dispatched_quantity
      AND item.tray_dispatched_quantity = item.tray_received_quantity
      AND item.tray_received_quantity <= item.kitchen_done_quantity
  ) THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_CUSTOMER_QUANTITY_CHAIN_INVALID';
  END IF;

  RAISE NOTICE 'PASS: tray exact-floor and customer selection batches';
END;
$test$;

ROLLBACK;
