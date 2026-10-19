-- Extend only the disposable fixture; invoice batch uses real production table
-- definitions loaded by the runner, not the earlier minimal intake stub.
ALTER TABLE public.print_jobs ADD COLUMN attempts integer NOT NULL DEFAULT 0,
 ADD COLUMN next_retry_at timestamptz NOT NULL DEFAULT now(),ADD COLUMN emergency_held_at timestamptz,
 ADD COLUMN claimed_by uuid,ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.audit_logs ADD COLUMN id uuid DEFAULT gen_random_uuid();
CREATE TABLE public.tax_entity(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tax_code text NOT NULL);
ALTER TABLE public.restaurants ADD COLUMN tax_entity_id uuid REFERENCES public.tax_entity(id);
INSERT INTO public.tax_entity(id,tax_code) VALUES('aa000000-0000-4000-8000-000000000001','1234567890');
UPDATE public.restaurants SET tax_entity_id='aa000000-0000-4000-8000-000000000001';
-- A pending legacy receipt and issued digital snapshot remain distinguishable.
CREATE SCHEMA recipient_measurement;
CREATE TABLE recipient_measurement.legacy(request_id uuid,quote jsonb,financial jsonb,snapshot jsonb,receipt_id uuid);
INSERT INTO recipient_measurement.legacy
 SELECT f.request_id,to_jsonb(q),to_jsonb(f),d.snapshot,d.id FROM public.direct_order_financials f
 JOIN public.direct_order_quotes q ON q.id=f.quote_id JOIN public.digital_receipts d ON d.order_id=f.order_id LIMIT 1;
CREATE TABLE recipient_measurement.legacy_money(size integer,request_id uuid,restaurant_id uuid);
DO $legacy_money$
DECLARE n integer;f jsonb;
BEGIN
 UPDATE public.users SET restaurant_id='d1000000-0000-4000-8000-000000000002' WHERE auth_id=auth.uid();
 FOREACH n IN ARRAY ARRAY[1,10,50] LOOP
  f:=photo_test.create_request(true,'store_prepaid');PERFORM photo_test.approve(f);
  INSERT INTO recipient_measurement.legacy_money VALUES(n,(f->>'request_id')::uuid,(f->>'store_id')::uuid);
 END LOOP;
END; $legacy_money$;

CREATE TABLE storage.objects(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),bucket_id text,name text,created_at timestamptz DEFAULT now());
