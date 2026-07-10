-- print_routing_contract_test.sql
-- Gate-2 callable contract for Floor/Station Print Routing V1 M1.
--
-- Run against a fully migrated database with:
--   psql "$DB_URL" -f supabase/tests/print_routing_contract_test.sql
--
-- Scenario coverage:
-- TP0 no destinations configured / NO_DESTINATION survival is represented by
--     the failed job fixture asserted during cancel cleanup.
-- TP1 create_order-style initial kitchen/floor enqueue.
-- TP2 add_items delta routing.
-- TP3 serving edge once.
-- TP4 add after serving / tray delta.
-- TP5 cancel order jobs.
-- TP6 claim skips already claimed rows.
-- TP7 bounded retry excludes jobs that reached the retry ceiling.
-- TP8 cross-store claim protection is enforced at runtime.
-- TP9 reprint reason.
-- TP10 enqueue failure audit evidence.

\set ON_ERROR_STOP on

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;
SELECT plan(48);

SELECT set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-00000000a111',
  true
);

INSERT INTO auth.users (
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  created_at,
  updated_at
)
VALUES (
  '00000000-0000-0000-0000-00000000a111',
  'authenticated',
  'authenticated',
  'print-routing-contract@globos.test',
  '',
  now(),
  now(),
  now()
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.tax_entity (id, tax_code, name, owner_type, einvoice_provider, data_source)
VALUES (
  '00000000-0000-0000-0000-00000000e111',
  'PRINTROUTE_TEST_000',
  'Print Routing Contract Tax Entity',
  'internal',
  'meinvoice',
  'VNPT_EPAY'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.restaurants (
  id,
  name,
  operation_mode,
  is_active,
  brand_id,
  tax_entity_id
)
SELECT
  '00000000-0000-0000-0000-00000000b111'::uuid,
  'Print Routing Contract Store',
  'standard',
  true,
  b.id,
  '00000000-0000-0000-0000-00000000e111'::uuid
FROM (
  SELECT id
  FROM public.brands
  WHERE code = 'globos_default'
  LIMIT 1
) b
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name,
    operation_mode = EXCLUDED.operation_mode,
    is_active = EXCLUDED.is_active,
    brand_id = EXCLUDED.brand_id,
    tax_entity_id = EXCLUDED.tax_entity_id;

INSERT INTO public.users (id, auth_id, restaurant_id, role, full_name, is_active)
VALUES (
  '00000000-0000-0000-0000-00000000c111',
  '00000000-0000-0000-0000-00000000a111',
  '00000000-0000-0000-0000-00000000b111',
  'super_admin',
  'Print Routing Contract',
  true
)
ON CONFLICT (id) DO UPDATE
SET role = EXCLUDED.role,
    is_active = true;

INSERT INTO public.tables (
  id,
  restaurant_id,
  table_number,
  seat_count,
  status,
  floor_label
)
VALUES (
  '00000000-0000-0000-0000-00000000d111',
  '00000000-0000-0000-0000-00000000b111',
  'T07',
  4,
  'occupied',
  '2F'
)
ON CONFLICT (id) DO UPDATE
SET status = 'occupied',
    floor_label = '2F';

INSERT INTO public.menu_items (id, restaurant_id, name, price, is_available)
VALUES
  (
    '00000000-0000-0000-0000-00000000e111',
    '00000000-0000-0000-0000-00000000b111',
    'Pho Bo',
    50000,
    true
  ),
  (
    '00000000-0000-0000-0000-00000000e222',
    '00000000-0000-0000-0000-00000000b111',
    'Bun Cha',
    60000,
    true
  )
ON CONFLICT (id) DO UPDATE
SET is_available = true;

INSERT INTO public.printer_destinations (
  id,
  restaurant_id,
  name,
  ip,
  port,
  purpose,
  floor_label,
  is_active
)
VALUES
  (
    '00000000-0000-0000-0000-00000000f111',
    '00000000-0000-0000-0000-00000000b111',
    'Kitchen',
    '192.168.1.10',
    9100,
    'kitchen',
    NULL,
    true
  ),
  (
    '00000000-0000-0000-0000-00000000f222',
    '00000000-0000-0000-0000-00000000b111',
    '2F',
    '192.168.1.20',
    9100,
    'floor',
    '2F',
    true
  ),
  (
    '00000000-0000-0000-0000-00000000f333',
    '00000000-0000-0000-0000-00000000b111',
    'Tray',
    '192.168.1.30',
    9100,
    'tray',
    NULL,
    true
  )
ON CONFLICT (id) DO UPDATE
SET is_active = true;

INSERT INTO public.orders (
  id,
  restaurant_id,
  table_id,
  status,
  created_by,
  created_at,
  updated_at
)
VALUES (
  '00000000-0000-0000-0000-000000001111',
  '00000000-0000-0000-0000-00000000b111',
  '00000000-0000-0000-0000-00000000d111',
  'confirmed',
  '00000000-0000-0000-0000-00000000a111',
  now() - interval '10 minutes',
  now() - interval '10 minutes'
)
ON CONFLICT (id) DO UPDATE
SET status = 'confirmed',
    table_id = EXCLUDED.table_id;

INSERT INTO public.order_items (
  id,
  restaurant_id,
  order_id,
  menu_item_id,
  item_type,
  label,
  display_name,
  unit_price,
  quantity,
  status,
  created_at
)
VALUES (
  '00000000-0000-0000-0000-000000002111',
  '00000000-0000-0000-0000-00000000b111',
  '00000000-0000-0000-0000-000000001111',
  '00000000-0000-0000-0000-00000000e111',
  'menu_item',
  'Pho Bo',
  'Pho Bo',
  50000,
  1,
  'ready',
  now() - interval '9 minutes'
)
ON CONFLICT (id) DO UPDATE
SET status = 'ready';

SELECT lives_ok(
  $$
    SELECT public.enqueue_print_jobs(
      '00000000-0000-0000-0000-000000001111',
      ARRAY['kitchen', 'floor'],
      '[{"menu_item_id":"00000000-0000-0000-0000-00000000e111","quantity":1}]'::jsonb,
      'initial'
    )
  $$,
  'TP1 create_order-style enqueue is callable'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.print_jobs
    WHERE order_id = '00000000-0000-0000-0000-000000001111'
      AND copy_type IN ('kitchen', 'floor')
      AND batch_no = 1
  ),
  2::bigint,
  'TP1 creates kitchen and floor batch 1 jobs'
);

SELECT lives_ok(
  $$
    SELECT public.recalc_order_status(
      '00000000-0000-0000-0000-000000001111'
    )
  $$,
  'TP3 serving edge creates first tray job'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.print_jobs
    WHERE order_id = '00000000-0000-0000-0000-000000001111'
      AND copy_type = 'tray'
      AND batch_no = 1
  ),
  1::bigint,
  'TP3 creates one tray batch on first serving edge'
);

