DO $$
DECLARE
  v_relation text;
BEGIN
  FOREACH v_relation IN ARRAY ARRAY[
    'public.restaurants',
    'public.tables',
    'public.table_qr_tokens',
    'public.audit_logs'
  ] LOOP
    IF to_regclass(v_relation) IS NULL THEN
      RAISE EXCEPTION 'TABLE_QR_BATCH_PREFLIGHT_MISSING_RELATION:%', v_relation;
    END IF;
  END LOOP;

  IF to_regprocedure('public.require_admin_actor_for_restaurant(uuid)') IS NULL
     OR to_regprocedure('public.admin_generate_table_qr(uuid)') IS NULL
     OR to_regprocedure('extensions.gen_random_bytes(integer)') IS NULL THEN
    RAISE EXCEPTION 'TABLE_QR_BATCH_PREFLIGHT_MISSING_RPC_DEPENDENCY';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM (VALUES
      ('restaurants', 'id'),
      ('restaurants', 'name'),
      ('tables', 'id'),
      ('tables', 'restaurant_id'),
      ('tables', 'table_number'),
      ('tables', 'floor_label'),
      ('tables', 'layout_sort_order'),
      ('table_qr_tokens', 'id'),
      ('table_qr_tokens', 'restaurant_id'),
      ('table_qr_tokens', 'table_id'),
      ('table_qr_tokens', 'token'),
      ('table_qr_tokens', 'is_active'),
      ('table_qr_tokens', 'created_by'),
      ('table_qr_tokens', 'created_at'),
      ('audit_logs', 'actor_id'),
      ('audit_logs', 'action'),
      ('audit_logs', 'entity_type'),
      ('audit_logs', 'entity_id'),
      ('audit_logs', 'details')
    ) required(table_name, column_name)
    WHERE NOT EXISTS (
      SELECT 1
      FROM information_schema.columns c
      WHERE c.table_schema = 'public'
        AND c.table_name = required.table_name
        AND c.column_name = required.column_name
    )
  ) THEN
    RAISE EXCEPTION 'TABLE_QR_BATCH_PREFLIGHT_MISSING_COLUMN';
  END IF;

  IF to_regclass('public.table_qr_tokens_one_active') IS NULL THEN
    RAISE EXCEPTION 'TABLE_QR_BATCH_PREFLIGHT_ACTIVE_INDEX_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.table_qr_tokens
    WHERE is_active = true
    GROUP BY table_id
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'TABLE_QR_BATCH_PREFLIGHT_DUPLICATE_ACTIVE_TOKEN';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.table_qr_tokens q
    JOIN public.tables t ON t.id = q.table_id
    WHERE q.restaurant_id <> t.restaurant_id
  ) THEN
    RAISE EXCEPTION 'TABLE_QR_BATCH_PREFLIGHT_TOKEN_SCOPE_MISMATCH';
  END IF;
END;
$$;

SELECT 'TABLE_QR_BATCH_PREFLIGHT_OK' AS result;
