DO $$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure(
       'public.admin_get_or_create_table_qrs(uuid,uuid[])'
     ) IS NULL THEN
    RAISE EXCEPTION 'TABLE_QR_RETURNING_FIX_PREFLIGHT_RPC_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.admin_get_or_create_table_qrs(uuid,uuid[])'::regprocedure
  ) INTO v_definition;

  IF v_definition NOT LIKE '%ON CONFLICT DO NOTHING%'
     OR v_definition NOT LIKE '%RETURNING id, restaurant_id, table_id%' THEN
    RAISE EXCEPTION 'TABLE_QR_RETURNING_FIX_PREFLIGHT_EXPECTED_PRIOR_STATE_MISSING';
  END IF;

  IF to_regclass('public.table_qr_tokens_one_active') IS NULL THEN
    RAISE EXCEPTION 'TABLE_QR_RETURNING_FIX_PREFLIGHT_ACTIVE_INDEX_MISSING';
  END IF;
END;
$$;

SELECT 'TABLE_QR_RETURNING_FIX_PREFLIGHT_OK' AS result;
