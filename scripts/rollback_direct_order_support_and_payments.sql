-- Only before feature activity. Once money/support records exist, fix forward.
-- Preserve all additive schema/history; redeploy preceding main afterward.
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';
DO $guard$
BEGIN
 IF EXISTS(SELECT 1 FROM public.direct_order_payment_receipts)
  OR EXISTS(SELECT 1 FROM public.direct_order_payment_charges)
  OR EXISTS(SELECT 1 FROM public.direct_order_refund_records)
  OR EXISTS(SELECT 1 FROM public.direct_order_requests WHERE support_version>1)
  OR EXISTS(SELECT 1 FROM public.direct_order_customer_events WHERE event_kind='payment_request')
  OR EXISTS(SELECT 1 FROM public.direct_order_messages WHERE metadata->>'attachment_bucket'='direct-order-chat')
  OR (SELECT count(*) FROM public.direct_order_support_20261008020000_backup)<>13 THEN
  RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_ROLLBACK_REQUIRES_FORWARD_FIX';
 END IF;
END;
$guard$;
DROP TRIGGER direct_order_quote_payment_notice ON public.direct_order_quotes;
DROP TRIGGER direct_order_charge_payment_notice ON public.direct_order_payment_charges;
DROP TRIGGER direct_order_pickup_support ON public.direct_order_requests;
DROP TRIGGER direct_order_dispatch_settlement ON public.direct_order_dispatches;
DROP TRIGGER direct_order_completion_settlement ON public.direct_delivery_fulfillment_tickets;
DROP TRIGGER zzz_direct_order_final_receipt ON public.print_jobs;
DROP TRIGGER zzz_direct_order_final_digital_receipt ON public.digital_receipts;
DROP TRIGGER direct_order_final_receipt_completed ON public.direct_delivery_fulfillment_tickets;
ALTER TABLE public.direct_order_customer_events ADD CONSTRAINT direct_order_customer_events_request_id_event_kind_key UNIQUE(request_id,event_kind);
DO $restore$
DECLARE row record;
BEGIN
 FOR row IN SELECT definition FROM public.direct_order_support_20261008020000_backup ORDER BY object_identity LOOP
  EXECUTE row.definition;
 END LOOP;
END;
$restore$;
REVOKE ALL ON FUNCTION public.direct_order_record_receipt(uuid,uuid,uuid,uuid,numeric,text),
 public.direct_order_staff_support_action(uuid,uuid,integer,text,jsonb),
 public.direct_order_public_charge_consent(uuid,text,uuid,uuid,boolean),
 public.direct_order_commit_attachment(uuid,uuid,text,uuid,text,text,uuid)
 FROM authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.direct_order_approve_photo_payment(uuid,uuid,numeric,uuid,uuid) TO authenticated;
COMMIT;
