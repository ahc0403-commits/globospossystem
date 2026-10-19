-- Disposable fixture additions only. Use the actual public receipt reader and
-- staff chat functions extracted by the runner, not fake authorization logic.
ALTER TABLE public.digital_receipts ADD COLUMN created_at timestamptz NOT NULL DEFAULT now(), ADD COLUMN revoked_at timestamptz;
ALTER TABLE public.tables ADD COLUMN floor_label text;
CREATE SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE TABLE public.digital_receipt_links(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), digital_receipt_id uuid REFERENCES public.digital_receipts(id), token_hash bytea, expires_at timestamptz, revoked_at timestamptz, last_presented_at timestamptz);
ALTER TABLE public.print_jobs ADD CONSTRAINT print_jobs_copy_type_check CHECK(copy_type IN ('kitchen','floor','tray','confirmation','receipt','delivery_driver_receipt'));
CREATE UNIQUE INDEX requirement_fixture_print_identity ON public.print_jobs(order_id,copy_type,batch_no,destination_id) NULLS NOT DISTINCT;
