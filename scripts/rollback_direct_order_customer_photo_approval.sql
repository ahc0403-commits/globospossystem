-- Restore only this feature's approval condition; keep financial records and
-- later pickup, VAT, receipt, and kitchen changes. Roll back the web release first.
BEGIN;
DO $rollback$
DECLARE
 v_definition text;
 v_current text := $current$  SELECT message.id INTO v_reviewed_proof_id
  FROM public.direct_order_messages message
  WHERE message.request_id = v_request.id
    AND message.restaurant_id = p_store_id
    AND message.sender_type = 'customer'
    AND message.message_type = 'payment_proof'
    AND message.attachment_storage_path IS NOT NULL
    AND message.metadata->>'quote_id' = v_quote.id::text
    AND message.metadata->>'quote_version' = v_quote.version::text
  ORDER BY message.created_at DESC, message.id DESC
  LIMIT 1;

  -- Preserve the optional legacy verified-transfer caller. Photo review is
  -- sufficient for authenticated staff and never requires that integration.
  IF v_reviewed_proof_id IS NULL AND NOT EXISTS (
    SELECT 1
    FROM public.direct_order_sepay_candidates payment_link
    JOIN public.sepay_transactions payment_transaction
      ON payment_transaction.id = payment_link.sepay_transaction_id
    WHERE payment_link.request_id = v_request.id
      AND payment_link.restaurant_id = p_store_id
      AND payment_transaction.restaurant_id = p_store_id
      AND payment_transaction.transfer_type = 'in'
      AND payment_transaction.resolution_status = 'matched'
      AND payment_transaction.transfer_amount::numeric = v_quote.final_total
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_PROOF_REQUIRED';
  END IF;
$current$;
 v_previous text := $previous$  IF NOT EXISTS (
    SELECT 1
    FROM public.direct_order_sepay_candidates payment_link
    JOIN public.sepay_transactions payment_transaction
      ON payment_transaction.id = payment_link.sepay_transaction_id
    WHERE payment_link.request_id = v_request.id
      AND payment_link.restaurant_id = p_store_id
      AND payment_transaction.restaurant_id = p_store_id
      AND payment_transaction.transfer_type = 'in'
      AND payment_transaction.resolution_status = 'matched'
      AND payment_transaction.transfer_amount::numeric = v_quote.final_total
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_VERIFIED_PAYMENT_REQUIRED';
  END IF;
$previous$;
 v_audit_current text := $current$      'ticket_id', v_ticket.id,
      'final_total', v_quote.final_total,
      'review_method', CASE WHEN v_reviewed_proof_id IS NOT NULL
        THEN 'customer_photo' ELSE 'sepay' END,
      'proof_message_id', v_reviewed_proof_id
$current$;
 v_audit_previous text := $previous$      'ticket_id', v_ticket.id,
      'final_total', v_quote.final_total
$previous$;
BEGIN
 SELECT pg_get_functiondef('public.direct_order_approve_payment(uuid,uuid,numeric,text)'::regprocedure) INTO v_definition;
 IF position(v_current IN v_definition)=0 OR position(v_audit_current IN v_definition)=0 THEN
  RAISE EXCEPTION 'PHOTO_APPROVAL_ROLLBACK_ANCHOR_DRIFT';
 END IF;
 v_definition:=replace(v_definition,v_current,v_previous);
 v_definition:=replace(v_definition,v_audit_current,v_audit_previous);
 v_definition:=replace(v_definition,E'\n  v_reviewed_proof_id uuid;','');
 EXECUTE v_definition;
END;
$rollback$;
DROP FUNCTION public.direct_order_approve_photo_payment(uuid,uuid,numeric,uuid,uuid);
COMMIT;
