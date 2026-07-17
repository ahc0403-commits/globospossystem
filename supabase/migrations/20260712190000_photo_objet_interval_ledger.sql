-- Reset the polluted Photo Objet collector ledger and install interval-safe identity.
-- The immutable backup is created before deletion. Production execution must use
-- psql ON_ERROR_STOP inside one transaction.

CREATE TABLE IF NOT EXISTS public.photo_interval_20260712190000_state (
  migration_id text PRIMARY KEY,
  backup_captured boolean NOT NULL DEFAULT false,
  cleanup_applied boolean NOT NULL DEFAULT false,
  enqueue_function_definition text,
  photo_gate_existed boolean NOT NULL DEFAULT false,
  photo_gate_value text,
  photo_gate_description text,
  photo_gate_updated_at timestamptz,
  photo_gate_updated_by uuid,
  applied_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.photo_interval_20260712190000_jobs_backup
  AS TABLE public.meinvoice_jobs WITH NO DATA;
CREATE TABLE IF NOT EXISTS public.photo_interval_20260712190000_raw_backup
  AS TABLE public.photo_objet_sales_raw WITH NO DATA;
CREATE TABLE IF NOT EXISTS public.photo_interval_20260712190000_runs_backup
  AS TABLE public.photo_objet_sales_pull_runs WITH NO DATA;
CREATE TABLE IF NOT EXISTS public.photo_interval_20260712190000_sales_backup
  AS TABLE public.photo_objet_sales WITH NO DATA;

-- Backup snapshots and rollback definitions are owner-only control-plane data.
-- Explicit revokes are required because Supabase default ACLs may grant broad
-- access to newly created tables.
ALTER TABLE public.photo_interval_20260712190000_jobs_backup
  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_interval_20260712190000_jobs_backup
  FORCE ROW LEVEL SECURITY;
ALTER TABLE public.photo_interval_20260712190000_raw_backup
  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_interval_20260712190000_raw_backup
  FORCE ROW LEVEL SECURITY;
ALTER TABLE public.photo_interval_20260712190000_runs_backup
  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_interval_20260712190000_runs_backup
  FORCE ROW LEVEL SECURITY;
ALTER TABLE public.photo_interval_20260712190000_sales_backup
  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_interval_20260712190000_sales_backup
  FORCE ROW LEVEL SECURITY;
ALTER TABLE public.photo_interval_20260712190000_state
  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_interval_20260712190000_state
  FORCE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE
  public.photo_interval_20260712190000_jobs_backup,
  public.photo_interval_20260712190000_raw_backup,
  public.photo_interval_20260712190000_runs_backup,
  public.photo_interval_20260712190000_sales_backup,
  public.photo_interval_20260712190000_state
FROM PUBLIC, anon, authenticated, service_role;

INSERT INTO public.photo_interval_20260712190000_state (migration_id)
VALUES ('20260712190000')
ON CONFLICT (migration_id) DO NOTHING;

DO $$
DECLARE
  v_dispatched bigint;
BEGIN
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
    RAISE EXCEPTION
      'PHOTO_INTERVAL_PREFLIGHT_DISPATCHED_JOBS: % Photo jobs have external dispatch evidence',
      v_dispatched;
  END IF;

  IF NOT (
    SELECT backup_captured
    FROM public.photo_interval_20260712190000_state
    WHERE migration_id = '20260712190000'
  ) THEN
    UPDATE public.photo_interval_20260712190000_state
    SET enqueue_function_definition = pg_get_functiondef(
          'public.enqueue_photo_objet_meinvoice_job(uuid)'::regprocedure
        ),
        photo_gate_existed = EXISTS (
          SELECT 1 FROM public.system_config
          WHERE key = 'photo_objet_meinvoice_dispatch_enabled'
        ),
        photo_gate_value = (
          SELECT value FROM public.system_config
          WHERE key = 'photo_objet_meinvoice_dispatch_enabled'
        ),
        photo_gate_description = (
          SELECT description FROM public.system_config
          WHERE key = 'photo_objet_meinvoice_dispatch_enabled'
        ),
        photo_gate_updated_at = (
          SELECT updated_at FROM public.system_config
          WHERE key = 'photo_objet_meinvoice_dispatch_enabled'
        ),
        photo_gate_updated_by = (
          SELECT updated_by FROM public.system_config
          WHERE key = 'photo_objet_meinvoice_dispatch_enabled'
        )
    WHERE migration_id = '20260712190000';

    INSERT INTO public.photo_interval_20260712190000_jobs_backup
    SELECT * FROM public.meinvoice_jobs
    WHERE source_system = 'photo_objet_moers';

    INSERT INTO public.photo_interval_20260712190000_raw_backup
    SELECT * FROM public.photo_objet_sales_raw;

    INSERT INTO public.photo_interval_20260712190000_runs_backup
    SELECT * FROM public.photo_objet_sales_pull_runs;

    INSERT INTO public.photo_interval_20260712190000_sales_backup
    SELECT sales.*
    FROM public.photo_objet_sales sales
    LEFT JOIN public.restaurants store ON store.id = sales.store_id
    WHERE sales.sale_date < DATE '2026-07-01'
       OR store.name IN (
         'PHOTO OBJET BIEN HOA',
         'PHOTO OBJET DI AN',
         'PHOTO OBJET LONG THANH',
         'PHOTO OBJET THAO DIEN',
         'PHOTO OBJET QUANG TRUNG',
         'PHOTO OBJET NOW ZONE'
       );

    UPDATE public.photo_interval_20260712190000_state
    SET backup_captured = true
    WHERE migration_id = '20260712190000';
  END IF;

  IF NOT (
    SELECT cleanup_applied
    FROM public.photo_interval_20260712190000_state
    WHERE migration_id = '20260712190000'
  ) THEN

    DELETE FROM public.meinvoice_jobs
    WHERE source_system = 'photo_objet_moers';

    DELETE FROM public.photo_objet_sales_raw;
    DELETE FROM public.photo_objet_sales_pull_runs;

    DELETE FROM public.photo_objet_sales sales
    WHERE sales.sale_date < DATE '2026-07-01'
       OR EXISTS (
        SELECT 1
        FROM public.restaurants store
        WHERE store.id = sales.store_id
          AND store.name IN (
          'PHOTO OBJET BIEN HOA',
          'PHOTO OBJET DI AN',
          'PHOTO OBJET LONG THANH',
          'PHOTO OBJET THAO DIEN',
          'PHOTO OBJET QUANG TRUNG',
          'PHOTO OBJET NOW ZONE'
        )
      );

    UPDATE public.photo_interval_20260712190000_state
    SET cleanup_applied = true,
        applied_at = now()
    WHERE migration_id = '20260712190000';
  END IF;
END $$;

ALTER TABLE public.photo_objet_sales_pull_runs
  ADD COLUMN IF NOT EXISTS run_source text,
  ADD COLUMN IF NOT EXISTS slot_id text,
  ADD COLUMN IF NOT EXISTS slot_date_hcm date,
  ADD COLUMN IF NOT EXISTS slot_time_hcm time,
  ADD COLUMN IF NOT EXISTS interval_start_at timestamptz,
  ADD COLUMN IF NOT EXISTS interval_end_at timestamptz;

ALTER TABLE public.photo_objet_sales_raw
  ADD COLUMN IF NOT EXISTS source_identity_version integer NOT NULL DEFAULT 2,
  ADD COLUMN IF NOT EXISTS occurrence_no integer,
  ADD COLUMN IF NOT EXISTS interval_start_at timestamptz,
  ADD COLUMN IF NOT EXISTS interval_end_at timestamptz;

ALTER TABLE public.photo_objet_sales_raw
  ALTER COLUMN source_identity_version SET DEFAULT 2,
  ALTER COLUMN sold_at SET NOT NULL;

DO $$
BEGIN
  ALTER TABLE public.photo_objet_sales_pull_runs
    ADD CONSTRAINT photo_objet_pull_run_interval_check
    CHECK (
      interval_start_at IS NULL
      OR (interval_end_at IS NOT NULL AND interval_end_at > interval_start_at)
    );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  ALTER TABLE public.photo_objet_sales_raw
    ADD CONSTRAINT photo_objet_raw_identity_v2_check
    CHECK (
      source_identity_version = 2
      AND occurrence_no > 0
      AND interval_start_at IS NOT NULL
      AND interval_end_at > interval_start_at
      AND sold_at >= interval_start_at
      AND sold_at < interval_end_at
    );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

CREATE INDEX IF NOT EXISTS idx_photo_objet_pull_runs_slot
  ON public.photo_objet_sales_pull_runs (store_id, slot_id)
  WHERE slot_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_photo_objet_raw_store_sold_at
  ON public.photo_objet_sales_raw (store_id, sold_at);

COMMENT ON COLUMN public.photo_objet_sales_pull_runs.interval_start_at IS
  'Inclusive intended collection boundary derived from the scheduled slot.';
COMMENT ON COLUMN public.photo_objet_sales_pull_runs.interval_end_at IS
  'Exclusive intended collection boundary derived from the scheduled slot.';
COMMENT ON COLUMN public.photo_objet_sales_raw.source_identity_version IS
  'Version 2 excludes workbook row order from identity and uses occurrence_no for identical rows.';
COMMENT ON COLUMN public.photo_objet_sales_raw.occurrence_no IS
  'One-based multiplicity among rows with the same canonical store/device/time/amount/type identity.';
COMMENT ON COLUMN public.photo_objet_sales_raw.source_hash IS
  'Stable idempotency hash. Version 2 uses canonical sale fields and occurrence_no, never workbook row index.';

INSERT INTO public.system_config (key, value, description)
VALUES (
  'photo_objet_meinvoice_dispatch_enabled',
  'false',
  'Dedicated Photo Objet MISA release gate. Keep false until rebuilt history and live interval collection are verified.'
)
ON CONFLICT (key) DO UPDATE
SET value = 'false',
    description = EXCLUDED.description,
    updated_at = now(),
    updated_by = NULL;

CREATE OR REPLACE FUNCTION public.enqueue_photo_objet_meinvoice_job(
  p_raw_sale_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_raw public.photo_objet_sales_raw%ROWTYPE;
  v_tax_entity_id uuid;
  v_tax_code text;
  v_config_status text;
  v_status text := 'pending_manual_config';
  v_job_id uuid;
BEGIN
  SELECT * INTO v_raw
  FROM public.photo_objet_sales_raw
  WHERE id = p_raw_sale_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PHOTO_OBJET_RAW_SALE_NOT_FOUND';
  END IF;

  SELECT r.tax_entity_id, te.tax_code
  INTO v_tax_entity_id, v_tax_code
  FROM public.restaurants r
  JOIN public.tax_entity te ON te.id = r.tax_entity_id
  WHERE r.id = v_raw.store_id;

  IF v_tax_entity_id IS NULL OR v_tax_code = 'PLACEHOLDER_DEV_000' THEN
    UPDATE public.photo_objet_sales_raw
    SET invoice_enqueue_status = 'skipped',
        invoice_enqueue_error = 'TAX_ENTITY_NOT_READY',
        updated_at = now()
    WHERE id = v_raw.id;
    RETURN NULL;
  END IF;

  SELECT COALESCE(m.integration_status, 'needs_vendor_activation')
  INTO v_config_status
  FROM public.meinvoice_tax_entity_config m
  WHERE m.tax_entity_id = v_tax_entity_id;

  v_status := CASE
    WHEN COALESCE(v_config_status, 'needs_vendor_activation') = 'active'
     AND COALESCE((
       SELECT value = 'true'
       FROM public.system_config
       WHERE key = 'meinvoice_dispatch_enabled'
     ), false)
     AND COALESCE((
       SELECT value = 'true'
       FROM public.system_config
       WHERE key = 'photo_objet_meinvoice_dispatch_enabled'
     ), false)
      THEN 'pending'
    ELSE 'pending_manual_config'
  END;

  INSERT INTO public.meinvoice_jobs (
    order_id,
    source_system,
    source_table,
    source_id,
    source_key,
    source_snapshot,
    store_id,
    tax_entity_id,
    buyer_kind,
    buyer_snapshot,
    payment_method_snapshot,
    payment_summary,
    line_items_snapshot,
    status
  )
  VALUES (
    NULL,
    'photo_objet_moers',
    'photo_objet_sales_raw',
    v_raw.id,
    v_raw.source_hash,
    jsonb_build_object(
      'source', 'photo_objet_moers',
      'raw_sale_id', v_raw.id,
      'store_id', v_raw.store_id,
      'sale_date', v_raw.sale_date,
      'device_id', COALESCE(v_raw.device_id, ''),
      'device_name', v_raw.device_name,
      'sale_time_text', COALESCE(v_raw.sale_time_text, ''),
      'source_hash', v_raw.source_hash,
      'source_identity_version', v_raw.source_identity_version,
      'occurrence_no', v_raw.occurrence_no
    ),
    v_raw.store_id,
    v_tax_entity_id,
    'anonymous',
    jsonb_build_object(
      'customer_name', 'Người mua không lấy hóa đơn',
      'source', 'photo_objet_moers'
    ),
    public.meinvoice_payment_method_label(v_tax_entity_id, ARRAY['CASH']::text[]),
    jsonb_build_array(
      jsonb_build_object(
        'source', 'photo_objet_moers',
        'raw_sale_id', v_raw.id,
        'method', 'CASH',
        'amount', v_raw.amount,
        'created_at', v_raw.sold_at
      )
    ),
    jsonb_build_array(
      jsonb_build_object(
        'order_item_id', v_raw.id,
        'item_type', 'photo_objet_sale',
        'display_name', 'Photo Objet sale - ' || v_raw.device_name,
        'quantity', 1,
        'unit_price', v_raw.amount,
        'vat_rate', 0,
        'vat_amount', 0,
        'total_amount_ex_tax', v_raw.amount,
        'paying_amount_inc_tax', v_raw.amount
      )
    ),
    v_status
  )
  ON CONFLICT (source_system, source_key) DO UPDATE
  SET source_id = EXCLUDED.source_id,
      source_snapshot = EXCLUDED.source_snapshot,
      updated_at = now()
  RETURNING id INTO v_job_id;

  UPDATE public.photo_objet_sales_raw
  SET meinvoice_job_id = v_job_id,
      invoice_enqueue_status = 'queued',
      invoice_enqueue_error = NULL,
      updated_at = now()
  WHERE id = v_raw.id;

  RETURN v_job_id;
END;
$$;

COMMENT ON FUNCTION public.enqueue_photo_objet_meinvoice_job(uuid) IS
  'Queues one Photo Objet MISA job per stable raw sale and requires the dedicated Photo dispatch gate.';
