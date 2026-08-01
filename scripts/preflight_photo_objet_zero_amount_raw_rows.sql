\set ON_ERROR_STOP on

DO $preflight$
DECLARE
  v_amount_constraint text;
BEGIN
  IF to_regclass('public.photo_objet_sales_raw') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_ZERO_AMOUNT_RAW_TABLE_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = 'public.photo_objet_sales_raw'::regclass
      AND attname = 'amount'
      AND atttypid = 'int8'::regtype
      AND attnotnull
      AND NOT attisdropped
  ) THEN
    RAISE EXCEPTION 'PHOTO_ZERO_AMOUNT_AMOUNT_COLUMN_INVALID';
  END IF;

  SELECT lower(pg_get_constraintdef(oid))
  INTO v_amount_constraint
  FROM pg_constraint
  WHERE conrelid = 'public.photo_objet_sales_raw'::regclass
    AND conname = 'photo_objet_sales_raw_amount_check';

  IF v_amount_constraint IS NULL
     OR v_amount_constraint NOT LIKE '%amount > 0%' THEN
    RAISE EXCEPTION 'PHOTO_ZERO_AMOUNT_PRIOR_CONSTRAINT_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.photo_objet_sales_raw WHERE amount <= 0
  ) THEN
    RAISE EXCEPTION 'PHOTO_ZERO_AMOUNT_PRIOR_DATA_INVALID';
  END IF;
END
$preflight$;

SELECT 'Photo Objet zero-amount raw-row preflight passed' AS result;
