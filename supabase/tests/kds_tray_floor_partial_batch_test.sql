\set ON_ERROR_STOP on

BEGIN;

SELECT set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000002',
  true
);

DO $test$
DECLARE
  v_first_request uuid := gen_random_uuid();
  v_second_request uuid := gen_random_uuid();
  v_allocations jsonb := jsonb_build_array(jsonb_build_object(
    'item_id', '10000000-0000-0000-0000-000000000008'::uuid,
    'queue_id', '10000000-0000-0000-0000-000000000007'::uuid,
    'source_kind', 'base',
    'quantity', 1
  ));
  v_result jsonb;
BEGIN
  v_result := public.kds_dispatch_tray_floor_batch_v1(
    v_first_request, '1F', v_allocations
  );
  IF (v_result->>'changed_quantity')::integer <> 1
     OR v_result->>'deduplicated' <> 'false'
     OR NOT EXISTS (
       SELECT 1 FROM public.emergency_fulfillment_items
       WHERE id = '10000000-0000-0000-0000-000000000008'
         AND tray_received_quantity = 1
         AND tray_dispatched_quantity = 1
     )
     OR EXISTS (
       SELECT 1 FROM public.emergency_fulfillment_items
       WHERE id = '10000000-0000-0000-0000-000000000010'
         AND tray_dispatched_quantity <> 0
     ) THEN
    RAISE EXCEPTION 'KDS_PARTIAL_SELECTION_RESULT_INVALID';
  END IF;

  v_result := public.kds_dispatch_tray_floor_batch_v1(
    v_first_request, '1F', v_allocations
  );
  IF v_result->>'deduplicated' <> 'true'
     OR (SELECT count(*) FROM public.test_kds_progress_events) <> 1 THEN
    RAISE EXCEPTION 'KDS_PARTIAL_SELECTION_IDEMPOTENCY_INVALID';
  END IF;

  BEGIN
    PERFORM public.kds_dispatch_tray_floor_batch_v1(
      gen_random_uuid(), '1F',
      jsonb_build_array(jsonb_build_object(
        'item_id', '10000000-0000-0000-0000-000000000008'::uuid,
        'queue_id', '10000000-0000-0000-0000-000000000007'::uuid,
        'source_kind', 'base',
        'quantity', 2
      ))
    );
    RAISE EXCEPTION 'KDS_PARTIAL_OVER_SELECTION_UNEXPECTEDLY_SUCCEEDED';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'KDS_TRAY_FLOOR_BATCH_STALE' THEN RAISE; END IF;
  END;

  v_result := public.kds_dispatch_tray_floor_batch_v1(
    v_second_request, '1F', v_allocations
  );
  IF (v_result->>'changed_quantity')::integer <> 1
     OR NOT EXISTS (
       SELECT 1 FROM public.emergency_fulfillment_items
       WHERE id = '10000000-0000-0000-0000-000000000008'
         AND tray_received_quantity = 2
         AND tray_dispatched_quantity = 2
     )
     OR (SELECT count(*) FROM public.test_kds_progress_events) <> 2 THEN
    RAISE EXCEPTION 'KDS_PARTIAL_REMAINING_SELECTION_INVALID';
  END IF;

  RAISE NOTICE 'PASS: tray partial selection, stale guard and idempotency';
END;
$test$;

ROLLBACK;
