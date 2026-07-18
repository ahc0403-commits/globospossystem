\set ON_ERROR_STOP on

DO $$
DECLARE
  v_bad integer;
BEGIN
  IF to_regclass('ops.brands') IS NULL
     OR to_regclass('public.external_sales') IS NULL
     OR to_regclass(
       'public.vnd_currency_enforcement_20260718170000_backup'
     ) IS NULL THEN
    RAISE EXCEPTION 'VND_CURRENCY_VERIFY_RELATION_MISSING';
  END IF;

  SELECT count(*) INTO v_bad
  FROM (
    VALUES
      ('ops', 'brands'),
      ('public', 'external_sales')
  ) expected(table_schema, table_name)
  LEFT JOIN information_schema.columns column_info
    ON column_info.table_schema = expected.table_schema
   AND column_info.table_name = expected.table_name
   AND column_info.column_name = 'currency'
   AND column_info.is_nullable = 'NO'
   AND column_info.column_default = '''VND''::text'
  WHERE column_info.column_name IS NULL;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VND_CURRENCY_VERIFY_COLUMN_CONTRACT_FAILED: %', v_bad;
  END IF;

  SELECT count(*) INTO v_bad
  FROM ops.brands
  WHERE currency IS DISTINCT FROM 'VND';
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VND_CURRENCY_VERIFY_BRAND_DATA_FAILED: %', v_bad;
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.external_sales
  WHERE currency IS DISTINCT FROM 'VND';
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VND_CURRENCY_VERIFY_EXTERNAL_DATA_FAILED: %', v_bad;
  END IF;

  SELECT count(*) INTO v_bad
  FROM pg_constraint
  WHERE (conrelid, conname) IN (
    (
      'ops.brands'::regclass,
      'ops_brands_currency_vnd_only_20260718170000'
    ),
    (
      'public.external_sales'::regclass,
      'external_sales_currency_vnd_only_20260718170000'
    )
  )
    AND contype = 'c'
    AND convalidated;
  IF v_bad <> 2 THEN
    RAISE EXCEPTION 'VND_CURRENCY_VERIFY_CONSTRAINT_FAILED: %', v_bad;
  END IF;

  IF has_table_privilege(
       'anon',
       'public.vnd_currency_enforcement_20260718170000_backup',
       'SELECT,INSERT,UPDATE,DELETE'
     )
     OR has_table_privilege(
       'authenticated',
       'public.vnd_currency_enforcement_20260718170000_backup',
       'SELECT,INSERT,UPDATE,DELETE'
     )
     OR has_table_privilege(
       'service_role',
       'public.vnd_currency_enforcement_20260718170000_backup',
       'SELECT,INSERT,UPDATE,DELETE'
     ) THEN
    RAISE EXCEPTION 'VND_CURRENCY_VERIFY_BACKUP_ACL_FAILED';
  END IF;
END $$;

SELECT 'VND_CURRENCY_VERIFY_OK' AS result;
