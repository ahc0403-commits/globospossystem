-- Photo Objet Moers sales raw ledger and meInvoice queue bridge.
--
-- D7 is intentionally controlled by the collector runtime config, not by this
-- schema. This migration adds source-safe meInvoice jobs so Photo Objet cash
-- sales can share the existing async MISA dispatcher without creating POS
-- orders or depending on live MISA availability.

ALTER TABLE public.meinvoice_jobs
  ALTER COLUMN order_id DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS source_system text NOT NULL DEFAULT 'restaurant_pos',
  ADD COLUMN IF NOT EXISTS source_table text,
  ADD COLUMN IF NOT EXISTS source_id uuid,
  ADD COLUMN IF NOT EXISTS source_key text,
  ADD COLUMN IF NOT EXISTS source_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb;

UPDATE public.meinvoice_jobs
SET source_table = COALESCE(source_table, 'orders'),
    source_id = COALESCE(source_id, order_id),
    source_key = COALESCE(source_key, 'orders:' || order_id::text),
    source_snapshot = CASE
      WHEN source_snapshot = '{}'::jsonb AND order_id IS NOT NULL THEN
        jsonb_build_object('source', 'restaurant_pos', 'order_id', order_id)
      ELSE source_snapshot
    END
WHERE source_system = 'restaurant_pos'
  AND order_id IS NOT NULL;

DO $$
BEGIN
  ALTER TABLE public.meinvoice_jobs
    ADD CONSTRAINT meinvoice_jobs_source_system_check
    CHECK (source_system IN ('restaurant_pos', 'photo_objet_moers'));
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  ALTER TABLE public.meinvoice_jobs
    ADD CONSTRAINT meinvoice_jobs_source_key_unique
    UNIQUE (source_system, source_key);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

COMMENT ON COLUMN public.meinvoice_jobs.source_system IS
  'Origin of the invoiceable sale. restaurant_pos uses orders; photo_objet_moers uses photo_objet_sales_raw.';
COMMENT ON COLUMN public.meinvoice_jobs.source_key IS
  'Idempotency key for non-order sources. Photo Objet uses the Moers raw source_hash.';
COMMENT ON COLUMN public.meinvoice_jobs.source_snapshot IS
  'Safe source metadata snapshot. Do not store credentials or raw MISA responses here.';

CREATE TABLE IF NOT EXISTS public.photo_objet_sales_pull_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  target_date date NOT NULL,
  collector_method text NOT NULL DEFAULT 'excel'
    CHECK (collector_method IN ('excel', 'html_scrape', 'internal_endpoint')),
  status text NOT NULL DEFAULT 'started'
    CHECK (status IN ('started', 'success', 'failed', 'partial')),
  rows_read integer NOT NULL DEFAULT 0 CHECK (rows_read >= 0),
  rows_inserted integer NOT NULL DEFAULT 0 CHECK (rows_inserted >= 0),
  rows_duplicate integer NOT NULL DEFAULT 0 CHECK (rows_duplicate >= 0),
  aggregate_rows integer NOT NULL DEFAULT 0 CHECK (aggregate_rows >= 0),
  error_message text,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.photo_objet_sales_pull_runs IS
  'Operational ledger of each Moers Photo Objet sales pull attempt.';

CREATE INDEX IF NOT EXISTS idx_photo_objet_sales_pull_runs_store_started
  ON public.photo_objet_sales_pull_runs (store_id, started_at DESC);

