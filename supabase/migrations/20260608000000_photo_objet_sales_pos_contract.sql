BEGIN;

CREATE TABLE IF NOT EXISTS public.photo_objet_sales (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  sale_date date NOT NULL,
  device_name text NOT NULL,
  device_id text,
  gross_sales bigint NOT NULL DEFAULT 0,
  service_amount bigint NOT NULL DEFAULT 0,
  transaction_count integer NOT NULL DEFAULT 0,
  service_count integer NOT NULL DEFAULT 0,
  raw_rows jsonb,
  pulled_at timestamptz NOT NULL DEFAULT now(),
  pull_source text NOT NULL DEFAULT 'scheduled'
    CHECK (pull_source IN ('scheduled', 'manual')),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT photo_objet_sales_gross_non_negative CHECK (gross_sales >= 0),
  CONSTRAINT photo_objet_sales_service_non_negative CHECK (service_amount >= 0),
  CONSTRAINT photo_objet_sales_transactions_non_negative CHECK (transaction_count >= 0),
  CONSTRAINT photo_objet_sales_service_count_non_negative CHECK (service_count >= 0),
  UNIQUE (store_id, sale_date, device_name)
);

CREATE INDEX IF NOT EXISTS idx_photo_objet_sales_store_date
  ON public.photo_objet_sales (store_id, sale_date DESC);

COMMENT ON TABLE public.photo_objet_sales IS
  'Photo Objet daily sales ingestion table. POS contract uses restaurants.id as store_id.';

COMMIT;
