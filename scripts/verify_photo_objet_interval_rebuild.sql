\set ON_ERROR_STOP on

DO $$
DECLARE
  v_state boolean;
  v_backup_captured boolean;
  v_gate text;
  v_invalid bigint;
BEGIN
  SELECT cleanup_applied, backup_captured INTO v_state, v_backup_captured
  FROM public.photo_interval_20260712190000_state
  WHERE migration_id = '20260712190000';
  IF v_state IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'PHOTO_INTERVAL_VERIFY_STATE_MISSING';
  END IF;
  IF v_backup_captured IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'PHOTO_INTERVAL_VERIFY_BACKUP_STATE_MISSING';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.photo_interval_20260712190000_raw_backup)
     OR NOT EXISTS (SELECT 1 FROM public.photo_interval_20260712190000_jobs_backup) THEN
    RAISE EXCEPTION 'PHOTO_INTERVAL_VERIFY_BACKUP_EMPTY';
  END IF;

  SELECT value INTO v_gate
  FROM public.system_config
  WHERE key = 'photo_objet_meinvoice_dispatch_enabled';
  IF v_gate IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 'PHOTO_INTERVAL_VERIFY_DISPATCH_GATE: %', v_gate;
  END IF;

  SELECT count(*) INTO v_invalid
  FROM public.photo_objet_sales_raw raw
  WHERE raw.source_identity_version <> 2
     OR raw.sold_at IS NULL
     OR raw.occurrence_no IS NULL
     OR raw.interval_start_at IS NULL
     OR raw.interval_end_at <= raw.interval_start_at
     OR raw.sold_at < raw.interval_start_at
     OR raw.sold_at >= raw.interval_end_at;
  IF v_invalid <> 0 THEN
    RAISE EXCEPTION 'PHOTO_INTERVAL_VERIFY_INVALID_RAW_ROWS: %', v_invalid;
  END IF;

  SELECT count(*) INTO v_invalid
  FROM public.meinvoice_jobs job
  WHERE job.source_system = 'photo_objet_moers'
    AND job.status <> 'pending_manual_config';
  IF v_invalid <> 0 THEN
    RAISE EXCEPTION 'PHOTO_INTERVAL_VERIFY_RELEASED_JOBS: %', v_invalid;
  END IF;

  SELECT count(*) INTO v_invalid
  FROM public.photo_objet_sales_raw raw
  LEFT JOIN public.meinvoice_jobs job
    ON job.id = raw.meinvoice_job_id
   AND job.source_system = 'photo_objet_moers'
  WHERE raw.invoice_enqueue_status = 'queued'
    AND job.id IS NULL;
  IF v_invalid <> 0 THEN
    RAISE EXCEPTION 'PHOTO_INTERVAL_VERIFY_MISSING_JOBS: %', v_invalid;
  END IF;

  SELECT count(*) INTO v_invalid
  FROM public.photo_objet_sales
  WHERE sale_date < DATE '2026-07-01';
  IF v_invalid <> 0 THEN
    RAISE EXCEPTION 'PHOTO_INTERVAL_VERIFY_PRE_JULY_SALES_REMAIN: %', v_invalid;
  END IF;
END $$;

SELECT
  raw.sale_date,
  count(*) AS transaction_count,
  sum(raw.amount) AS gross_sales,
  count(DISTINCT raw.source_hash) AS distinct_source_hashes
FROM public.photo_objet_sales_raw raw
GROUP BY raw.sale_date
ORDER BY raw.sale_date;

SELECT 'PHOTO_INTERVAL_VERIFY_OK' AS result;
