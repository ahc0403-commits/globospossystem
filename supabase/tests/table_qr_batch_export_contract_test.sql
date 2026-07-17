-- Runtime contract for stable table QR get-or-create behavior.
-- Run against a fully migrated database; all fixtures roll back.

\set ON_ERROR_STOP on

BEGIN;

DO $contract$
DECLARE
  v_store uuid := 'f2000000-0000-4000-8000-000000000001';
  v_auth uuid := 'f2000000-0000-4000-8000-000000000002';
  v_user uuid := 'f2000000-0000-4000-8000-000000000003';
  v_table_a uuid := 'f2000000-0000-4000-8000-000000000011';
  v_table_b uuid := 'f2000000-0000-4000-8000-000000000012';
  v_first_token text;
  v_second_token text;
  v_rows integer;
  v_blocked boolean := false;
BEGIN
  INSERT INTO public.restaurants (id, name, address, is_active, brand_id, tax_entity_id)
  SELECT v_store, 'QR Batch Contract Store', 'test', true, r.brand_id, r.tax_entity_id
  FROM public.restaurants r
  WHERE r.brand_id IS NOT NULL AND r.tax_entity_id IS NOT NULL
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_QR_BATCH_TEST_REQUIRES_STORE_FIXTURE';
  END IF;

  INSERT INTO auth.users (id, email)
  VALUES (v_auth, 'qr.batch.contract@globos.test')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.users (id, auth_id, restaurant_id, role, full_name, is_active)
  VALUES (v_user, v_auth, v_store, 'admin', 'QR Batch Admin', true)
  ON CONFLICT (id) DO UPDATE
  SET auth_id = EXCLUDED.auth_id,
      restaurant_id = EXCLUDED.restaurant_id,
      role = 'admin',
      is_active = true;

  INSERT INTO public.user_store_access (
    user_id, store_id, is_primary, is_active, source_type
  ) VALUES (v_user, v_store, true, true, 'direct')
  ON CONFLICT DO NOTHING;

  INSERT INTO public.tables (
    id, restaurant_id, table_number, seat_count, status, floor_label,
    layout_sort_order
  ) VALUES
    (v_table_a, v_store, 'QR-A', 4, 'available', '2F', 8),
    (v_table_b, v_store, 'QR-B', 4, 'available', '3F', 4);

  PERFORM set_config('request.jwt.claim.sub', v_auth::text, true);
  SELECT token INTO v_first_token
  FROM public.admin_get_or_create_table_qrs(v_store, ARRAY[v_table_a]);
  SELECT token INTO v_second_token
  FROM public.admin_get_or_create_table_qrs(v_store, ARRAY[v_table_a]);

  IF v_first_token IS NULL OR v_first_token <> v_second_token THEN
    RAISE EXCEPTION 'TABLE_QR_BATCH_TOKEN_NOT_STABLE';
  END IF;
  IF (
    SELECT count(*)
    FROM public.table_qr_tokens
    WHERE table_id = v_table_a
  ) <> 1 THEN
    RAISE EXCEPTION 'TABLE_QR_BATCH_REPRINT_ROTATED_TOKEN';
  END IF;

  SELECT count(*) INTO v_rows
  FROM public.admin_get_or_create_table_qrs(
    v_store,
    ARRAY[v_table_a, v_table_a, v_table_b]
  );
  IF v_rows <> 2 THEN
    RAISE EXCEPTION 'TABLE_QR_BATCH_DUPLICATE_INPUT_CARDINALITY_INVALID:%', v_rows;
  END IF;

  IF (
    SELECT count(*)
    FROM public.table_qr_tokens
    WHERE table_id IN (v_table_a, v_table_b)
      AND is_active = true
  ) <> 2 THEN
    RAISE EXCEPTION 'TABLE_QR_BATCH_DUPLICATE_INPUT_CREATED_EXTRA_TOKEN';
  END IF;

  IF (
    SELECT string_agg(table_number, ',' ORDER BY layout_sort_order, table_number, table_id)
    FROM public.admin_get_or_create_table_qrs(v_store, NULL)
  ) <> 'QR-B,QR-A' THEN
    RAISE EXCEPTION 'TABLE_QR_BATCH_ORDER_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.table_qr_tokens
    WHERE table_id IN (v_table_a, v_table_b) AND is_active = true
    GROUP BY table_id
    HAVING count(*) <> 1
  ) THEN
    RAISE EXCEPTION 'TABLE_QR_BATCH_ACTIVE_TOKEN_INVARIANT_INVALID';
  END IF;

  BEGIN
    PERFORM public.admin_get_or_create_table_qrs(
      v_store,
      ARRAY['f2000000-0000-4000-8000-000000000099'::uuid]
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%TABLE_SCOPE_INVALID%';
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'TABLE_QR_BATCH_SCOPE_GUARD_MISSING';
  END IF;
END;
$contract$;

ROLLBACK;

SELECT 'TABLE_QR_BATCH_RUNTIME_CONTRACT_OK' AS result;
