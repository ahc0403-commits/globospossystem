CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE public.users (id uuid PRIMARY KEY);
CREATE TABLE public.tax_entity (id uuid PRIMARY KEY, tax_code text NOT NULL);
CREATE TABLE public.restaurants (
  id uuid PRIMARY KEY,
  name text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  tax_entity_id uuid REFERENCES public.tax_entity(id)
);
CREATE TABLE public.system_config (
  key text PRIMARY KEY,
  value text NOT NULL,
  description text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES public.users(id)
);
CREATE TABLE public.meinvoice_tax_entity_config (
  tax_entity_id uuid PRIMARY KEY REFERENCES public.tax_entity(id),
  integration_status text NOT NULL
);
CREATE TABLE public.meinvoice_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text DEFAULT 'misa',
  invoice_form text DEFAULT 'cash_register',
  order_id uuid,
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  tax_entity_id uuid NOT NULL REFERENCES public.tax_entity(id),
  buyer_kind text NOT NULL DEFAULT 'anonymous',
  buyer_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  payment_method_snapshot text,
  payment_summary jsonb NOT NULL DEFAULT '[]'::jsonb,
  line_items_snapshot jsonb NOT NULL DEFAULT '[]'::jsonb,
  status text NOT NULL DEFAULT 'pending_manual_config',
  manual_action_type text,
  manual_action_note text,
  misa_ref_id text,
  transaction_id text,
  invoice_series text,
  invoice_number text,
  tax_authority_code text,
  search_code text,
  error_message text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  dispatch_attempts integer NOT NULL DEFAULT 0,
  last_dispatch_at timestamptz,
  next_retry_at timestamptz,
  sent_at timestamptz,
  source_system text NOT NULL DEFAULT 'restaurant_pos',
  source_table text,
  source_id uuid,
  source_key text,
  source_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  dispatch_claim_id uuid,
  dispatch_claimed_at timestamptz,
  UNIQUE (source_system, source_key)
);
CREATE TABLE public.photo_objet_sales_pull_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  target_date date NOT NULL,
  collector_method text NOT NULL DEFAULT 'excel',
  status text NOT NULL DEFAULT 'started',
  rows_read integer NOT NULL DEFAULT 0,
  rows_inserted integer NOT NULL DEFAULT 0,
  rows_duplicate integer NOT NULL DEFAULT 0,
  aggregate_rows integer NOT NULL DEFAULT 0,
  error_message text,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.photo_objet_sales_raw (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  sale_date date NOT NULL,
  device_name text NOT NULL,
  device_id text,
  sale_time_text text,
  sold_at timestamptz,
  amount bigint NOT NULL CHECK (amount > 0),
  raw_type text,
  payment_method text NOT NULL DEFAULT 'CASH',
  buyer_kind text NOT NULL DEFAULT 'anonymous',
  raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  source_hash text NOT NULL UNIQUE,
  pull_run_id uuid REFERENCES public.photo_objet_sales_pull_runs(id),
  meinvoice_job_id uuid REFERENCES public.meinvoice_jobs(id) ON DELETE SET NULL,
  invoice_enqueue_status text NOT NULL DEFAULT 'pending',
  invoice_enqueue_error text,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.photo_objet_sales (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  sale_date date NOT NULL,
  device_name text NOT NULL,
  device_id text,
  gross_sales bigint DEFAULT 0,
  service_amount bigint DEFAULT 0,
  transaction_count integer DEFAULT 0,
  service_count integer DEFAULT 0,
  raw_rows jsonb,
  pulled_at timestamptz DEFAULT now(),
  pull_source text DEFAULT 'scheduled',
  UNIQUE (store_id, sale_date, device_name)
);

CREATE FUNCTION public.meinvoice_payment_method_label(uuid, text[])
RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT 'TM'::text $$;

CREATE FUNCTION public.enqueue_photo_objet_meinvoice_job(p_raw_sale_id uuid)
RETURNS uuid
LANGUAGE plpgsql
AS $$
BEGIN
  -- ORIGINAL_ENQUEUE_FUNCTION
  RETURN NULL;
END;
$$;

INSERT INTO public.tax_entity (id, tax_code)
VALUES ('10000000-0000-4000-8000-000000000001', 'AKJ-TAX');
INSERT INTO public.meinvoice_tax_entity_config (tax_entity_id, integration_status)
VALUES ('10000000-0000-4000-8000-000000000001', 'active');
INSERT INTO public.system_config (key, value) VALUES ('meinvoice_dispatch_enabled', 'true');

INSERT INTO public.restaurants (id, name, tax_entity_id) VALUES
  ('77000000-0000-4000-8000-000000000102', 'PHOTO OBJET BIEN HOA', '10000000-0000-4000-8000-000000000001'),
  ('77000000-0000-4000-8000-000000000103', 'PHOTO OBJET DI AN', '10000000-0000-4000-8000-000000000001'),
  ('77000000-0000-4000-8000-000000000104', 'PHOTO OBJET LONG THANH', '10000000-0000-4000-8000-000000000001'),
  ('77000000-0000-4000-8000-000000000105', 'PHOTO OBJET THAO DIEN', '10000000-0000-4000-8000-000000000001'),
  ('77000000-0000-4000-8000-000000000106', 'PHOTO OBJET QUANG TRUNG', '10000000-0000-4000-8000-000000000001'),
  ('77000000-0000-4000-8000-000000000107', 'PHOTO OBJET NOW ZONE', '10000000-0000-4000-8000-000000000001'),
  ('77000000-0000-4000-8000-000000000108', 'PHOTO OBJET D7', '10000000-0000-4000-8000-000000000001');

INSERT INTO public.photo_objet_sales_pull_runs (id, store_id, target_date, status)
VALUES (
  '20000000-0000-4000-8000-000000000001',
  '77000000-0000-4000-8000-000000000102',
  DATE '2026-07-12',
  'success'
);
INSERT INTO public.meinvoice_jobs (
  id, store_id, tax_entity_id, status, source_system, source_table,
  source_id, source_key, dispatch_attempts
) VALUES (
  '30000000-0000-4000-8000-000000000001',
  '77000000-0000-4000-8000-000000000102',
  '10000000-0000-4000-8000-000000000001',
  'pending_manual_config', 'photo_objet_moers', 'photo_objet_sales_raw',
  '40000000-0000-4000-8000-000000000001', 'legacy-hash', 0
);
INSERT INTO public.photo_objet_sales_raw (
  id, store_id, sale_date, device_name, sale_time_text, sold_at, amount,
  source_hash, pull_run_id, meinvoice_job_id, invoice_enqueue_status
) VALUES (
  '40000000-0000-4000-8000-000000000001',
  '77000000-0000-4000-8000-000000000102', DATE '2026-07-12', 'M1',
  '2026-07-12 11:00:00', NULL, 100000, 'legacy-hash',
  '20000000-0000-4000-8000-000000000001',
  '30000000-0000-4000-8000-000000000001', 'queued'
);
INSERT INTO public.photo_objet_sales (store_id, sale_date, device_name, gross_sales, transaction_count) VALUES
  ('77000000-0000-4000-8000-000000000102', DATE '2026-06-30', 'M1', 50000, 1),
  ('77000000-0000-4000-8000-000000000102', DATE '2026-07-12', 'M1', 100000, 1),
  ('77000000-0000-4000-8000-000000000108', DATE '2026-07-12', 'M1', 70000, 1);
