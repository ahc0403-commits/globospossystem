\set ON_ERROR_STOP on

-- Runtime regression for one customer-facing paper and digital receipt per
-- combined payment. Every fixture mutation is rolled back.
BEGIN;

DO $test$
DECLARE
  v_store_id uuid;
  v_auth_id uuid := gen_random_uuid();
  v_table_a_id uuid := gen_random_uuid();
  v_table_b_id uuid := gen_random_uuid();
  v_table_suffix text;
  v_table_a text;
  v_table_b text;
  v_menu_a_id uuid := gen_random_uuid();
  v_menu_b_id uuid := gen_random_uuid();
  v_order_a_id uuid := gen_random_uuid();
  v_order_b_id uuid := gen_random_uuid();
  v_item_a_id uuid := gen_random_uuid();
  v_item_b_id uuid := gen_random_uuid();
  v_group_id uuid := gen_random_uuid();
  v_print_first public.print_jobs%ROWTYPE;
  v_print_again public.print_jobs%ROWTYPE;
  v_digital_first jsonb;
  v_digital_again jsonb;
  v_receipt_id uuid;
  v_snapshot jsonb;
  v_link jsonb;
  v_public_snapshot jsonb;
  v_ledger jsonb;
  v_ledger_entry jsonb;
  v_count integer;
