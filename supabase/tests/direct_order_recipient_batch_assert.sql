DO $batch_assert$
BEGIN
 IF EXISTS(SELECT 1 FROM recipient_measurement.money_scopes s JOIN public.direct_order_financials f ON f.request_id=s.request_id
 LEFT JOIN public.red_invoice_intakes i ON i.order_id=f.order_id WHERE i.status IS DISTINCT FROM 'ready' OR i.gross_amount<>108000 OR i.buyer_phone<>'0901234567')
 OR (SELECT count(*) FROM public.red_invoice_intakes WHERE source_note='Direct Order')<>64
 THEN RAISE EXCEPTION 'BATCH_INVOICE_INTAKE_WRONG'; END IF;
 IF EXISTS(WITH target AS(SELECT s.size,s.expected,f.payment_id FROM recipient_measurement.money_scopes s JOIN public.direct_order_financials f ON f.request_id=s.request_id
 UNION ALL SELECT s.size,s.expected,c.payment_id FROM recipient_measurement.money_scopes s JOIN public.direct_order_payment_charges c ON c.request_id=s.request_id)
 SELECT 1 FROM target t JOIN public.payment_adjustments a ON a.payment_id=t.payment_id GROUP BY t.size,t.expected HAVING sum(a.amount)<>t.expected OR count(*)<>t.size+1)
 THEN RAISE EXCEPTION 'BATCH_REFUND_ALLOCATION_WRONG'; END IF;
END; $batch_assert$;
SELECT 'DIRECT_ORDER_RECIPIENT_POLICY_BOOKING_RECEIPT_ATTACHMENT_BATCH=PASS';
DO $invoice_history$
DECLARE s recipient_measurement.money_scopes%ROWTYPE;o uuid;frozen jsonb:='[{"frozen":"original"}]';
BEGIN
 SELECT * INTO s FROM recipient_measurement.money_scopes WHERE size=1;
 SELECT order_id INTO o FROM public.direct_order_financials WHERE request_id=s.request_id;
 UPDATE public.meinvoice_jobs SET status='valid_invoice',line_items_snapshot=frozen WHERE order_id=o;
 PERFORM public.direct_order_sync_invoice_batch(s.restaurant_id,s.request_id);
 IF NOT EXISTS(SELECT 1 FROM public.meinvoice_jobs WHERE order_id=o AND status='manual_action_required' AND line_items_snapshot=frozen)
 OR NOT EXISTS(SELECT 1 FROM public.red_invoice_intakes WHERE order_id=o AND status='manual_review' AND line_items_snapshot=frozen)
 THEN RAISE EXCEPTION 'ISSUED_INVOICE_AUTOMATED_OR_REBUILT'; END IF;
 UPDATE public.red_invoice_intakes SET status='exported' WHERE order_id=o;
 BEGIN
  PERFORM public.direct_order_sync_invoice_batch(s.restaurant_id,s.request_id);RAISE EXCEPTION 'EXPORTED_INTAKE_CHANGED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'RED_INVOICE_INTAKE_LOCKED' THEN RAISE; END IF; END;
END; $invoice_history$;