SELECT is(
  (
    SELECT jsonb_array_length(payload->'items')
    FROM public.print_jobs
    WHERE order_id = '00000000-0000-0000-0000-000000001111'
      AND copy_type = 'tray'
      AND batch_no = 1
  ),
  1,
  'TP3 first tray payload includes the ready item'
);

UPDATE public.orders
SET status = 'confirmed'
WHERE id = '00000000-0000-0000-0000-000000001111';

SELECT lives_ok(
  $$
    SELECT *
    FROM public.add_items_to_order(
      '00000000-0000-0000-0000-000000001111',
      '00000000-0000-0000-0000-00000000b111',
      '[{"menu_item_id":"00000000-0000-0000-0000-00000000e222","quantity":2}]'::jsonb
    )
  $$,
  'TP2 add_items_to_order is callable'
);

SELECT is(
  (
    SELECT jsonb_array_length(payload->'items')
    FROM public.print_jobs
    WHERE order_id = '00000000-0000-0000-0000-000000001111'
      AND copy_type = 'kitchen'
      AND batch_no = 2
  ),
  1,
  'TP2 add_items kitchen batch contains only the delta item'
);

UPDATE public.order_items
SET status = 'ready'
WHERE order_id = '00000000-0000-0000-0000-000000001111'
  AND menu_item_id = '00000000-0000-0000-0000-00000000e222';