BEGIN
  SELECT id INTO v_store_id
  FROM public.restaurants
  WHERE is_active = true
  ORDER BY id
  LIMIT 1;
  IF v_store_id IS NULL THEN
    RAISE EXCEPTION 'COMBINED_RECEIPT_FIXTURE_ACTIVE_STORE_REQUIRED';
  END IF;

  v_table_suffix := upper(substr(replace(v_group_id::text, '-', ''), 1, 8));
  v_table_a := 'CR-A-' || v_table_suffix;
  v_table_b := 'CR-B-' || v_table_suffix;

  INSERT INTO auth.users (id) VALUES (v_auth_id);
  INSERT INTO public.users (
    auth_id, restaurant_id, role, full_name, is_active,
    account_type, fixed_account_code
  ) VALUES (
    v_auth_id, v_store_id, 'super_admin', 'Combined Receipt Fixture', true,
    'master', 'combined_receipt_fixture'
  );
  PERFORM set_config('request.jwt.claim.sub', v_auth_id::text, true);

  INSERT INTO public.tables (
    id, restaurant_id, table_number, seat_count, status, floor_label
  ) VALUES
    (v_table_a_id, v_store_id, v_table_a, 4, 'available', '1F'),
    (v_table_b_id, v_store_id, v_table_b, 4, 'available', '1F');

  INSERT INTO public.menu_items (
    id, restaurant_id, name, name_ko, name_vi, name_en,
    price, is_available, vat_category
  ) VALUES
    (
      v_menu_a_id, v_store_id, 'Fixture Pho', '퍼', 'Phở bò', 'Pho',
      50000, true, 'food'
    ),
    (
      v_menu_b_id, v_store_id, 'Fixture Bun Cha', '분짜', 'Bún chả',
      'Bun cha', 60000, true, 'food'
    );

  INSERT INTO public.orders (
    id, restaurant_id, table_id, status, created_by
  ) VALUES
    (v_order_a_id, v_store_id, v_table_a_id, 'completed', v_auth_id),
    (v_order_b_id, v_store_id, v_table_b_id, 'completed', v_auth_id);

  INSERT INTO public.order_items (
    id, restaurant_id, order_id, menu_item_id, menu_item_id_snapshot,
    label, display_name, unit_price, quantity, status,
    total_amount_ex_tax, paying_amount_inc_tax
  ) VALUES
    (
      v_item_a_id, v_store_id, v_order_a_id, v_menu_a_id, v_menu_a_id,
      'Fixture Pho', 'Fixture Pho', 50000, 1, 'served', 50000, 50000
    ),
    (
      v_item_b_id, v_store_id, v_order_b_id, v_menu_b_id, v_menu_b_id,
      'Fixture Bun Cha', 'Fixture Bun Cha', 60000, 1, 'served', 60000, 60000
    );

  INSERT INTO public.combined_payment_groups (
    id, restaurant_id, method, total_amount, order_count, status,
    processed_by, completed_at
  ) VALUES (
    v_group_id, v_store_id, 'CASH', 110000, 2, 'completed',
    v_auth_id, now()
  );

  INSERT INTO public.payments (
    restaurant_id, order_id, amount, amount_portion, method, is_revenue,
    processed_by, combined_payment_group_id
  ) VALUES
    (
      v_store_id, v_order_a_id, 50000, 50000, 'CASH', true,
      v_auth_id, v_group_id
    ),
    (
      v_store_id, v_order_b_id, 60000, 60000, 'CASH', true,
      v_auth_id, v_group_id
    );

  SELECT * INTO v_print_first
  FROM public.enqueue_combined_receipt_print_job(v_group_id, 120000, false);
  SELECT * INTO v_print_again
  FROM public.enqueue_combined_receipt_print_job(v_group_id, 120000, false);

  IF v_print_first.id IS DISTINCT FROM v_print_again.id THEN
    RAISE EXCEPTION 'COMBINED_PAPER_RECEIPT_NOT_IDEMPOTENT';
  END IF;
  SELECT count(*)::integer INTO v_count
  FROM public.print_jobs
  WHERE combined_payment_group_id = v_group_id
    AND copy_type = 'receipt'
    AND batch_no = 1;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'COMBINED_PAPER_RECEIPT_COUNT_INVALID:%', v_count;
  END IF;

  v_digital_first := public.ensure_combined_digital_receipt(
    v_group_id, 120000, 10000
  );
  v_digital_again := public.ensure_combined_digital_receipt(
    v_group_id, 120000, 10000
  );
  v_receipt_id := (v_digital_first->>'receipt_id')::uuid;

  IF v_receipt_id IS DISTINCT FROM
       (v_digital_again->>'receipt_id')::uuid
     OR (v_digital_first->>'created')::boolean IS DISTINCT FROM true
     OR (v_digital_again->>'created')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'COMBINED_DIGITAL_RECEIPT_NOT_IDEMPOTENT';
  END IF;
  SELECT count(*)::integer INTO v_count
  FROM public.digital_receipts
  WHERE combined_payment_group_id = v_group_id
    AND order_id IS NULL;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'COMBINED_DIGITAL_RECEIPT_COUNT_INVALID:%', v_count;
  END IF;

  SELECT snapshot INTO v_snapshot
  FROM public.digital_receipts
  WHERE id = v_receipt_id;

  IF v_snapshot->>'receipt_scope' IS DISTINCT FROM 'combined'
     OR (v_snapshot->>'combined_payment_group_id')::uuid
          IS DISTINCT FROM v_group_id
     OR jsonb_array_length(v_snapshot->'order_ids') <> 2
     OR jsonb_array_length(v_snapshot->'items') <> 2
     OR (v_snapshot->>'subtotal_amount')::numeric <> 110000
     OR (v_snapshot->>'total_amount')::numeric <> 110000
     OR (v_snapshot->>'received_amount')::numeric <> 120000
     OR (v_snapshot->>'change_amount')::numeric <> 10000 THEN
    RAISE EXCEPTION 'COMBINED_DIGITAL_RECEIPT_SNAPSHOT_INVALID:%', v_snapshot;
  END IF;

  SELECT count(*)::integer INTO v_count
  FROM jsonb_array_elements(v_snapshot->'items') item
  WHERE item->>'item_id' IN (v_item_a_id::text, v_item_b_id::text)
    AND item->>'order_id' IN (v_order_a_id::text, v_order_b_id::text)
    AND item->>'menu_item_id' IN (v_menu_a_id::text, v_menu_b_id::text)
    AND item->>'label' IN (
      '[' || v_table_a || '] Phở bò',
      '[' || v_table_b || '] Bún chả'
    );
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'COMBINED_DIGITAL_RECEIPT_ITEM_IDENTITY_INVALID:%',
      v_snapshot->'items';
  END IF;

  IF v_print_first.payload->'items' IS DISTINCT FROM v_snapshot->'items'
     OR v_print_first.payload->>'receipt_number'
          IS DISTINCT FROM v_snapshot->>'receipt_number'
     OR (v_print_first.payload->>'combined_received_amount')::numeric
          <> 120000
     OR (v_print_first.payload->>'combined_change_amount')::numeric
          <> 10000 THEN
    RAISE EXCEPTION 'COMBINED_PAPER_DIGITAL_SNAPSHOT_DIVERGED';
  END IF;

  v_link := public.issue_digital_receipt_link(v_receipt_id);
  v_public_snapshot := public.get_public_receipt(v_link->>'token');
  IF v_public_snapshot->'items' IS DISTINCT FROM v_snapshot->'items'
     OR (v_public_snapshot->>'combined_payment_group_id')::uuid
          IS DISTINCT FROM v_group_id THEN
    RAISE EXCEPTION 'COMBINED_PUBLIC_RECEIPT_SNAPSHOT_INVALID';
  END IF;

  PERFORM public.show_combined_customer_receipt_display(
    v_store_id, v_group_id, v_receipt_id
  );
  IF NOT EXISTS (
    SELECT 1
    FROM public.customer_payment_displays display
    WHERE display.store_id = v_store_id
      AND display.payload->>'receipt_id' = v_receipt_id::text
      AND display.payload->>'combined_payment_group_id' = v_group_id::text
      AND (display.payload->>'is_combined')::boolean = true
  ) THEN
    RAISE EXCEPTION 'COMBINED_CUSTOMER_DISPLAY_PAYLOAD_INVALID';
  END IF;

  v_ledger := public.get_receipt_ledger(
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
    v_store_id,
    v_group_id::text,
    NULL,
    100,
    0
  );
  IF jsonb_array_length(v_ledger->'receipts') <> 1 THEN
    RAISE EXCEPTION 'COMBINED_LEDGER_ENTRY_COUNT_INVALID:%',
      v_ledger->'receipts';
  END IF;
  v_ledger_entry := v_ledger->'receipts'->0;
  IF (v_ledger_entry->>'combined_payment_group_id')::uuid
       IS DISTINCT FROM v_group_id
     OR v_ledger_entry->>'receipt_scope' IS DISTINCT FROM 'combined'
     OR jsonb_array_length(v_ledger_entry->'order_ids') <> 2
     OR jsonb_array_length(v_ledger_entry->'payments') <> 1
     OR jsonb_array_length(v_ledger_entry->'allocations') <> 2
     OR (v_ledger_entry->>'gross_amount')::numeric <> 110000 THEN
    RAISE EXCEPTION 'COMBINED_LEDGER_ENTRY_INVALID:%', v_ledger_entry;
  END IF;

  v_ledger := public.get_receipt_ledger(
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
    v_store_id,
    v_order_a_id::text,
    NULL,
    100,
    0
  );
  IF jsonb_array_length(v_ledger->'receipts') <> 1
     OR (v_ledger->'receipts'->0->>'combined_payment_group_id')::uuid
          IS DISTINCT FROM v_group_id THEN
    RAISE EXCEPTION 'COMBINED_LEDGER_ORDER_SEARCH_INVALID';
  END IF;
END;
$test$;

ROLLBACK;

SELECT 'UNIFIED_COMBINED_CUSTOMER_RECEIPT_RUNTIME_OK' AS result;
