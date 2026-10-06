-- Isolated database fixture: retain the real approval, payment, receipt enqueue
-- and metadata triggers; reduce only unrelated printer configuration tables.
ALTER TABLE public.tables ADD COLUMN IF NOT EXISTS table_number text;
ALTER TABLE public.print_jobs
  ADD COLUMN copy_type text DEFAULT 'receipt',
  ADD COLUMN batch_no integer DEFAULT 1,
  ADD COLUMN destination_id uuid,
  ADD COLUMN status text DEFAULT 'pending',
  ADD COLUMN last_error text,
  ADD COLUMN created_at timestamptz DEFAULT now();
CREATE TABLE public.printer_destinations(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), restaurant_id uuid,
  purpose text, is_active boolean DEFAULT true, created_at timestamptz DEFAULT now()
);
INSERT INTO public.printer_destinations(restaurant_id,purpose)
  VALUES('d1000000-0000-4000-8000-000000000002','receipt');
CREATE TABLE public.digital_receipts(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), restaurant_id uuid NOT NULL,
  order_id uuid NOT NULL UNIQUE, combined_payment_group_id uuid, snapshot jsonb NOT NULL
);
DROP FUNCTION public.enqueue_receipt_print_job(uuid,boolean);
