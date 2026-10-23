-- Optional delivery details and customer-controlled replacement before receipt.
-- production-gate: self-verifying
BEGIN;

ALTER TABLE public.direct_order_request_addresses
  DROP CONSTRAINT direct_order_address_detail_valid,
  ADD CONSTRAINT direct_order_address_detail_valid
    CHECK (length(btrim(detail_address)) BETWEEN 0 AND 300);

-- Keep the current menu, tenant, location, pickup and payment implementations.
DO $optional_details$
DECLARE
  signature text;
  definition text;
  needle text := $old$btrim(v_address->>'detail_address')$old$;
BEGIN
  FOREACH signature IN ARRAY ARRAY[
    'public.direct_order_public_submit(uuid,text,uuid,jsonb)',
    'public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)'
  ] LOOP
    definition := pg_get_functiondef(signature::regprocedure);
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle) <> 1
      OR strpos(definition, 'NOT BETWEEN 0 AND 300') = 0 THEN
      RAISE EXCEPTION 'DIRECT_ORDER_OPTIONAL_ADDRESS_ANCHOR_DRIFT';
    END IF;
    EXECUTE replace(definition, needle, $new$CASE
      WHEN v_address->>'address_source' = 'pickup' THEN NULL
      ELSE btrim(COALESCE(v_address->>'detail_address', '')) END$new$);
  END LOOP;

  signature := 'public.enqueue_direct_delivery_driver_receipt(uuid,uuid,boolean)';
  definition := pg_get_functiondef(signature::regprocedure);
  needle := $old$OR NULLIF(btrim(v_address.detail_address), '') IS NULL$old$;
  IF strpos(definition,needle) = 0 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_OPTIONAL_RECEIPT_ANCHOR_DRIFT';
  END IF;
  EXECUTE replace(definition,needle,
    $new$OR char_length(btrim(COALESCE(v_address.detail_address, ''))) > 300$new$);

  signature := 'public.guard_direct_delivery_driver_receipt_job()';
  definition := pg_get_functiondef(signature::regprocedure);
  needle := $old$OR NULLIF(btrim(NEW.payload->>'detail_address'), '') IS NULL$old$;
  IF strpos(definition,needle) = 0 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_OPTIONAL_PRINT_ANCHOR_DRIFT';
  END IF;
  EXECUTE replace(definition,needle,
    $new$OR char_length(btrim(COALESCE(NEW.payload->>'detail_address', ''))) > 300$new$);
END;
$optional_details$;

