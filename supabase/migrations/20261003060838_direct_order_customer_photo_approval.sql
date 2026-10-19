-- Staff approve customer payment photos without a bank integration dependency.
-- production-gate: self-verifying
BEGIN;

DO $restore_photo_review$
DECLARE
  v_definition text;
  v_signature regprocedure :=
    'public.direct_order_approve_payment(uuid,uuid,numeric,text)'::regprocedure;
  v_old text := $old$  IF NOT EXISTS (
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
$old$;
  v_new text := $new$  SELECT message.id INTO v_reviewed_proof_id
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
$new$;
  v_audit_old text := $old$      'ticket_id', v_ticket.id,
      'final_total', v_quote.final_total
$old$;
  v_audit_new text := $new$      'ticket_id', v_ticket.id,
      'final_total', v_quote.final_total,
      'review_method', CASE WHEN v_reviewed_proof_id IS NOT NULL
        THEN 'customer_photo' ELSE 'sepay' END,
      'proof_message_id', v_reviewed_proof_id
$new$;
BEGIN
  SELECT pg_get_functiondef(v_signature) INTO v_definition;
  IF position(v_old IN v_definition) = 0
     OR position(v_audit_old IN v_definition) = 0
     OR position('  v_actor public.users%ROWTYPE;' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PHOTO_APPROVAL_ANCHOR_DRIFT';
  END IF;
  v_definition := replace(v_definition,
    '  v_actor public.users%ROWTYPE;',
    E'  v_actor public.users%ROWTYPE;\n  v_reviewed_proof_id uuid;');
  v_definition := replace(v_definition, v_old, v_new);
  v_definition := replace(v_definition, v_audit_old, v_audit_new);
  EXECUTE v_definition;
END;
$restore_photo_review$;

-- Capture the exact quote and latest photo shown to the cashier. The request
-- lock serializes photo replacement, rejection and approval; the common payment
-- function still owns all financial, inventory and kitchen writes atomically.
CREATE OR REPLACE FUNCTION public.direct_order_approve_photo_payment(
  p_store_id uuid,
  p_request_id uuid,
  p_confirmed_amount numeric,
  p_quote_id uuid,
  p_proof_message_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_request public.direct_order_requests%ROWTYPE;
  v_quote public.direct_order_quotes%ROWTYPE;
  v_financial public.direct_order_financials%ROWTYPE;
  v_proof_id uuid;
  v_result jsonb;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  PERFORM pg_advisory_xact_lock(
    hashtextextended('direct-order-approval:' || p_request_id::text, 0)
  );
  SELECT * INTO v_request
  FROM public.direct_order_requests request_row
  WHERE request_row.id = p_request_id
    AND request_row.restaurant_id = p_store_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;

  SELECT * INTO v_financial
  FROM public.direct_order_financials financial
  WHERE financial.request_id = p_request_id
    AND financial.restaurant_id = p_store_id;
  IF FOUND THEN
    IF p_quote_id IS DISTINCT FROM v_financial.quote_id
       OR p_confirmed_amount IS DISTINCT FROM v_financial.final_total
       OR NOT EXISTS (
         SELECT 1 FROM public.audit_logs audit
         WHERE audit.entity_id = p_request_id
           AND audit.action = 'direct_order_payment_approved'
           AND audit.details->>'proof_message_id' = p_proof_message_id::text
           AND audit.details->>'review_method' = 'customer_photo'
       ) THEN
      RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_REVIEW_CHANGED';
    END IF;
    RETURN public.direct_order_approve_payment(
      p_store_id, p_request_id, p_confirmed_amount, NULL
    );
  END IF;

  SELECT * INTO v_quote
  FROM public.direct_order_quotes quote
  WHERE quote.request_id = p_request_id
    AND quote.restaurant_id = p_store_id
    AND quote.status = 'locked'
  ORDER BY quote.version DESC
  LIMIT 1
  FOR UPDATE;
  IF NOT FOUND OR p_quote_id IS DISTINCT FROM v_quote.id THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_REVIEW_CHANGED';
  END IF;

  SELECT message.id INTO v_proof_id
  FROM public.direct_order_messages message
  WHERE message.request_id = p_request_id
    AND message.restaurant_id = p_store_id
    AND message.sender_type = 'customer'
    AND message.message_type = 'payment_proof'
    AND message.attachment_storage_path IS NOT NULL
    AND message.metadata->>'quote_id' = v_quote.id::text
    AND message.metadata->>'quote_version' = v_quote.version::text
  ORDER BY message.created_at DESC, message.id DESC
  LIMIT 1;
  IF v_proof_id IS NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_PROOF_REQUIRED';
  END IF;
  IF p_proof_message_id IS DISTINCT FROM v_proof_id THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_REVIEW_CHANGED';
  END IF;

  v_result := public.direct_order_approve_payment(
    p_store_id, p_request_id, p_confirmed_amount, NULL
  );
  UPDATE public.direct_order_financials financial
  SET delivery_payment_mode = v_quote.delivery_payment_mode
  WHERE financial.request_id = p_request_id
    AND financial.restaurant_id = p_store_id
    AND financial.quote_id = v_quote.id;
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_approve_photo_payment(
  uuid, uuid, numeric, uuid, uuid
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_approve_photo_payment(
  uuid, uuid, numeric, uuid, uuid
) TO authenticated, service_role;

DO $verify$
DECLARE v_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.direct_order_approve_payment(uuid,uuid,numeric,text)'::regprocedure
  ) INTO v_definition;
  IF position('IF v_reviewed_proof_id IS NULL AND NOT EXISTS' IN v_definition) = 0
     OR position('DIRECT_ORDER_PAYMENT_PROOF_REQUIRED' IN v_definition) = 0
     OR position('DIRECT_ORDER_PROOF_RESUBMISSION_PENDING' IN v_definition) = 0
     OR position('public.process_payment(' IN v_definition) = 0
     OR position('''review_method''' IN v_definition) = 0
     OR has_function_privilege('anon',
       'public.direct_order_approve_photo_payment(uuid,uuid,numeric,uuid,uuid)',
       'EXECUTE')
     OR NOT has_function_privilege('authenticated',
       'public.direct_order_approve_photo_payment(uuid,uuid,numeric,uuid,uuid)',
       'EXECUTE') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PHOTO_APPROVAL_VERIFICATION_FAILED';
  END IF;
END;
$verify$;

COMMIT;
