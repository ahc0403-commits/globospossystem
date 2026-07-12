\set ON_ERROR_STOP on

DO $$
DECLARE
  v_store_count bigint;
  v_dispatched bigint;
BEGIN
  SELECT count(*) INTO v_store_count
  FROM public.restaurants
  WHERE is_active = true
    AND name IN (
      'PHOTO OBJET BIEN HOA',
      'PHOTO OBJET DI AN',
      'PHOTO OBJET LONG THANH',
      'PHOTO OBJET THAO DIEN',
      'PHOTO OBJET QUANG TRUNG',
      'PHOTO OBJET NOW ZONE'
    );
  IF v_store_count <> 6 THEN
    RAISE EXCEPTION 'PHOTO_INTERVAL_PREFLIGHT_STORE_COUNT: expected 6, got %', v_store_count;
  END IF;

  SELECT count(*) INTO v_dispatched
  FROM public.meinvoice_jobs
  WHERE source_system = 'photo_objet_moers'
    AND (
      dispatch_attempts > 0
      OR misa_ref_id IS NOT NULL
      OR transaction_id IS NOT NULL
      OR invoice_number IS NOT NULL
      OR sent_at IS NOT NULL
    );
  IF v_dispatched <> 0 THEN
    RAISE EXCEPTION 'PHOTO_INTERVAL_PREFLIGHT_DISPATCHED_JOBS: %', v_dispatched;
  END IF;
END $$;

SELECT
  (SELECT count(*) FROM public.photo_objet_sales_raw) AS raw_rows_to_backup,
  (SELECT count(*) FROM public.meinvoice_jobs WHERE source_system = 'photo_objet_moers') AS jobs_to_backup,
  (SELECT count(*) FROM public.photo_objet_sales_pull_runs) AS runs_to_backup,
  (SELECT count(*) FROM public.photo_objet_sales WHERE sale_date < DATE '2026-07-01') AS pre_july_sales_to_delete;

SELECT 'PHOTO_INTERVAL_PREFLIGHT_OK' AS result;
