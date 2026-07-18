\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing integer;
BEGIN
  IF to_regclass(
       'public.vnd_currency_enforcement_20260718170000_backup'
     ) IS NULL THEN
    RAISE EXCEPTION 'VND_CURRENCY_ROLLBACK_BACKUP_MISSING';
  END IF;

  SELECT count(*) INTO v_missing
  FROM public.vnd_currency_enforcement_20260718170000_backup backup
  WHERE backup.source_table = 'ops.brands'
    AND NOT EXISTS (
      SELECT 1 FROM ops.brands brand WHERE brand.id = backup.row_id
    );
  IF v_missing <> 0 THEN
    RAISE EXCEPTION 'VND_CURRENCY_ROLLBACK_BRAND_ROW_MISSING: %', v_missing;
  END IF;

  SELECT count(*) INTO v_missing
  FROM public.vnd_currency_enforcement_20260718170000_backup backup
  WHERE backup.source_table = 'public.external_sales'
    AND NOT EXISTS (
      SELECT 1
      FROM public.external_sales sale
      WHERE sale.id = backup.row_id
    );
  IF v_missing <> 0 THEN
    RAISE EXCEPTION 'VND_CURRENCY_ROLLBACK_EXTERNAL_ROW_MISSING: %', v_missing;
  END IF;
END $$;

ALTER TABLE ops.brands
  DROP CONSTRAINT IF EXISTS ops_brands_currency_vnd_only_20260718170000;
ALTER TABLE public.external_sales
  DROP CONSTRAINT IF EXISTS external_sales_currency_vnd_only_20260718170000;

ALTER TABLE ops.brands
  ALTER COLUMN currency DROP NOT NULL,
  ALTER COLUMN currency SET DEFAULT '';

ALTER TABLE public.external_sales
  ALTER COLUMN currency SET DEFAULT 'VND',
  ALTER COLUMN currency SET NOT NULL;

UPDATE ops.brands brand
SET currency = backup.original_currency
FROM public.vnd_currency_enforcement_20260718170000_backup backup
WHERE backup.source_table = 'ops.brands'
  AND backup.row_id = brand.id;

UPDATE public.external_sales sale
SET currency = backup.original_currency
FROM public.vnd_currency_enforcement_20260718170000_backup backup
WHERE backup.source_table = 'public.external_sales'
  AND backup.row_id = sale.id;

DO $$
DECLARE
  v_bad integer;
BEGIN
  SELECT count(*) INTO v_bad
  FROM public.vnd_currency_enforcement_20260718170000_backup backup
  JOIN ops.brands brand
    ON backup.source_table = 'ops.brands'
   AND brand.id = backup.row_id
  WHERE brand.currency IS DISTINCT FROM backup.original_currency;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VND_CURRENCY_ROLLBACK_BRAND_RESTORE_FAILED: %', v_bad;
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.vnd_currency_enforcement_20260718170000_backup backup
  JOIN public.external_sales sale
    ON backup.source_table = 'public.external_sales'
   AND sale.id = backup.row_id
  WHERE sale.currency IS DISTINCT FROM backup.original_currency;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VND_CURRENCY_ROLLBACK_EXTERNAL_RESTORE_FAILED: %', v_bad;
  END IF;
END $$;

DROP TABLE public.vnd_currency_enforcement_20260718170000_backup;

DO $$
BEGIN
  IF to_regclass(
       'public.vnd_currency_enforcement_20260718170000_backup'
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'VND_CURRENCY_ROLLBACK_BACKUP_REMAINS';
  END IF;
END $$;

SELECT 'VND_CURRENCY_ROLLBACK_OK' AS result;
