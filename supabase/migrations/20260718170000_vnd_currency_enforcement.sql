-- Enforce VND as the only operational transaction currency.
-- The POS production schema has one persisted currency column:
-- public.external_sales.currency. Vendor reference caches remain untouched
-- because they are metadata, not persisted transaction currency.

DO $$
DECLARE
  v_missing integer;
  v_bad integer;
BEGIN
  IF to_regclass('public.external_sales') IS NULL THEN
    RAISE EXCEPTION 'VND_CURRENCY_REQUIRED_RELATION_MISSING';
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
    RAISE EXCEPTION 'VND_CURRENCY_REQUIRED_COLUMN_MISSING: %', v_missing;
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.external_sales
  WHERE NULLIF(btrim(currency), '') IS NULL
     OR upper(btrim(currency)) <> 'VND';
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VND_CURRENCY_NON_VND_EXTERNAL_SALE_BLOCKED: %', v_bad;
  END IF;
END $$;
CREATE TABLE IF NOT EXISTS public.vnd_currency_enforcement_20260718170000_backup (
  source_table text NOT NULL
    CHECK (source_table = 'public.external_sales'),
  row_id uuid NOT NULL,
  original_currency text,
  captured_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  PRIMARY KEY (source_table, row_id)
);

REVOKE ALL ON TABLE public.vnd_currency_enforcement_20260718170000_backup
  FROM PUBLIC, anon, authenticated, service_role;

INSERT INTO public.vnd_currency_enforcement_20260718170000_backup (
  source_table,
  row_id,
  original_currency
)
SELECT 'public.external_sales', id, currency
FROM public.external_sales
WHERE currency IS DISTINCT FROM 'VND'
ON CONFLICT (source_table, row_id) DO NOTHING;

UPDATE public.external_sales
SET currency = 'VND'
WHERE currency IS DISTINCT FROM 'VND';

ALTER TABLE public.external_sales
  ALTER COLUMN currency SET DEFAULT 'VND',
  ALTER COLUMN currency SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.external_sales'::regclass
      AND conname = 'external_sales_currency_vnd_only_20260718170000'
  ) THEN
    ALTER TABLE public.external_sales
      ADD CONSTRAINT external_sales_currency_vnd_only_20260718170000
      CHECK (currency = 'VND') NOT VALID;
  END IF;
END $$;

ALTER TABLE public.external_sales
  VALIDATE CONSTRAINT external_sales_currency_vnd_only_20260718170000;

DO $$
DECLARE
  v_bad integer;
BEGIN
  SELECT count(*) INTO v_bad
  FROM public.external_sales
  WHERE currency IS DISTINCT FROM 'VND';
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VND_CURRENCY_EXTERNAL_SALE_VERIFY_FAILED: %', v_bad;
  END IF;

  SELECT count(*) INTO v_bad
  FROM pg_constraint
  WHERE conrelid = 'public.external_sales'::regclass
    AND conname = 'external_sales_currency_vnd_only_20260718170000'
    AND convalidated;
  IF v_bad <> 1 THEN
    RAISE EXCEPTION 'VND_CURRENCY_CONSTRAINT_VERIFY_FAILED: %', v_bad;
  END IF;
END $$;
