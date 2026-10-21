BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
DO $$ DECLARE r record; shop uuid:='273b057e-3b69-46e3-93c1-6194c2802849'; oid uuid;
BEGIN
 FOR r IN SELECT * FROM operating_test.direct_line_upgrade ORDER BY was_approved DESC LOOP
  PERFORM public.direct_order_record_receipt(shop,r.request_id,r.quote_id,r.proof_id,10800,r.reference);
  PERFORM public.direct_order_record_receipt(shop,r.request_id,r.quote_id,r.proof_id,10800,r.reference);
  SELECT order_id INTO oid FROM public.direct_order_financials WHERE request_id=r.request_id;
  ASSERT (SELECT count(*)=1 AND sum(amount)=10800 FROM public.payments WHERE order_id=oid), 'upgrade duplicated payment';
  ASSERT EXISTS(SELECT 1 FROM public.order_items WHERE order_id=oid AND id=
   CASE WHEN r.was_approved THEN r.old_order_line_id ELSE r.request_line_id END), 'upgrade changed legacy or lost pending line identity';
  IF NOT r.was_approved THEN
   ASSERT (SELECT count(*)=1 FROM public.meinvoice_jobs WHERE order_id=oid), 'pending order invoice job lost';
  END IF;
 END LOOP;
 RAISE NOTICE 'DIRECT_LINE_PENDING_UPGRADE=PASS historical IDs preserved, pending requests approve, retries do not repay';
END $$;
ROLLBACK;
