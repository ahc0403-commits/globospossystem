DO $$
BEGIN
  IF to_regclass('public.external_sales') IS NULL
     OR to_regclass('public.delivery_settlements') IS NULL
     OR to_regclass('public.delivery_settlement_items') IS NULL THEN
    RAISE EXCEPTION 'DELIBERRY_RETIREMENT_BASE_TABLES_MISSING';
  END IF;
END;
$$;
SELECT 'DELIBERRY_RETIREMENT_PREFLIGHT_OK' AS result;
