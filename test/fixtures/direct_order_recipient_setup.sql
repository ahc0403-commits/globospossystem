-- Extend only the disposable fixture; invoice batch uses real production table
-- definitions loaded by the runner, not the earlier minimal intake stub.
ALTER TABLE public.print_jobs ADD COLUMN IF NOT EXISTS attempts integer NOT NULL DEFAULT 0,
 ADD COLUMN IF NOT EXISTS next_retry_at timestamptz NOT NULL DEFAULT now(),ADD COLUMN IF NOT EXISTS emergency_held_at timestamptz,
 ADD COLUMN IF NOT EXISTS claimed_by uuid,ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.audit_logs ADD COLUMN IF NOT EXISTS id uuid DEFAULT gen_random_uuid();
CREATE TABLE public.tax_entity(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tax_code text NOT NULL);
ALTER TABLE public.restaurants ADD COLUMN IF NOT EXISTS tax_entity_id uuid REFERENCES public.tax_entity(id);
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

-- The preceding rollback exercise removed these triggers. Restore the actual
-- current-main triggers so new handoff tests use the production contract.
DO $restore_notices$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='direct_order_driver_handoff_notice') THEN
  CREATE TRIGGER direct_order_driver_handoff_notice AFTER INSERT ON public.direct_order_dispatches
   FOR EACH ROW EXECUTE FUNCTION public.direct_order_customer_event_trigger();
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='direct_order_pickup_ready_notice') THEN
  CREATE TRIGGER direct_order_pickup_ready_notice AFTER UPDATE OF status ON public.direct_delivery_fulfillment_tickets
   FOR EACH ROW EXECUTE FUNCTION public.direct_order_customer_event_trigger();
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='direct_order_pickup_conversion_notice') THEN
  CREATE TRIGGER direct_order_pickup_conversion_notice AFTER UPDATE OF fulfillment_method ON public.direct_order_requests
   FOR EACH ROW EXECUTE FUNCTION public.direct_order_customer_event_trigger();
 END IF;
END; $restore_notices$;

-- Current production native-pickup constraints (omitted by the older minimal fixture).
ALTER TABLE public.direct_order_quotes DROP CONSTRAINT direct_order_quotes_delivery_payment_mode_check;
ALTER TABLE public.direct_order_quotes ADD CONSTRAINT direct_order_quotes_delivery_payment_mode_check
 CHECK(delivery_payment_mode IN ('customer_direct','store_prepaid','not_applicable'));
ALTER TABLE public.direct_order_quotes ADD CONSTRAINT direct_order_pickup_quote_zero_fee CHECK(delivery_payment_mode<>'not_applicable' OR delivery_fee_total=0);
ALTER TABLE public.direct_order_financials DROP CONSTRAINT direct_order_financials_delivery_payment_mode_check;
ALTER TABLE public.direct_order_financials ADD CONSTRAINT direct_order_financials_delivery_payment_mode_check
 CHECK(delivery_payment_mode IN ('customer_direct','store_prepaid','not_applicable'));
ALTER TABLE public.direct_order_financials ADD CONSTRAINT direct_order_pickup_financial_zero_fee CHECK(delivery_payment_mode<>'not_applicable' OR delivery_fee_total=0);