-- A null path authorizes a reservation without loading chat/customer details.
-- A non-null path commits the verified object. Both paths use the same gate.
-- Legacy v1/v2 contracts remain available to cached clients.
CREATE FUNCTION public.direct_order_public_proof_v3(
  p_session_id uuid,
  p_secret_hash text,
  p_request_id uuid,
  p_quote_id uuid,
  p_expected_message_id uuid DEFAULT NULL,
  p_review_request_id uuid DEFAULT NULL,
  p_storage_path text DEFAULT NULL,
  p_verify_only boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
DECLARE
  session_row public.direct_order_sessions%ROWTYPE;
  request_row public.direct_order_requests%ROWTYPE;
  quote_row public.direct_order_quotes%ROWTYPE;
  review_row public.direct_order_proof_review_requests%ROWTYPE;
  message_row public.direct_order_messages%ROWTYPE;
  latest_id uuid;
BEGIN
  session_row := public.direct_order_validate_session(p_session_id,p_secret_hash);
  SELECT * INTO request_row FROM public.direct_order_requests
  WHERE id=p_request_id AND session_id=session_row.id
    AND restaurant_id=session_row.restaurant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
  SELECT * INTO quote_row FROM public.direct_order_quotes
  WHERE id=p_quote_id AND request_id=request_row.id
    AND restaurant_id=request_row.restaurant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_CHANGED'; END IF;

  IF p_storage_path IS NOT NULL THEN
    IF p_storage_path !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}[.](jpg|jpeg|png|webp)$'
      OR position(request_row.restaurant_id::text||'/'||request_row.id::text||'/' IN p_storage_path) <> 1 THEN
      RAISE EXCEPTION 'DIRECT_ORDER_PROOF_PATH_INVALID';
    END IF;
    SELECT * INTO message_row FROM public.direct_order_messages
    WHERE attachment_storage_path=p_storage_path;
    IF FOUND THEN
      IF message_row.request_id IS DISTINCT FROM request_row.id
        OR message_row.restaurant_id IS DISTINCT FROM request_row.restaurant_id
        OR message_row.sender_type <> 'customer' OR message_row.message_type <> 'payment_proof'
        OR message_row.metadata->>'quote_id' IS DISTINCT FROM quote_row.id::text
        OR message_row.metadata->>'review_request_id' IS DISTINCT FROM p_review_request_id::text
        OR message_row.metadata->>'replaces_message_id' IS DISTINCT FROM p_expected_message_id::text THEN
        RAISE EXCEPTION 'DIRECT_ORDER_PROOF_PATH_INVALID';
      END IF;
      RETURN jsonb_build_object('message_id',message_row.id,'state','awaiting_payment_review',
        'review_request_id',p_review_request_id,'idempotent',true);
    END IF;
  END IF;

  IF request_row.support_closed_at IS NOT NULL OR request_row.pii_purged_at IS NOT NULL
    OR quote_row.id IS DISTINCT FROM (SELECT id FROM public.direct_order_quotes
      WHERE request_id=request_row.id AND restaurant_id=request_row.restaurant_id
        AND status IN ('active','locked') ORDER BY version DESC LIMIT 1)
    OR EXISTS(SELECT 1 FROM public.direct_order_financials WHERE request_id=request_row.id)
    OR EXISTS(SELECT 1 FROM public.direct_order_payment_receipts
      WHERE request_id=request_row.id AND quote_id=quote_row.id)
    OR NOT ((request_row.state='quoted' AND quote_row.status='active'
        AND (quote_row.amount_finalized_at IS NOT NULL OR COALESCE(quote_row.expires_at>now(),false)))
      OR (request_row.state='awaiting_payment_review' AND quote_row.status='locked')) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PROOF_NOT_ALLOWED';
  END IF;
  SELECT id INTO latest_id FROM public.direct_order_messages
  WHERE request_id=request_row.id AND restaurant_id=request_row.restaurant_id
    AND sender_type='customer' AND message_type='payment_proof'
    AND attachment_storage_path IS NOT NULL
    AND metadata->>'quote_id'=quote_row.id::text AND metadata->>'charge_id' IS NULL
  ORDER BY created_at DESC,id DESC LIMIT 1;
  IF latest_id IS DISTINCT FROM p_expected_message_id THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_REVIEW_CHANGED';
  END IF;
  SELECT * INTO review_row FROM public.direct_order_proof_review_requests
  WHERE request_id=request_row.id AND status='requested' FOR UPDATE;
  IF review_row.id IS DISTINCT FROM p_review_request_id
    OR (review_row.id IS NOT NULL AND review_row.quote_id<>quote_row.id) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PROOF_REVIEW_NOT_ALLOWED';
  END IF;
  IF p_storage_path IS NULL OR p_verify_only IS TRUE THEN
    RETURN jsonb_build_object('store_id',request_row.restaurant_id);
  END IF;

  INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,
    message_type,attachment_storage_path,metadata,created_at)
  VALUES(request_row.id,request_row.restaurant_id,'customer','payment_proof',p_storage_path,
    jsonb_build_object('quote_id',quote_row.id,'quote_version',quote_row.version,
      'review_request_id',p_review_request_id,'replaces_message_id',latest_id),clock_timestamp())
  RETURNING * INTO message_row;
  IF request_row.state='quoted' THEN
    UPDATE public.direct_order_quotes SET status='locked',locked_at=COALESCE(locked_at,now())
    WHERE id=quote_row.id;
    UPDATE public.direct_order_requests SET state='awaiting_payment_review',updated_at=now()
    WHERE id=request_row.id;
  ELSE
    UPDATE public.direct_order_requests SET updated_at=clock_timestamp() WHERE id=request_row.id;
  END IF;
  IF review_row.id IS NOT NULL THEN
    UPDATE public.direct_order_proof_review_requests SET status='resubmitted',
      replacement_message_id=message_row.id,resolved_at=clock_timestamp() WHERE id=review_row.id;
  END IF;
  RETURN jsonb_build_object('message_id',message_row.id,'state','awaiting_payment_review',
    'review_request_id',p_review_request_id,'idempotent',false);
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_public_proof_v3(uuid,text,uuid,uuid,uuid,uuid,text,boolean)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_proof_v3(uuid,text,uuid,uuid,uuid,uuid,text,boolean)
  TO service_role;

DO $verify$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_constraint
    WHERE conrelid='public.direct_order_request_addresses'::regclass
      AND conname='direct_order_address_detail_valid'
      AND pg_get_constraintdef(oid) LIKE '%>= 0%')
    OR has_function_privilege('anon',
      'public.direct_order_public_proof_v3(uuid,text,uuid,uuid,uuid,uuid,text,boolean)','EXECUTE')
    OR has_function_privilege('authenticated',
      'public.direct_order_public_proof_v3(uuid,text,uuid,uuid,uuid,uuid,text,boolean)','EXECUTE') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_PROOF_VERIFICATION_FAILED';
  END IF;
END;
$verify$;
COMMIT;