SELECT lives_ok(
  $$
    SELECT public.recalc_order_status(
      '00000000-0000-0000-0000-000000001111'
    )
  $$,
  'TP4 re-serving edge is callable after additions'
);

SELECT is(
  (
    SELECT jsonb_array_length(payload->'items')
    FROM public.print_jobs
    WHERE order_id = '00000000-0000-0000-0000-000000001111'
      AND copy_type = 'tray'
      AND batch_no = 2
  ),
  1,
  'TP4 tray batch 2 contains only the new item'
);

SELECT is(
  (
    SELECT payload->'items'->0->>'item_id'
    FROM public.print_jobs
    WHERE order_id = '00000000-0000-0000-0000-000000001111'
      AND copy_type = 'tray'
      AND batch_no = 2
  ),
  (
    SELECT id::text
    FROM public.order_items
    WHERE order_id = '00000000-0000-0000-0000-000000001111'
      AND menu_item_id = '00000000-0000-0000-0000-00000000e222'
    ORDER BY created_at DESC
    LIMIT 1
  ),
  'TP4 tray batch 2 identifies the new order item'
);

INSERT INTO public.print_jobs (
  id,
  restaurant_id,
  order_id,
  copy_type,
  batch_no,
  destination_id,
  payload,
  status,
  last_error
)
VALUES (
  '00000000-0000-0000-0000-000000003111',
  '00000000-0000-0000-0000-00000000b111',
  '00000000-0000-0000-0000-000000001111',
  'kitchen',
  99,
  NULL,
  '{"ticket":"kitchen","items":[]}'::jsonb,
  'failed',
  'NO_DESTINATION'
)
ON CONFLICT (id) DO UPDATE
SET status = 'failed',
    last_error = 'NO_DESTINATION';

SELECT lives_ok(
  $$
    SELECT public.cancel_order(
      '00000000-0000-0000-0000-000000001111',
      '00000000-0000-0000-0000-00000000b111',
      true
    )
  $$,
  'TP5 serving order cancel is callable for admin actor'
);

SELECT is(
  (
    SELECT status
    FROM public.orders
    WHERE id = '00000000-0000-0000-0000-000000001111'
  ),
  'cancelled',
  'TP5 order is cancelled'
);

SELECT is(
  (
    SELECT status
    FROM public.print_jobs
    WHERE id = '00000000-0000-0000-0000-000000003111'
  ),
  'cancelled',
  'TP5 failed print job is cancelled with the order'
);

INSERT INTO public.print_jobs (
  id,
  restaurant_id,
  order_id,
  copy_type,
  batch_no,
  destination_id,
  payload,
  status,
  attempts,
  next_retry_at
)
VALUES
  (
    '00000000-0000-0000-0000-000000003201',
    '00000000-0000-0000-0000-00000000b111',
    '00000000-0000-0000-0000-000000001111',
    'kitchen',
    101,
    '00000000-0000-0000-0000-00000000f111',
    '{"ticket":"kitchen","items":[]}'::jsonb,
    'pending',
    0,
    now() - interval '1 minute'
  ),
  (
    '00000000-0000-0000-0000-000000003202',
    '00000000-0000-0000-0000-00000000b111',
    '00000000-0000-0000-0000-000000001111',
    'kitchen',
    102,
    '00000000-0000-0000-0000-00000000f111',
    '{"ticket":"kitchen","items":[]}'::jsonb,
    'pending',
    0,
    now() - interval '1 minute'
  )
ON CONFLICT (id) DO UPDATE
SET status = 'pending',
    attempts = 0,
    destination_id = EXCLUDED.destination_id,
    next_retry_at = EXCLUDED.next_retry_at;

