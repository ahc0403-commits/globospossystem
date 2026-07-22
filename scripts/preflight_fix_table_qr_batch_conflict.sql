DO $$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure(
       'public.admin_get_or_create_table_qrs(uuid,uuid[])'
     ) IS NULL THEN
    RAISE EXCEPTION 'TABLE_QR_CONFLICT_FIX_PREFLIGHT_RPC_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.admin_get_or_create_table_qrs(uuid,uuid[])'::regprocedure
  ) INTO v_definition;

  IF v_definition NOT LIKE '%public.require_admin_actor_for_restaurant%'
     OR v_definition NOT LIKE '%ORDER BY t.layout_sort_order, t.table_number, t.id%'
     OR v_definition NOT LIKE '%extensions.gen_random_bytes(24)%' THEN
    RAISE EXCEPTION 'TABLE_QR_CONFLICT_FIX_PREFLIGHT_RPC_CONTRACT_INVALID';
  END IF;

  IF to_regclass('public.table_qr_tokens_one_active') IS NULL THEN
    RAISE EXCEPTION 'TABLE_QR_CONFLICT_FIX_PREFLIGHT_ACTIVE_INDEX_MISSING';
  END IF;
END;
$$;

SELECT 'TABLE_QR_CONFLICT_FIX_PREFLIGHT_OK' AS result;
