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
  v_early_order uuid := gen_random_uuid();
  v_late_order uuid := gen_random_uuid();
  v_early_order_item uuid := gen_random_uuid();
  v_late_order_item uuid := gen_random_uuid();
  v_early_item uuid;
  v_late_item uuid;
  v_request uuid := gen_random_uuid();
  v_allocations jsonb;
  v_result jsonb;
  v_early_sequence bigint;
  v_late_sequence bigint;
BEGIN
  SELECT id INTO v_store FROM public.restaurants
  WHERE is_active = true ORDER BY created_at, id LIMIT 1;
  IF v_store IS NULL THEN
    RAISE EXCEPTION 'KDS_HANDOFF_TEST_NEEDS_SEEDED_STORE';
  END IF;

  INSERT INTO auth.users(id, email)
  VALUES (v_auth, 'kds-handoff-batch@example.test');
  INSERT INTO public.users(auth_id, restaurant_id, role, full_name, is_active)
  VALUES (v_auth, v_store, 'emergency_station', 'KDS handoff test', true)
  RETURNING id INTO v_user;
  INSERT INTO public.user_store_access(
    user_id, store_id, is_primary, is_active, source_type
  ) VALUES (v_user, v_store, true, true, 'direct');
  INSERT INTO public.restaurant_settings(restaurant_id, fulfillment_mode)
  VALUES (v_store, 'paperless')
  ON CONFLICT (restaurant_id) DO UPDATE SET fulfillment_mode = 'paperless';
  INSERT INTO public.emergency_fulfillment_sessions(
    id, restaurant_id, reason
  ) VALUES (v_session, v_store, 'KDS handoff batch contract');
  INSERT INTO public.emergency_station_assignments(
    id, restaurant_id, user_id, station_type, is_active
  ) VALUES (v_assignment, v_store, v_user, 'kitchen', true);
  INSERT INTO public.menu_items(
    id, restaurant_id, name, name_ko, name_vi, name_en, price
  ) VALUES (
    v_menu, v_store, 'Gimbap fixture', '김밥', 'Cơm cuộn', 'Gimbap', 10000
  );
  INSERT INTO public.orders(
    id, restaurant_id, status, fulfillment_mode_snapshot, created_at
  ) VALUES
    (v_early_order, v_store, 'serving', 'paperless', now() - interval '2 minutes'),
    (v_late_order, v_store, 'serving', 'paperless', now() - interval '1 minute');
  INSERT INTO public.order_items(
    id, restaurant_id, order_id, menu_item_id, display_name, label,
    quantity, unit_price, status, fulfillment_mode_snapshot, created_at
  ) VALUES
    (v_early_order_item, v_store, v_early_order, v_menu, '김밥', '김밥',
      1, 10000, 'ready', 'paperless', now() - interval '2 minutes'),
    (v_late_order_item, v_store, v_late_order, v_menu, '김밥', '김밥',
      1, 10000, 'ready', 'paperless', now() - interval '1 minute');

  SELECT id INTO v_early_item FROM public.emergency_fulfillment_items
  WHERE order_item_id = v_early_order_item;
  SELECT id INTO v_late_item FROM public.emergency_fulfillment_items
  WHERE order_item_id = v_late_order_item;
  IF v_early_item IS NULL OR v_late_item IS NULL THEN
    RAISE EXCEPTION 'KDS_HANDOFF_FIXTURE_CAPTURE_FAILED';
  END IF;
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_auth, 'role', 'authenticated')::text,
    true
  );

  BEGIN
    PERFORM public.kds_complete_kitchen_batch_v1(
      gen_random_uuid(),
      jsonb_build_array(jsonb_build_object(
        'item_id', v_late_item, 'source_kind', 'base', 'quantity', 1
      ))
    );
    RAISE EXCEPTION 'KDS_HANDOFF_FIFO_SKIP_UNEXPECTEDLY_SUCCEEDED';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'KDS_CHECKET_SELECTION_STALE' THEN RAISE; END IF;
  END;

  v_allocations := jsonb_build_array(
    jsonb_build_object(
      'item_id', v_early_item, 'source_kind', 'base', 'quantity', 1
    ),
    jsonb_build_object(
      'item_id', v_late_item, 'source_kind', 'base', 'quantity', 1
    )
  );
  v_result := public.kds_complete_kitchen_batch_v1(v_request, v_allocations);
  IF (v_result->>'changed_quantity')::integer <> 2
     OR v_result->>'deduplicated' <> 'false' THEN
    RAISE EXCEPTION 'KDS_HANDOFF_BATCH_RESULT_INVALID';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_items
    WHERE id IN (v_early_item, v_late_item)
      AND (kitchen_done_quantity <> 1 OR kitchen_started_quantity <> 1)
  ) THEN RAISE EXCEPTION 'KDS_HANDOFF_KITCHEN_PROGRESS_INVALID'; END IF;
  SELECT ready_sequence INTO v_early_sequence
  FROM public.emergency_tray_ready_lots WHERE source_id = v_early_item;
  SELECT ready_sequence INTO v_late_sequence
  FROM public.emergency_tray_ready_lots WHERE source_id = v_late_item;
  IF v_early_sequence IS NULL OR v_late_sequence IS NULL
     OR v_early_sequence >= v_late_sequence THEN
    RAISE EXCEPTION 'KDS_HANDOFF_TRAY_SEQUENCE_INVALID';
  END IF;
  v_result := public.kds_complete_kitchen_batch_v1(v_request, v_allocations);
  IF v_result->>'deduplicated' <> 'true'
     OR (SELECT count(*) FROM public.emergency_tray_ready_lots
         WHERE source_id IN (v_early_item, v_late_item)) <> 2 THEN
    RAISE EXCEPTION 'KDS_HANDOFF_BATCH_IDEMPOTENCY_INVALID';
  END IF;

  UPDATE public.emergency_station_assignments
  SET station_type = 'tray' WHERE id = v_assignment;
  PERFORM public.kds_record_station_progress_v3(
    v_early_item, 'base', 'tray_dispatched', 1, gen_random_uuid()
  );
  PERFORM public.kds_record_station_progress_v3(
    v_late_item, 'base', 'tray_dispatched', 1, gen_random_uuid()
  );
  IF EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_items
    WHERE id IN (v_early_item, v_late_item)
      AND (tray_received_quantity <> 1 OR tray_dispatched_quantity <> 1)
  ) OR (SELECT count(*) FROM public.emergency_floor_ready_lots
        WHERE source_id IN (v_early_item, v_late_item)) <> 2 THEN
    RAISE EXCEPTION 'KDS_HANDOFF_TRAY_PROGRESS_INVALID';
  END IF;

  UPDATE public.emergency_station_assignments
  SET station_type = 'floor', floor_label = (
    SELECT floor_label FROM public.emergency_order_queue
    WHERE order_id = v_early_order
  ) WHERE id = v_assignment;
  PERFORM public.kds_record_station_progress_v3(
    v_early_item, 'base', 'floor_served', 1, gen_random_uuid()
  );
  IF NOT EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_items
    WHERE id = v_early_item AND floor_served_quantity = 1
  ) THEN RAISE EXCEPTION 'KDS_HANDOFF_FLOOR_PROGRESS_INVALID'; END IF;

  RAISE NOTICE 'PASS: kitchen batch FIFO, idempotency, tray ordering and floor handoff';
END;
$test$;

ROLLBACK;