SELECT is(
  (
    SELECT count(*)
    FROM public.claim_print_jobs(
      '00000000-0000-0000-0000-00000000b111',
      1
    )
  ),
  1::bigint,
  'TP6 first claim takes one available job'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.claim_print_jobs(
      '00000000-0000-0000-0000-00000000b111',
      10
    )
    WHERE id IN (
      '00000000-0000-0000-0000-000000003201',
      '00000000-0000-0000-0000-000000003202'
    )
  ),
  1::bigint,
  'TP6 second claim skips the already claimed row'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.print_jobs
    WHERE id IN (
      '00000000-0000-0000-0000-000000003201',
      '00000000-0000-0000-0000-000000003202'
    )
      AND status = 'printing'
      AND attempts = 1
  ),
  2::bigint,
  'TP6 two jobs are claimed once each'
);

SELECT lives_ok(
  $$
    SELECT public.complete_print_job(
      '00000000-0000-0000-0000-000000003202',
      false,
      'SIMULATED_FAILURE'
    )
  $$,
  'TP7 failed completion path is callable'
);

SELECT is(
  (
    SELECT status
    FROM public.print_jobs
    WHERE id = '00000000-0000-0000-0000-000000003202'
  ),
  'failed',
  'TP7 failed completion returns the job to failed status'
);

INSERT INTO public.print_jobs (
  id,
  restaurant_id,
  order_id,
  copy_type,
  batch_no,
  destination_id,
  payload,
  status,
  attempts,
  next_retry_at
)
VALUES (
  '00000000-0000-0000-0000-000000003203',
  '00000000-0000-0000-0000-00000000b111',
  '00000000-0000-0000-0000-000000001111',
  'kitchen',
  103,
  '00000000-0000-0000-0000-00000000f111',
  '{"ticket":"kitchen","items":[]}'::jsonb,
  'failed',
  10,
  now() - interval '1 minute'
)
ON CONFLICT (id) DO UPDATE
SET status = 'failed',
    attempts = 10,
    destination_id = EXCLUDED.destination_id,
    next_retry_at = EXCLUDED.next_retry_at;

SELECT is(
  (
    SELECT count(*)
    FROM public.claim_print_jobs(
      '00000000-0000-0000-0000-00000000b111',
      10
    )
    WHERE id = '00000000-0000-0000-0000-000000003203'
  ),
  0::bigint,
  'TP7 attempts=10 failed job is not offered again'
);

