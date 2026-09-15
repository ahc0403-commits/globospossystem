-- Runtime contract for BM service/cancellation/staff-meal menu history.
-- Run after all migrations with:
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/bm_menu_exception_history_test.sql

BEGIN;

DO $test$
DECLARE
  v_result jsonb;
  v_forbidden boolean := false;
  v_detail_forbidden boolean := false;
  v_scope_forbidden boolean := false;
BEGIN
  INSERT INTO public.companies(id, name)
  VALUES ('b1000000-0000-4000-8000-000000000001', 'BM history test company');

  INSERT INTO public.brand_master(id, company_id, name, type)
  VALUES (
    'b1000000-0000-4000-8000-000000000002',
    'b1000000-0000-4000-8000-000000000001',
    'BM history master',
    'internal'
  );

  INSERT INTO public.tax_entity(id, tax_code, name, owner_type)
  VALUES (
    'b1000000-0000-4000-8000-000000000003',
    'BM-HISTORY-TEST-20260915',
    'BM history tax entity',
    'internal'
  );

  INSERT INTO public.brands(id, code, name, brand_master_id)
  VALUES
    (
      'b1000000-0000-4000-8000-000000000004',
      'bm_history_test_20260915',
      'BM history brand',
      'b1000000-0000-4000-8000-000000000002'
    ),
    (
      'b1000000-0000-4000-8000-000000000007',
      'bm_history_other_20260915',
      'BM history other brand',
      'b1000000-0000-4000-8000-000000000002'
    );

  INSERT INTO public.restaurants(id, name, slug, brand_id, tax_entity_id)
  VALUES (
    'b1000000-0000-4000-8000-000000000005',
    'BM history store',
    'bm-history-test-20260915',
    'b1000000-0000-4000-8000-000000000004',
    'b1000000-0000-4000-8000-000000000003'
  );

  INSERT INTO auth.users(id, email)
  VALUES
    ('b1000000-0000-4000-8000-0000000000a1', 'bm-history-bm@globos.test'),
    ('b1000000-0000-4000-8000-0000000000a2', 'bm-history-store@globos.test');

  INSERT INTO public.users(
    id, auth_id, restaurant_id, primary_store_id, brand_id, role, full_name
  ) VALUES
    (
      'b1000000-0000-4000-8000-0000000000b1',
      'b1000000-0000-4000-8000-0000000000a1',
      'b1000000-0000-4000-8000-000000000005',
      'b1000000-0000-4000-8000-000000000005',
      'b1000000-0000-4000-8000-000000000004',
      'brand_admin',
      'BM History Manager'
    ),
    (
      'b1000000-0000-4000-8000-0000000000b2',
      'b1000000-0000-4000-8000-0000000000a2',
      'b1000000-0000-4000-8000-000000000005',
      'b1000000-0000-4000-8000-000000000005',
      'b1000000-0000-4000-8000-000000000004',
      'store_admin',
      'Store Manager'
    );

  INSERT INTO public.restaurants(
    id, name, slug, brand_id, tax_entity_id, is_active
  )
  VALUES (
    'b1000000-0000-4000-8000-000000000006',
    'BM history inaccessible store',
    'bm-history-inaccessible-test-20260915',
    'b1000000-0000-4000-8000-000000000007',
    'b1000000-0000-4000-8000-000000000003',
    false
  );

  INSERT INTO public.orders(
    id, restaurant_id, status, order_purpose, notes, created_by, created_at
  ) VALUES
    (
      'b1000000-0000-4000-8000-000000000010',
      'b1000000-0000-4000-8000-000000000005',
      'confirmed',
      'customer',
      NULL,
      'b1000000-0000-4000-8000-0000000000a1',
      '2026-09-15 02:00:00+00'
    ),
    (
      'b1000000-0000-4000-8000-000000000013',
      'b1000000-0000-4000-8000-000000000005',
      'completed',
      'staff_meal',
      'staff dinner',
      'b1000000-0000-4000-8000-0000000000a1',
      '2026-09-15 02:30:00+00'
    );

  INSERT INTO public.menu_items(id, restaurant_id, name, price)
  VALUES (
    'b1000000-0000-4000-8000-000000000012',
    'b1000000-0000-4000-8000-000000000005',
    'Test noodle',
    50000
  );

  INSERT INTO public.order_items(
    id, restaurant_id, order_id, menu_item_id, item_type, label, display_name,
    unit_price, quantity, status, paying_amount_inc_tax
  ) VALUES
    (
      'b1000000-0000-4000-8000-000000000011',
      'b1000000-0000-4000-8000-000000000005',
      'b1000000-0000-4000-8000-000000000010',
      'b1000000-0000-4000-8000-000000000012',
      'menu_item',
      'Test noodle',
      'Test noodle',
      50000,
      2,
      'cancelled',
      110000
    ),
    (
      'b1000000-0000-4000-8000-000000000014',
      'b1000000-0000-4000-8000-000000000005',
      'b1000000-0000-4000-8000-000000000013',
      'b1000000-0000-4000-8000-000000000012',
      'menu_item',
      'Staff rice',
      'Staff rice',
      50000,
      1,
      'served',
      50000
    ),
    (
      'b1000000-0000-4000-8000-000000000015',
      'b1000000-0000-4000-8000-000000000005',
      'b1000000-0000-4000-8000-000000000013',
      'b1000000-0000-4000-8000-000000000012',
      'menu_item',
      'Staff soup',
      'Staff soup',
      10000,
      2,
      'served',
      20000
    );

  INSERT INTO public.audit_logs(
    id, actor_id, action, entity_type, entity_id, details, created_at
  ) VALUES
    (
      'b1000000-0000-4000-8000-000000000020',
      'b1000000-0000-4000-8000-0000000000a1',
      'mark_order_item_service',
      'order_items',
      'b1000000-0000-4000-8000-000000000011',
      jsonb_build_object(
        'store_id', 'b1000000-0000-4000-8000-000000000005',
        'order_id', 'b1000000-0000-4000-8000-000000000010',
        'label', 'Test noodle',
        'quantity', 2,
        'unit_price', 50000,
        'reason', 'guest recovery'
      ),
      '2026-09-15 03:00:00+00'
    ),
    (
      'b1000000-0000-4000-8000-000000000021',
      'b1000000-0000-4000-8000-0000000000a1',
      'unmark_order_item_service',
      'order_items',
      'b1000000-0000-4000-8000-000000000011',
      jsonb_build_object(
        'store_id', 'b1000000-0000-4000-8000-000000000005',
        'order_id', 'b1000000-0000-4000-8000-000000000010',
        'label', 'Test noodle',
        'quantity', 2,
        'unit_price', 50000,
        'reason', 'manager reversed'
      ),
      '2026-09-15 04:00:00+00'
    );

  INSERT INTO public.order_cancellation_ledger(
    id, restaurant_id, order_id, order_item_id, cancellation_scope,
    cancelled_amount, quantity, unit_price, item_snapshot, created_by,
    created_at, order_status_snapshot
  ) VALUES (
    'b1000000-0000-4000-8000-000000000030',
    'b1000000-0000-4000-8000-000000000005',
    'b1000000-0000-4000-8000-000000000010',
    'b1000000-0000-4000-8000-000000000011',
    'item',
    110000,
    2,
    50000,
    jsonb_build_array(jsonb_build_object(
      'order_item_id', 'b1000000-0000-4000-8000-000000000011',
      'label', 'Test noodle',
      'item_type', 'menu_item',
      'quantity', 2,
      'unit_price', 50000,
      'paying_amount_inc_tax', 110000,
      'is_service_item', false
    )),
    'b1000000-0000-4000-8000-0000000000a1',
    '2026-09-15 05:00:00+00',
    'confirmed'
  );

  INSERT INTO public.order_cancellation_reversals(
    id, cancellation_ledger_id, restaurant_id, order_id, order_item_id,
    restored_by, restored_at
  ) VALUES (
    'b1000000-0000-4000-8000-000000000031',
    'b1000000-0000-4000-8000-000000000030',
    'b1000000-0000-4000-8000-000000000005',
    'b1000000-0000-4000-8000-000000000010',
    'b1000000-0000-4000-8000-000000000011',
    'b1000000-0000-4000-8000-0000000000a1',
    '2026-09-15 06:00:00+00'
  );

  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', 'b1000000-0000-4000-8000-0000000000a1',
      'role', 'authenticated'
    )::text,
    true
  );
  PERFORM set_config(
    'request.jwt.claim.sub',
    'b1000000-0000-4000-8000-0000000000a1',
    true
  );

  v_result := public.get_bm_menu_exception_history(
    NULL,
    '2026-09-01 00:00:00+00',
    '2026-10-01 00:00:00+00',
    'all',
    true,
    NULL,
    '2026-10-01 00:00:00+00',
    0,
    50
  );

  IF jsonb_array_length(v_result -> 'items') <> 5
     OR (v_result #>> '{summary,total_rows}')::integer <> 5
     OR (v_result #>> '{summary,service_event_count}')::integer <> 1
     OR (v_result #>> '{summary,service_quantity}')::numeric <> 2
     OR (v_result #>> '{summary,service_reference_amount}')::numeric <> 100000
     OR (v_result #>> '{summary,cancellation_event_count}')::integer <> 1
     OR (v_result #>> '{summary,cancelled_quantity}')::numeric <> 2
     OR (v_result #>> '{summary,cancelled_amount}')::numeric <> 110000
     OR (v_result #>> '{summary,staff_meal_event_count}')::integer <> 1
     OR (v_result #>> '{summary,staff_meal_quantity}')::numeric <> 3
     OR (v_result #>> '{summary,staff_meal_reference_amount}')::numeric <> 70000
     OR (v_result #>> '{summary,reversal_event_count}')::integer <> 2 THEN
    RAISE EXCEPTION 'BM history aggregation mismatch: %', v_result;
  END IF;

  v_result := public.get_bm_menu_exception_history(
    'b1000000-0000-4000-8000-000000000005',
    '2026-09-01 00:00:00+00',
    '2026-10-01 00:00:00+00',
    'all',
    false,
    'noodle',
    '2026-10-01 00:00:00+00',
    0,
    1
  );

  IF jsonb_array_length(v_result -> 'items') <> 1
     OR (v_result #>> '{summary,total_rows}')::integer <> 2
     OR COALESCE((v_result ->> 'has_more')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'BM history filter or pagination mismatch: %', v_result;
  END IF;

  v_result := public.get_bm_menu_exception_history(
    'b1000000-0000-4000-8000-000000000005',
    '2026-09-01 00:00:00+00',
    '2026-10-01 00:00:00+00',
    'staff_meal',
    true,
    NULL,
    '2026-10-01 00:00:00+00',
    0,
    50
  );

  IF jsonb_array_length(v_result -> 'items') <> 1
     OR (v_result #>> '{summary,total_rows}')::integer <> 1
     OR (v_result #>> '{items,0,source_kind}') <> 'staff_meal'
     OR (v_result #>> '{items,0,item_name}') <> 'Staff rice, Staff soup'
     OR (v_result #>> '{items,0,quantity}')::numeric <> 3
     OR (v_result #>> '{items,0,reference_amount}')::numeric <> 70000 THEN
    RAISE EXCEPTION 'BM staff meal filter mismatch: %', v_result;
  END IF;

  v_result := public.get_bm_order_history_detail(
    'b1000000-0000-4000-8000-000000000013'
  );

  IF (v_result ->> 'order_id')::uuid <>
       'b1000000-0000-4000-8000-000000000013'::uuid
     OR length(v_result ->> 'order_number') <> 5
     OR (v_result ->> 'item_count')::integer <> 2
     OR (v_result ->> 'total_quantity')::numeric <> 3
     OR (v_result ->> 'reference_amount')::numeric <> 70000
     OR jsonb_array_length(v_result -> 'items') <> 2
     OR (v_result #>> '{items,0,name}') <> 'Staff rice'
     OR (v_result #>> '{items,1,name}') <> 'Staff soup' THEN
    RAISE EXCEPTION 'BM original order detail mismatch: %', v_result;
  END IF;

  BEGIN
    PERFORM public.get_bm_menu_exception_history(
      'b1000000-0000-4000-8000-000000000006',
      '2026-09-01 00:00:00+00',
      '2026-10-01 00:00:00+00'
    );
  EXCEPTION WHEN OTHERS THEN
    v_scope_forbidden := SQLERRM LIKE '%BM_MENU_HISTORY_FORBIDDEN%';
  END;

  IF NOT v_scope_forbidden THEN
    RAISE EXCEPTION 'BM out-of-scope store access was not rejected';
  END IF;

  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', 'b1000000-0000-4000-8000-0000000000a2',
      'role', 'authenticated'
    )::text,
    true
  );
  PERFORM set_config(
    'request.jwt.claim.sub',
    'b1000000-0000-4000-8000-0000000000a2',
    true
  );

  BEGIN
    PERFORM public.get_bm_menu_exception_history(
      'b1000000-0000-4000-8000-000000000005',
      '2026-09-01 00:00:00+00',
      '2026-10-01 00:00:00+00'
    );
  EXCEPTION WHEN OTHERS THEN
    v_forbidden := SQLERRM LIKE '%BM_MENU_HISTORY_FORBIDDEN%';
  END;

  IF NOT v_forbidden THEN
    RAISE EXCEPTION 'Non-BM history access was not rejected';
  END IF;

  BEGIN
    PERFORM public.get_bm_order_history_detail(
      'b1000000-0000-4000-8000-000000000013'
    );
  EXCEPTION WHEN OTHERS THEN
    v_detail_forbidden := SQLERRM LIKE '%BM_MENU_HISTORY_FORBIDDEN%';
  END;

  IF NOT v_detail_forbidden THEN
    RAISE EXCEPTION 'Non-BM original order detail access was not rejected';
  END IF;
END;
$test$;

ROLLBACK;
