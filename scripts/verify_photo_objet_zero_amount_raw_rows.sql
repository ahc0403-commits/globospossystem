\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_amount_constraint text;
BEGIN
  SELECT lower(pg_get_constraintdef(oid))
  INTO v_amount_constraint
  FROM pg_constraint
  WHERE conrelid = 'public.photo_objet_sales_raw'::regclass
    AND conname = 'photo_objet_sales_raw_amount_check';

  IF v_amount_constraint IS NULL
     OR v_amount_constraint NOT LIKE '%amount >= 0%' THEN
    RAISE EXCEPTION 'PHOTO_ZERO_AMOUNT_CONSTRAINT_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgrelid = 'public.photo_objet_sales_raw'::regclass
      AND tgname = 'trg_enqueue_photo_objet_meinvoice_job'
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'PHOTO_ZERO_AMOUNT_INVOICE_TRIGGER_PRESENT';
  END IF;
END
$verify$;

SELECT 'Photo Objet zero-amount raw-row verification passed' AS result;