INSERT INTO public.tax_entity (id, tax_code, name, owner_type, einvoice_provider, data_source)
VALUES (
  '00000000-0000-0000-0000-00000000e999',
  'PRINTROUTE_TEST_999',
  'Print Routing Other Store Tax Entity',
  'internal',
  'meinvoice',
  'VNPT_EPAY'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.restaurants (
  id,
  name,
  operation_mode,
  is_active,
  brand_id,
  tax_entity_id
)
SELECT
  '00000000-0000-0000-0000-00000000b222'::uuid,
  'Print Routing Other Store',
  'standard',
  true,
  b.id,
  '00000000-0000-0000-0000-00000000e999'::uuid
FROM (
  SELECT id
  FROM public.brands
  WHERE code = 'globos_default'
  LIMIT 1
) b
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name,
    operation_mode = EXCLUDED.operation_mode,
    is_active = EXCLUDED.is_active,
    brand_id = EXCLUDED.brand_id,
    tax_entity_id = EXCLUDED.tax_entity_id;

INSERT INTO public.printer_destinations (
  id,
  restaurant_id,
  name,
  ip,
  port,
  purpose,
  floor_label,
  is_active
)
VALUES (
  '00000000-0000-0000-0000-00000000f444',
  '00000000-0000-0000-0000-00000000b222',
  'Other Kitchen',
  '192.168.2.10',
  9100,
  'kitchen',
  NULL,
  true
)
ON CONFLICT (id) DO UPDATE
SET is_active = true;

INSERT INTO public.print_jobs (
  id,
  restaurant_id,
  order_id,
  copy_type,
  batch_no,
  destination_id,
  payload,
  status
)
VALUES (
  '00000000-0000-0000-0000-000000003204',
  '00000000-0000-0000-0000-00000000b222',
  NULL,
  'kitchen',
  1,
  '00000000-0000-0000-0000-00000000f444',
  '{"ticket":"kitchen","items":[]}'::jsonb,
  'pending'
)
ON CONFLICT (id) DO UPDATE
SET status = 'pending',
    destination_id = EXCLUDED.destination_id;

UPDATE public.users
SET role = 'kitchen',
    restaurant_id = '00000000-0000-0000-0000-00000000b111'
WHERE auth_id = '00000000-0000-0000-0000-00000000a111';

SELECT throws_ok(
  $$
    SELECT *
    FROM public.claim_print_jobs(
      '00000000-0000-0000-0000-00000000b222',
      1
    )
  $$,
  'P0001',
  'PRINT_CLAIM_FORBIDDEN',
  'TP8 cross-store claim is forbidden'
);

UPDATE public.users
SET role = 'super_admin'
WHERE auth_id = '00000000-0000-0000-0000-00000000a111';

SELECT lives_ok(
  $$
    SELECT public.reprint_print_job(
      '00000000-0000-0000-0000-000000003201'
    )
  $$,
  'TP9 reprint_print_job is callable'
);

SELECT is(
  (
    SELECT payload->>'printed_reason'
    FROM public.print_jobs
    WHERE order_id = '00000000-0000-0000-0000-000000001111'
      AND copy_type = 'kitchen'
      AND payload->>'printed_reason' = 'reprint'
    ORDER BY created_at DESC
    LIMIT 1
  ),
  'reprint',
  'TP9 reprint job marks printed_reason'
);

SELECT lives_ok(
  $$
    SELECT public.enqueue_print_jobs(
      '00000000-0000-0000-0000-000000001111',
      ARRAY['invalid'],
      '[]'::jsonb,
      'forced_error'
    )
  $$,
  'TP10 enqueue helper catches internal failures'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.audit_logs
    WHERE action = 'print_enqueue_failed'
      AND entity_id = '00000000-0000-0000-0000-000000001111'
      AND details->>'reason' = 'forced_error'
      AND details->>'error' LIKE '%PRINT_COPY_TYPE_INVALID%'
  ),
  'TP10 enqueue failure records audit evidence'
);

SELECT lives_ok(
  $$
    SELECT public.admin_enqueue_printer_test_job(
      '00000000-0000-0000-0000-00000000b111',
      '00000000-0000-0000-0000-00000000f111'
    )
  $$,
  'TP10 admin destination test enqueues through print_jobs'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.print_jobs
    WHERE restaurant_id = '00000000-0000-0000-0000-00000000b111'
      AND destination_id = '00000000-0000-0000-0000-00000000f111'
      AND order_id IS NULL
      AND payload->>'printed_reason' = 'test_print'
      AND status = 'pending'
  ),
  'TP10 queued test job is order-independent and agent-processable'
);

INSERT INTO public.printer_destinations (
  id,
  restaurant_id,
  name,
  ip,
  port,
  purpose,
  floor_label,
  is_active
)
VALUES (
  '00000000-0000-0000-0000-00000000f555',
  '00000000-0000-0000-0000-00000000b111',
  'Cashier Receipt',
  '192.168.1.40',
  9100,
  'receipt',
  NULL,
  true
)
ON CONFLICT (id) DO UPDATE
SET is_active = true,
    purpose = 'receipt';

INSERT INTO public.payments (
  id,
  restaurant_id,
  order_id,
  amount,
  amount_portion,
  method,
  is_revenue,
  processed_by
)
VALUES (
  '00000000-0000-0000-0000-000000004111',
  '00000000-0000-0000-0000-00000000b111',
  '00000000-0000-0000-0000-000000001111',
  50000,
  50000,
  'CASH',
  true,
  '00000000-0000-0000-0000-00000000a111'
)
ON CONFLICT (id) DO NOTHING;

SELECT lives_ok(
  $$
    SELECT public.enqueue_receipt_print_job(
      '00000000-0000-0000-0000-000000001111',
      false
    )
  $$,
  'TP11 payment receipt enqueue is callable'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.print_jobs
    WHERE order_id = '00000000-0000-0000-0000-000000001111'
      AND copy_type = 'receipt'
      AND batch_no = 1
      AND destination_id = '00000000-0000-0000-0000-00000000f555'
      AND status = 'pending'
  ),
  1::bigint,
  'TP11 receipt batch 1 routes to the receipt destination'
);

