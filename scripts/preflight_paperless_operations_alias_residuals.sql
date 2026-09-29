DO $preflight$
BEGIN
  IF md5(pg_get_functiondef(
    'public.get_paperless_operations_report_pre_meal_start(uuid,timestamptz,timestamptz)'::regprocedure
  )) <> '08ab5dc5e56b033b5802c88aad8d11af' THEN
    RAISE EXCEPTION 'PAPERLESS_ALIAS_BASE_CHANGED';
  END IF;
  IF md5(pg_get_functiondef(
    'public.get_paperless_menu_timing_detail(uuid,timestamptz,timestamptz,text,text,integer,numeric,text)'::regprocedure
  )) <> '0fec65c5a9881bdf03414878f7cac94f' THEN
    RAISE EXCEPTION 'PAPERLESS_DETAIL_BASE_CHANGED';
  END IF;
  IF to_regprocedure('public.bunsik_ledger_menu_alias(uuid,uuid,date)') IS NULL THEN
    RAISE EXCEPTION 'PAPERLESS_ALIAS_HELPER_MISSING';
  END IF;
END $preflight$;
