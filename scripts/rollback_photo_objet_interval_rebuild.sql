\set ON_ERROR_STOP on

DO $$
DECLARE
  v_dispatched bigint;
  v_enqueue_function_definition text;
  v_photo_gate_existed boolean;
  v_photo_gate_value text;
  v_photo_gate_description text;
  v_photo_gate_updated_at timestamptz;
  v_photo_gate_updated_by uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.photo_interval_20260712190000_state
    WHERE migration_id = '20260712190000'
      AND cleanup_applied = true
  ) THEN
    RAISE EXCEPTION 'PHOTO_INTERVAL_ROLLBACK_STATE_MISSING';
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
    RAISE EXCEPTION 'PHOTO_INTERVAL_ROLLBACK_DISPATCHED_JOBS: %', v_dispatched;
  END IF;

  SELECT
    enqueue_function_definition,
    photo_gate_existed,
    photo_gate_value,
    photo_gate_description,
    photo_gate_updated_at,
    photo_gate_updated_by
  INTO
    v_enqueue_function_definition,
    v_photo_gate_existed,
    v_photo_gate_value,
    v_photo_gate_description,
    v_photo_gate_updated_at,
    v_photo_gate_updated_by
  FROM public.photo_interval_20260712190000_state
  WHERE migration_id = '20260712190000';

  IF v_enqueue_function_definition IS NULL THEN
    RAISE EXCEPTION 'PHOTO_INTERVAL_ROLLBACK_FUNCTION_BACKUP_MISSING';
  END IF;

  DELETE FROM public.meinvoice_jobs WHERE source_system = 'photo_objet_moers';
  DELETE FROM public.photo_objet_sales_raw;
  DELETE FROM public.photo_objet_sales_pull_runs;
  DELETE FROM public.photo_objet_sales sales
  WHERE sales.sale_date < DATE '2026-07-01'
     OR EXISTS (
       SELECT 1 FROM public.restaurants store
       WHERE store.id = sales.store_id
         AND store.name IN (
           'PHOTO OBJET BIEN HOA', 'PHOTO OBJET DI AN',
           'PHOTO OBJET LONG THANH', 'PHOTO OBJET THAO DIEN',
           'PHOTO OBJET QUANG TRUNG', 'PHOTO OBJET NOW ZONE'
         )
     );

  ALTER TABLE public.photo_objet_sales_raw
    DROP CONSTRAINT IF EXISTS photo_objet_raw_identity_v2_check;
  ALTER TABLE public.photo_objet_sales_raw
    ALTER COLUMN sold_at DROP NOT NULL,
    ALTER COLUMN source_identity_version SET DEFAULT 1;

  INSERT INTO public.photo_objet_sales_pull_runs (
    id, store_id, target_date, collector_method, status, rows_read,
    rows_inserted, rows_duplicate, aggregate_rows, error_message,
    started_at, finished_at, created_at
  )
  SELECT
    id, store_id, target_date, collector_method, status, rows_read,
    rows_inserted, rows_duplicate, aggregate_rows, error_message,
    started_at, finished_at, created_at
  FROM public.photo_interval_20260712190000_runs_backup;

  ALTER TABLE public.photo_objet_sales_raw DISABLE TRIGGER USER;

  INSERT INTO public.photo_objet_sales_raw (
    id, store_id, sale_date, device_name, device_id, sale_time_text, sold_at,
    amount, raw_type, payment_method, buyer_kind, raw_payload, source_hash,
    pull_run_id, meinvoice_job_id, invoice_enqueue_status,
    invoice_enqueue_error, first_seen_at, last_seen_at, created_at, updated_at,
    source_identity_version
  )
  SELECT
    id, store_id, sale_date, device_name, device_id, sale_time_text, sold_at,
    amount, raw_type, payment_method, buyer_kind, raw_payload, source_hash,
    pull_run_id, NULL, invoice_enqueue_status,
    invoice_enqueue_error, first_seen_at, last_seen_at, created_at, updated_at,
    1
  FROM public.photo_interval_20260712190000_raw_backup;

  ALTER TABLE public.photo_objet_sales_raw ENABLE TRIGGER USER;

  INSERT INTO public.meinvoice_jobs
  SELECT * FROM public.photo_interval_20260712190000_jobs_backup;

  UPDATE public.photo_objet_sales_raw raw
  SET meinvoice_job_id = backup.meinvoice_job_id
  FROM public.photo_interval_20260712190000_raw_backup backup
  WHERE backup.id = raw.id;

  INSERT INTO public.photo_objet_sales
  SELECT * FROM public.photo_interval_20260712190000_sales_backup;

  EXECUTE v_enqueue_function_definition;

  IF v_photo_gate_existed THEN
    INSERT INTO public.system_config (
      key, value, description, updated_at, updated_by
    ) VALUES (
      'photo_objet_meinvoice_dispatch_enabled',
      v_photo_gate_value,
      v_photo_gate_description,
      v_photo_gate_updated_at,
      v_photo_gate_updated_by
    )
    ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value,
        description = EXCLUDED.description,
        updated_at = EXCLUDED.updated_at,
        updated_by = EXCLUDED.updated_by;
  ELSE
    DELETE FROM public.system_config
    WHERE key = 'photo_objet_meinvoice_dispatch_enabled';
  END IF;
END $$;

DROP INDEX IF EXISTS public.idx_photo_objet_raw_store_sold_at;
DROP INDEX IF EXISTS public.idx_photo_objet_pull_runs_slot;

ALTER TABLE public.photo_objet_sales_pull_runs
  DROP CONSTRAINT IF EXISTS photo_objet_pull_run_interval_check,
  DROP COLUMN IF EXISTS run_source,
  DROP COLUMN IF EXISTS slot_id,
  DROP COLUMN IF EXISTS slot_date_hcm,
  DROP COLUMN IF EXISTS slot_time_hcm,
  DROP COLUMN IF EXISTS interval_start_at,
  DROP COLUMN IF EXISTS interval_end_at;

ALTER TABLE public.photo_objet_sales_raw
  DROP COLUMN IF EXISTS source_identity_version,
  DROP COLUMN IF EXISTS occurrence_no,
  DROP COLUMN IF EXISTS interval_start_at,
  DROP COLUMN IF EXISTS interval_end_at;

COMMENT ON COLUMN public.photo_objet_sales_raw.source_hash IS
  'Stable idempotency hash built from store, date, device, time, amount, type, row index, and raw row content.';

DROP TABLE public.photo_interval_20260712190000_sales_backup;
DROP TABLE public.photo_interval_20260712190000_runs_backup;
DROP TABLE public.photo_interval_20260712190000_raw_backup;
DROP TABLE public.photo_interval_20260712190000_jobs_backup;
DROP TABLE public.photo_interval_20260712190000_state;

SELECT 'PHOTO_INTERVAL_ROLLBACK_OK' AS result;