SELECT is(
  (
    SELECT payload->>'payment_method'
    FROM public.print_jobs
    WHERE order_id = '00000000-0000-0000-0000-000000001111'
      AND copy_type = 'receipt'
      AND batch_no = 1
  ),
  'CASH',
  'TP11 receipt payload snapshots the payment method'
);

SELECT lives_ok(
  $$
    SELECT public.enqueue_receipt_print_job(
      '00000000-0000-0000-0000-000000001111',
      false
    )
  $$,
  'TP11 automatic receipt enqueue is idempotent'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.print_jobs
    WHERE order_id = '00000000-0000-0000-0000-000000001111'
      AND copy_type = 'receipt'
      AND batch_no = 1
  ),
  1::bigint,
  'TP11 duplicate automatic enqueue keeps one batch 1 receipt'
);

SELECT lives_ok(
  $$
    SELECT public.enqueue_receipt_print_job(
      '00000000-0000-0000-0000-000000001111',
      true
    )
  $$,
  'TP12 manual receipt reprint is callable'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.print_jobs
    WHERE order_id = '00000000-0000-0000-0000-000000001111'
      AND copy_type = 'receipt'
      AND batch_no = 2
      AND destination_id = '00000000-0000-0000-0000-00000000f555'
      AND payload->>'printed_reason' = 'reprint'
  ),
  'TP12 receipt reprint creates a new batch on the receipt destination'
);

UPDATE public.users
SET role = 'cashier',
    restaurant_id = '00000000-0000-0000-0000-00000000b111'
WHERE auth_id = '00000000-0000-0000-0000-00000000a111';

SELECT throws_ok(
  $$
    SELECT public.create_delivery_order(
      '00000000-0000-0000-0000-00000000b111',
      NULL,
      'delivery-null-items'
    )
  $$,
  'P0001',
  'ORDER_ITEMS_REQUIRED',
  'TP13 delivery order rejects null items'
);

SELECT throws_ok(
  $$
    SELECT public.create_delivery_order(
      '00000000-0000-0000-0000-00000000b111',
      '[{"menu_item_id":"not-a-uuid","quantity":1}]'::jsonb,
      'delivery-invalid-item'
    )
  $$,
  'P0001',
  'INVALID_ORDER_ITEM_INPUT',
  'TP13 delivery order rejects malformed item input'
);

SELECT throws_ok(
  $$
    SELECT public.create_delivery_order(
      '00000000-0000-0000-0000-00000000b222',
      '[{"menu_item_id":"00000000-0000-0000-0000-00000000e111","quantity":1}]'::jsonb,
      'delivery-cross-store'
    )
  $$,
  'P0001',
  'DELIVERY_ORDER_CREATE_FORBIDDEN',
  'TP13 delivery order rejects cross-store creation'
);

UPDATE public.users
SET role = 'waiter'
WHERE auth_id = '00000000-0000-0000-0000-00000000a111';

SELECT throws_ok(
  $$
    SELECT public.create_delivery_order(
      '00000000-0000-0000-0000-00000000b111',
      '[{"menu_item_id":"00000000-0000-0000-0000-00000000e111","quantity":1}]'::jsonb,
      'delivery-wrong-role'
    )
  $$,
  'P0001',
  'DELIVERY_ORDER_CREATE_FORBIDDEN',
  'TP13 delivery order is cashier-only'
);

UPDATE public.users
SET role = 'cashier'
WHERE auth_id = '00000000-0000-0000-0000-00000000a111';

CREATE TEMP TABLE delivery_contract_order AS
SELECT (
  public.create_delivery_order(
    '00000000-0000-0000-0000-00000000b111',
    '[{"menu_item_id":"00000000-0000-0000-0000-00000000e111","quantity":1}]'::jsonb,
    'delivery-contract-1'
  )
).id;