CREATE TABLE IF NOT EXISTS public.photo_objet_sales_raw (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  sale_date date NOT NULL,
  device_name text NOT NULL,
  device_id text,
  sale_time_text text,
  sold_at timestamptz,
  amount bigint NOT NULL CHECK (amount > 0),
  raw_type text,
  payment_method text NOT NULL DEFAULT 'CASH' CHECK (payment_method = 'CASH'),
  buyer_kind text NOT NULL DEFAULT 'anonymous' CHECK (buyer_kind = 'anonymous'),
  raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  source_hash text NOT NULL,
  pull_run_id uuid REFERENCES public.photo_objet_sales_pull_runs(id)
    ON DELETE SET NULL,
  meinvoice_job_id uuid REFERENCES public.meinvoice_jobs(id) ON DELETE SET NULL,
  invoice_enqueue_status text NOT NULL DEFAULT 'pending'
    CHECK (invoice_enqueue_status IN ('pending', 'queued', 'skipped', 'failed')),
  invoice_enqueue_error text,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_hash)
);

COMMENT ON TABLE public.photo_objet_sales_raw IS
  'Append/unique Moers Photo Objet sales ledger. This is the source of truth for MISA invoice queueing.';
COMMENT ON COLUMN public.photo_objet_sales_raw.source_hash IS
  'Stable idempotency hash built from store, date, device, time, amount, type, row index, and raw row content.';
COMMENT ON COLUMN public.photo_objet_sales_raw.payment_method IS
  'Photo Objet sales are treated as cash; VNPAY/QR wallet data must not be mixed into this ledger.';

CREATE INDEX IF NOT EXISTS idx_photo_objet_sales_raw_store_date
  ON public.photo_objet_sales_raw (store_id, sale_date DESC);
CREATE INDEX IF NOT EXISTS idx_photo_objet_sales_raw_invoice_status
  ON public.photo_objet_sales_raw (invoice_enqueue_status, created_at);
CREATE INDEX IF NOT EXISTS idx_photo_objet_sales_raw_meinvoice_job
  ON public.photo_objet_sales_raw (meinvoice_job_id);

ALTER TABLE public.photo_objet_sales_pull_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_objet_sales_raw ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "photo_objet_sales_pull_runs_select_scope"
  ON public.photo_objet_sales_pull_runs;
CREATE POLICY "photo_objet_sales_pull_runs_select_scope"
  ON public.photo_objet_sales_pull_runs
  FOR SELECT
  TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id = photo_objet_sales_pull_runs.store_id
    )
  );

DROP POLICY IF EXISTS "photo_objet_sales_raw_select_scope"
  ON public.photo_objet_sales_raw;
CREATE POLICY "photo_objet_sales_raw_select_scope"
  ON public.photo_objet_sales_raw
  FOR SELECT
  TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id = photo_objet_sales_raw.store_id
    )
  );

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
  SELECT *
  INTO v_raw
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
      'source_hash', v_raw.source_hash
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
        'created_at', COALESCE(v_raw.sold_at, v_raw.first_seen_at)
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
  'Creates exactly one meInvoice job for a new Photo Objet Moers raw sale. The job remains async and configuration-gated like restaurant POS jobs.';

CREATE OR REPLACE FUNCTION public.trg_enqueue_photo_objet_meinvoice_job()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
BEGIN
  PERFORM public.enqueue_photo_objet_meinvoice_job(NEW.id);
  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    UPDATE public.photo_objet_sales_raw
    SET invoice_enqueue_status = 'failed',
        invoice_enqueue_error = SQLERRM,
        updated_at = now()
    WHERE id = NEW.id;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enqueue_photo_objet_meinvoice_job
  ON public.photo_objet_sales_raw;
CREATE TRIGGER trg_enqueue_photo_objet_meinvoice_job
  AFTER INSERT ON public.photo_objet_sales_raw
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_enqueue_photo_objet_meinvoice_job();

GRANT SELECT ON public.photo_objet_sales_pull_runs TO authenticated;
GRANT SELECT ON public.photo_objet_sales_raw TO authenticated;
GRANT ALL ON public.photo_objet_sales_pull_runs TO service_role;
GRANT ALL ON public.photo_objet_sales_raw TO service_role;
GRANT EXECUTE ON FUNCTION public.enqueue_photo_objet_meinvoice_job(uuid)
  TO service_role;
