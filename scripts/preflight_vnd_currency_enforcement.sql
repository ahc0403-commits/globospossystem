\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing integer;
  v_bad integer;
BEGIN
  IF to_regclass('public.external_sales') IS NULL THEN
    RAISE EXCEPTION 'VND_CURRENCY_PREFLIGHT_RELATION_MISSING';
  END IF;

  SELECT count(*) INTO v_missing
  FROM (
    VALUES
      ('public', 'external_sales', 'id'),
      ('public', 'external_sales', 'currency')
  ) required(table_schema, table_name, column_name)
  LEFT JOIN information_schema.columns column_info
    ON column_info.table_schema = required.table_schema
   AND column_info.table_name = required.table_name
   AND column_info.column_name = required.column_name
  WHERE column_info.column_name IS NULL;

  IF v_missing <> 0 THEN
    RAISE EXCEPTION 'VND_CURRENCY_PREFLIGHT_COLUMN_MISSING: %', v_missing;
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.external_sales
  WHERE NULLIF(btrim(currency), '') IS NULL
     OR upper(btrim(currency)) <> 'VND';
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VND_CURRENCY_PREFLIGHT_NON_VND_EXTERNAL_SALE: %', v_bad;
  END IF;
END $$;

SELECT 'VND_CURRENCY_PREFLIGHT_OK' AS result;