SELECT is(
  (
    SELECT id
    FROM delivery_contract_order
  ),
  (
    SELECT (
      public.create_delivery_order(
        '00000000-0000-0000-0000-00000000b111',
        '[{"menu_item_id":"00000000-0000-0000-0000-00000000e111","quantity":1}]'::jsonb,
        'delivery-contract-1'
      )
    ).id
  ),
  'TP13 delivery retry returns the original order'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.pos_client_mutation_attempts
    WHERE store_id = '00000000-0000-0000-0000-00000000b111'
      AND actor_id = '00000000-0000-0000-0000-00000000a111'
      AND client_mutation_id = 'delivery-contract-1'
      AND mutation_type = 'create_delivery_order'
  ),
  1::bigint,
  'TP13 delivery retry keeps one mutation attempt'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.orders o
    JOIN delivery_contract_order d ON d.id = o.id
    WHERE o.sales_channel = 'delivery'
  ),
  1::bigint,
  'TP13 delivery retry keeps one order'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.print_jobs pj
    JOIN delivery_contract_order d ON d.id = pj.order_id
    WHERE pj.copy_type = 'kitchen'
  ),
  1::bigint,
  'TP13 delivery retry keeps one kitchen ticket'
);

SELECT is(
  (
    SELECT concat_ws('/', payload->>'floor_label', payload->>'table_number')
    FROM public.print_jobs pj
    JOIN delivery_contract_order d ON d.id = pj.order_id
    WHERE pj.copy_type = 'kitchen'
    LIMIT 1
  ),
  'DELIVERY/DELIVERY',
  'TP13 kitchen ticket preserves delivery identity'
);

UPDATE public.order_items oi
SET status = 'ready'
FROM delivery_contract_order d
WHERE oi.order_id = d.id;

SELECT public.recalc_order_status(id)
FROM delivery_contract_order;

SELECT is(
  (
    SELECT concat_ws('/', payload->>'floor_label', payload->>'table_number')
    FROM public.print_jobs pj
    JOIN delivery_contract_order d ON d.id = pj.order_id
    WHERE pj.copy_type = 'tray'
    LIMIT 1
  ),
  'DELIVERY/DELIVERY',
  'TP13 tray ticket preserves delivery identity'
);

SELECT is(
  (
    SELECT (public.search_active_order_for_cashier(
      '00000000-0000-0000-0000-00000000b111',
      'giao hàng'
    ))->>'id'
  ),
  (
    SELECT id::text
    FROM delivery_contract_order
  ),
  'TP13 Vietnamese delivery search finds the active order'
);

INSERT INTO public.payments (
  id,
  restaurant_id,
  order_id,
  amount,
  amount_portion,
  method,
  is_revenue,
  processed_by
)
SELECT
  '00000000-0000-0000-0000-000000004222',
  '00000000-0000-0000-0000-00000000b111',
  d.id,
  50000,
  50000,
  'CASH',
  true,
  '00000000-0000-0000-0000-00000000a111'
FROM delivery_contract_order d;

SELECT lives_ok(
  $$
    SELECT public.enqueue_receipt_print_job(
      (SELECT id FROM delivery_contract_order),
      false
    )
  $$,
  'TP13 delivery receipt enqueue is callable'
);

SELECT is(
  (
    SELECT payload->>'table_number'
    FROM public.print_jobs pj
    JOIN delivery_contract_order d ON d.id = pj.order_id
    WHERE pj.copy_type = 'receipt'
    LIMIT 1
  ),
  'DELIVERY',
  'TP13 receipt preserves delivery identity'
);

UPDATE public.orders o
SET status = 'completed'
FROM delivery_contract_order d
WHERE o.id = d.id;

SELECT is(
  (
    SELECT delivery_revenue
    FROM public.v_daily_revenue_by_channel
    WHERE restaurant_id = '00000000-0000-0000-0000-00000000b111'
      AND sale_date = (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
  ),
  50000::numeric,
  'TP13 POS delivery payment is included in delivery revenue'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.external_sales
    WHERE restaurant_id = '00000000-0000-0000-0000-00000000b111'
  ),
  0::bigint,
  'TP13 manual delivery does not create Deliberry external sales'
);

SELECT * FROM finish();

ROLLBACK;
