-- Close the direct-order pilot gaps found in store testing: verified payment
-- approval, per-quote delivery payment ownership, and recoverable customer bills.
-- production-gate: self-verifying

BEGIN;

ALTER TABLE public.direct_order_quotes
  ADD COLUMN IF NOT EXISTS delivery_payment_mode text NOT NULL
    DEFAULT 'store_prepaid'
    CHECK (delivery_payment_mode IN ('customer_direct', 'store_prepaid'));

ALTER TABLE public.direct_order_financials
  ADD COLUMN IF NOT EXISTS delivery_payment_mode text NOT NULL
    DEFAULT 'store_prepaid'
    CHECK (delivery_payment_mode IN ('customer_direct', 'store_prepaid'));

ALTER TABLE public.direct_order_dispatches
  ADD COLUMN IF NOT EXISTS delivery_payment_mode text NOT NULL
    DEFAULT 'store_prepaid'
    CHECK (delivery_payment_mode IN ('customer_direct', 'store_prepaid'));

COMMENT ON COLUMN public.direct_order_quotes.delivery_payment_mode IS
  'Immutable quote policy: customer pays driver, or store collects and prepays.';
COMMENT ON COLUMN public.direct_order_financials.delivery_payment_mode IS
  'Delivery payment policy snapshotted when the verified payment is approved.';

DO $duplicate_guard$
DECLARE
  v_transaction uuid;
BEGIN
  SELECT link.sepay_transaction_id
  INTO v_transaction
  FROM public.direct_order_sepay_candidates link
  GROUP BY link.sepay_transaction_id
  HAVING count(DISTINCT link.request_id) > 1
  LIMIT 1;

  IF v_transaction IS NOT NULL THEN
    RAISE EXCEPTION
      'DIRECT_ORDER_VERIFIED_PAYMENT_MIGRATION_BLOCKED: transaction % is linked to multiple requests',
      v_transaction;
  END IF;
END;
$duplicate_guard$;

CREATE UNIQUE INDEX IF NOT EXISTS direct_order_sepay_one_request_per_transaction
  ON public.direct_order_sepay_candidates(sepay_transaction_id);

CREATE OR REPLACE FUNCTION public.direct_order_staff_quote_with_payment_mode(
  p_store_id uuid,
  p_request_id uuid,
  p_delivery_fee_total numeric,
  p_cashier_note text DEFAULT NULL,
  p_delivery_payment_mode text DEFAULT 'customer_direct'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_quote jsonb;
  v_quote_id uuid;
  v_effective_fee numeric;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );

  IF p_delivery_payment_mode NOT IN ('customer_direct', 'store_prepaid')
     OR p_delivery_fee_total IS NULL
     OR p_delivery_fee_total < 0
     OR (
       p_delivery_payment_mode = 'customer_direct'
       AND round(p_delivery_fee_total, 2) <> 0
     ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_INPUT_INVALID';
  END IF;

  v_effective_fee := CASE
    WHEN p_delivery_payment_mode = 'customer_direct' THEN 0
    ELSE round(p_delivery_fee_total, 2)
  END;

  v_quote := public.direct_order_staff_quote(
    p_store_id,
    p_request_id,
    v_effective_fee,
    p_cashier_note
  );
  v_quote_id := (v_quote->>'id')::uuid;

  UPDATE public.direct_order_quotes quote
  SET delivery_payment_mode = p_delivery_payment_mode
  WHERE quote.id = v_quote_id
    AND quote.request_id = p_request_id
    AND quote.restaurant_id = p_store_id;

  UPDATE public.direct_order_messages message
  SET metadata = COALESCE(message.metadata, '{}'::jsonb) || jsonb_build_object(
    'delivery_payment_mode', p_delivery_payment_mode
  )
  WHERE message.request_id = p_request_id
    AND message.restaurant_id = p_store_id
    AND message.message_type = 'quote'
    AND message.metadata->>'quote_id' = v_quote_id::text;

  SELECT to_jsonb(quote) - ARRAY['restaurant_id', 'created_by']
  INTO v_quote
  FROM public.direct_order_quotes quote
  WHERE quote.id = v_quote_id;

  RETURN v_quote;
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_staff_quote_with_payment_mode(
  uuid, uuid, numeric, text, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_quote_with_payment_mode(
  uuid, uuid, numeric, text, text
) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_staff_sepay_candidates_v2(
  p_store_id uuid,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_quote public.direct_order_quotes%ROWTYPE;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );

  SELECT quote.* INTO v_quote
  FROM public.direct_order_quotes quote
  WHERE quote.request_id = p_request_id
    AND quote.restaurant_id = p_store_id
    AND quote.status IN ('active', 'locked')
  ORDER BY quote.version DESC
  LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_NOT_FOUND'; END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', transaction_row.id,
      'amount', transaction_row.transfer_amount,
      'payment_code', transaction_row.payment_code,
      'reference_code', transaction_row.reference_code,
      'transaction_at', transaction_row.transaction_at,
      'received_at', transaction_row.received_at
    ) ORDER BY COALESCE(
      transaction_row.transaction_at,
      transaction_row.received_at
    ) DESC)
    FROM public.sepay_transactions transaction_row
    WHERE transaction_row.restaurant_id = p_store_id
      AND transaction_row.transfer_type = 'in'
      AND transaction_row.resolution_status = 'matched'
      AND transaction_row.transfer_amount::numeric = v_quote.final_total
      AND transaction_row.received_at >= now() - interval '2 days'
      AND NOT EXISTS (
        SELECT 1
        FROM public.direct_order_sepay_candidates used
        WHERE used.sepay_transaction_id = transaction_row.id
          AND used.request_id <> p_request_id
      )
  ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_staff_sepay_candidates_v2(uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_sepay_candidates_v2(uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_staff_link_sepay(
  p_store_id uuid,
  p_request_id uuid,
  p_transaction_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_link public.direct_order_sepay_candidates%ROWTYPE;
  v_quote public.direct_order_quotes%ROWTYPE;
  v_used_request uuid;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  PERFORM pg_advisory_xact_lock(
    hashtextextended('direct-order-sepay:' || p_transaction_id::text, 0)
  );

  PERFORM 1
  FROM public.direct_order_requests request_row
  WHERE request_row.id = p_request_id
    AND request_row.restaurant_id = p_store_id
    AND request_row.state IN ('quoted', 'awaiting_payment_review')
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_NOT_FOUND'; END IF;

  SELECT quote.* INTO v_quote
  FROM public.direct_order_quotes quote
  WHERE quote.request_id = p_request_id
    AND quote.restaurant_id = p_store_id
    AND quote.status IN ('active', 'locked')
  ORDER BY quote.version DESC
  LIMIT 1
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_NOT_FOUND'; END IF;

  SELECT used.request_id INTO v_used_request
  FROM public.direct_order_sepay_candidates used
  WHERE used.sepay_transaction_id = p_transaction_id
  LIMIT 1;
  IF v_used_request IS NOT NULL AND v_used_request <> p_request_id THEN
    RAISE EXCEPTION 'DIRECT_ORDER_SEPAY_TRANSACTION_ALREADY_USED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.sepay_transactions transaction_row
    WHERE transaction_row.id = p_transaction_id
      AND transaction_row.restaurant_id = p_store_id
      AND transaction_row.transfer_type = 'in'
      AND transaction_row.resolution_status = 'matched'
      AND transaction_row.transfer_amount::numeric = v_quote.final_total
      AND transaction_row.received_at >= now() - interval '2 days'
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_SEPAY_CANDIDATE_INVALID';
  END IF;

  INSERT INTO public.direct_order_sepay_candidates(
    request_id, restaurant_id, sepay_transaction_id, linked_by
  ) VALUES (
    p_request_id, p_store_id, p_transaction_id, (SELECT auth.uid())
  )
  ON CONFLICT (request_id, sepay_transaction_id) DO UPDATE
  SET linked_by = EXCLUDED.linked_by, linked_at = now()
  RETURNING * INTO v_link;

  UPDATE public.direct_order_quotes
  SET status = 'locked', locked_at = COALESCE(locked_at, now())
  WHERE id = v_quote.id;

  UPDATE public.direct_order_requests
  SET state = 'awaiting_payment_review', updated_at = now()
  WHERE id = p_request_id AND restaurant_id = p_store_id;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    (SELECT auth.uid()), 'direct_order_verified_payment_linked',
    'direct_order_requests', p_request_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'quote_id', v_quote.id,
      'sepay_transaction_id', p_transaction_id
    )
  );

  RETURN to_jsonb(v_link) - ARRAY['restaurant_id', 'linked_by'];
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_staff_link_sepay(uuid, uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_link_sepay(uuid, uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_staff_verified_payment_evidence(
  p_store_id uuid,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_result jsonb;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );

  SELECT jsonb_build_object(
    'transaction_id', transaction_row.id,
    'provider_transaction_id', transaction_row.sepay_transaction_id,
    'amount', transaction_row.transfer_amount,
    'payment_code', transaction_row.payment_code,
    'reference_code', COALESCE(
      transaction_row.reference_code,
      transaction_row.payment_code,
      transaction_row.sepay_transaction_id::text
    ),
    'transaction_at', transaction_row.transaction_at,
    'received_at', transaction_row.received_at,
    'quote_id', quote.id,
    'quote_version', quote.version
  )
  INTO v_result
  FROM public.direct_order_sepay_candidates link
  JOIN public.sepay_transactions transaction_row
    ON transaction_row.id = link.sepay_transaction_id
  JOIN public.direct_order_quotes quote
    ON quote.request_id = link.request_id
   AND quote.restaurant_id = link.restaurant_id
   AND quote.status = 'locked'
  WHERE link.request_id = p_request_id
    AND link.restaurant_id = p_store_id
    AND transaction_row.restaurant_id = p_store_id
    AND transaction_row.transfer_type = 'in'
    AND transaction_row.resolution_status = 'matched'
    AND transaction_row.transfer_amount::numeric = quote.final_total
  ORDER BY link.linked_at DESC
  LIMIT 1;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_staff_verified_payment_evidence(
  uuid, uuid
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_verified_payment_evidence(
  uuid, uuid
) TO authenticated, service_role;

DO $proof_or_verified_payment$
DECLARE
  v_approve regprocedure := to_regprocedure(
    'public.direct_order_approve_payment(uuid,uuid,numeric,text)'
  );
  v_definition text;
  v_old constant text := $old$  IF NOT EXISTS (
    SELECT 1 FROM public.direct_order_messages message
    WHERE message.request_id = v_request.id
      AND message.message_type = 'payment_proof'
      AND message.attachment_storage_path IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_PROOF_REQUIRED';
  END IF;
$old$;
  v_new constant text := $new$  IF NOT EXISTS (
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
$new$;
BEGIN
  IF v_approve IS NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_VERIFIED_PAYMENT_MIGRATION_FAILED: approval missing';
  END IF;
  SELECT pg_get_functiondef(v_approve::oid) INTO v_definition;
  IF position(v_old IN v_definition) = 0 THEN
    RAISE EXCEPTION
      'DIRECT_ORDER_VERIFIED_PAYMENT_MIGRATION_FAILED: proof anchor missing';
  END IF;
  EXECUTE replace(v_definition, v_old, v_new);
END;
$proof_or_verified_payment$;

CREATE OR REPLACE FUNCTION public.direct_order_customer_receipt_status(
  p_store_id uuid,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_order_id uuid;
  v_job public.print_jobs%ROWTYPE;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  SELECT financial.order_id INTO v_order_id
  FROM public.direct_order_financials financial
  WHERE financial.request_id = p_request_id
    AND financial.restaurant_id = p_store_id;
  IF v_order_id IS NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_NOT_APPROVED'; END IF;

  SELECT job.* INTO v_job
  FROM public.print_jobs job
  WHERE job.order_id = v_order_id
    AND job.restaurant_id = p_store_id
    AND job.copy_type = 'receipt'
  ORDER BY job.batch_no DESC, job.created_at DESC, job.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'exists', false, 'status', null, 'batch_no', null,
      'last_error_code', null, 'can_reprint', false
    );
  END IF;

  RETURN jsonb_build_object(
    'exists', true,
    'status', v_job.status,
    'batch_no', v_job.batch_no,
    'last_error_code', CASE
      WHEN v_job.last_error IS NULL THEN null
      WHEN v_job.last_error = 'NO_DESTINATION' THEN 'NO_DESTINATION'
      ELSE 'PRINT_FAILED'
    END,
    'can_reprint', EXISTS (
      SELECT 1 FROM public.print_jobs completed
      WHERE completed.order_id = v_order_id
        AND completed.restaurant_id = p_store_id
        AND completed.copy_type = 'receipt'
        AND completed.status = 'done'
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_customer_receipt_status(uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_customer_receipt_status(uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.enqueue_direct_order_customer_receipt(
  p_store_id uuid,
  p_request_id uuid,
  p_reprint boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_order_id uuid;
  v_job public.print_jobs%ROWTYPE;
  v_destination_id uuid;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  PERFORM pg_advisory_xact_lock(
    hashtextextended('direct-order-customer-receipt:' || p_request_id::text, 0)
  );

  SELECT financial.order_id INTO v_order_id
  FROM public.direct_order_financials financial
  WHERE financial.request_id = p_request_id
    AND financial.restaurant_id = p_store_id;
  IF v_order_id IS NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_NOT_APPROVED'; END IF;

  IF COALESCE(p_reprint, false) AND NOT EXISTS (
    SELECT 1 FROM public.print_jobs completed
    WHERE completed.order_id = v_order_id
      AND completed.restaurant_id = p_store_id
      AND completed.copy_type = 'receipt'
      AND completed.status = 'done'
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CUSTOMER_RECEIPT_REPRINT_NOT_AVAILABLE';
  END IF;

  SELECT * INTO v_job
  FROM public.enqueue_receipt_print_job(v_order_id, COALESCE(p_reprint, false));

  IF NOT COALESCE(p_reprint, false) AND v_job.status = 'failed' THEN
    SELECT destination.id INTO v_destination_id
    FROM public.printer_destinations destination
    WHERE destination.restaurant_id = p_store_id
      AND destination.purpose = 'receipt'
      AND destination.is_active = true
    ORDER BY destination.created_at, destination.id
    LIMIT 1;

    IF v_destination_id IS NOT NULL THEN
      UPDATE public.print_jobs
      SET destination_id = v_destination_id,
          status = 'pending', attempts = 0, next_retry_at = now(),
          last_error = NULL, updated_at = now()
      WHERE id = v_job.id AND status = 'failed'
      RETURNING * INTO v_job;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'job_id', v_job.id,
    'status', v_job.status,
    'batch_no', v_job.batch_no,
    'reprint', COALESCE(p_reprint, false)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_direct_order_customer_receipt(
  uuid, uuid, boolean
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enqueue_direct_order_customer_receipt(
  uuid, uuid, boolean
) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.enqueue_direct_order_customer_receipt_after_payment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
  BEGIN
    PERFORM public.enqueue_receipt_print_job(NEW.order_id, false);
  EXCEPTION WHEN OTHERS THEN
    BEGIN
      INSERT INTO public.audit_logs(
        actor_id, action, entity_type, entity_id, details
      ) VALUES (
        (SELECT auth.uid()),
        'direct_order_customer_receipt_queue_failed',
        'direct_order_requests',
        NEW.request_id,
        jsonb_build_object(
          'store_id', NEW.restaurant_id,
          'order_id', NEW.order_id,
          'error_code', 'CUSTOMER_RECEIPT_QUEUE_FAILED'
        )
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION
  public.enqueue_direct_order_customer_receipt_after_payment()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.enqueue_direct_order_customer_receipt_after_payment()
  TO service_role;

DROP TRIGGER IF EXISTS direct_order_customer_receipt_after_payment
  ON public.direct_order_financials;
CREATE TRIGGER direct_order_customer_receipt_after_payment
AFTER INSERT ON public.direct_order_financials
FOR EACH ROW EXECUTE FUNCTION
  public.enqueue_direct_order_customer_receipt_after_payment();

CREATE OR REPLACE FUNCTION public.direct_order_approve_verified_payment(
  p_store_id uuid,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_quote public.direct_order_quotes%ROWTYPE;
  v_transaction public.sepay_transactions%ROWTYPE;
  v_result jsonb;
  v_receipt jsonb;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  PERFORM pg_advisory_xact_lock(
    hashtextextended('direct-order-approval:' || p_request_id::text, 0)
  );

  IF EXISTS (
    SELECT 1 FROM public.direct_order_financials financial
    WHERE financial.request_id = p_request_id
      AND financial.restaurant_id = p_store_id
  ) THEN
    SELECT jsonb_build_object(
      'request_id', financial.request_id,
      'order_id', financial.order_id,
      'payment_id', financial.payment_id,
      'ticket_id', (
        SELECT ticket.id
        FROM public.direct_delivery_fulfillment_tickets ticket
        WHERE ticket.request_id = financial.request_id
          AND ticket.restaurant_id = p_store_id
      ),
      'final_total', financial.final_total,
      'idempotent', true
    ) INTO v_result
    FROM public.direct_order_financials financial
    WHERE financial.request_id = p_request_id
      AND financial.restaurant_id = p_store_id;
    BEGIN
      v_receipt := public.enqueue_direct_order_customer_receipt(
        p_store_id, p_request_id, false
      );
    EXCEPTION WHEN OTHERS THEN
      v_receipt := jsonb_build_object(
        'status', 'not_queued',
        'error_code', 'CUSTOMER_RECEIPT_QUEUE_FAILED'
      );
    END;
    RETURN v_result || jsonb_build_object('customer_receipt', v_receipt);
  END IF;

  PERFORM 1
  FROM public.direct_order_requests request_row
  WHERE request_row.id = p_request_id
    AND request_row.restaurant_id = p_store_id
    AND request_row.state = 'awaiting_payment_review'
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_APPROVABLE'; END IF;

  SELECT quote.* INTO v_quote
  FROM public.direct_order_quotes quote
  WHERE quote.request_id = p_request_id
    AND quote.restaurant_id = p_store_id
    AND quote.status = 'locked'
  ORDER BY quote.version DESC
  LIMIT 1
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_APPROVABLE'; END IF;

  SELECT transaction_row.* INTO v_transaction
  FROM public.direct_order_sepay_candidates link
  JOIN public.sepay_transactions transaction_row
    ON transaction_row.id = link.sepay_transaction_id
  WHERE link.request_id = p_request_id
    AND link.restaurant_id = p_store_id
    AND transaction_row.restaurant_id = p_store_id
    AND transaction_row.transfer_type = 'in'
    AND transaction_row.resolution_status = 'matched'
    AND transaction_row.transfer_amount::numeric = v_quote.final_total
  ORDER BY link.linked_at DESC
  LIMIT 1
  FOR UPDATE OF transaction_row;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DIRECT_ORDER_VERIFIED_PAYMENT_REQUIRED';
  END IF;

  v_result := public.direct_order_approve_payment(
    p_store_id,
    p_request_id,
    v_quote.final_total,
    COALESCE(
      v_transaction.reference_code,
      v_transaction.payment_code,
      v_transaction.sepay_transaction_id::text
    )
  );

  UPDATE public.direct_order_financials financial
  SET delivery_payment_mode = v_quote.delivery_payment_mode
  WHERE financial.request_id = p_request_id
    AND financial.restaurant_id = p_store_id
    AND financial.quote_id = v_quote.id;

  BEGIN
    v_receipt := public.enqueue_direct_order_customer_receipt(
      p_store_id, p_request_id, false
    );
  EXCEPTION WHEN OTHERS THEN
    v_receipt := jsonb_build_object(
      'status', 'not_queued',
      'error_code', 'CUSTOMER_RECEIPT_QUEUE_FAILED'
    );
  END;

  RETURN v_result || jsonb_build_object('customer_receipt', v_receipt);
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_approve_payment(
  uuid, uuid, numeric, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_approve_payment(
  uuid, uuid, numeric, text
) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.direct_order_approve_verified_payment(uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_approve_verified_payment(uuid, uuid)
  TO authenticated, service_role;

DO $restore_dispatch_transition$
DECLARE
  v_dispatch regprocedure := to_regprocedure(
    'public.direct_order_set_dispatch(uuid,uuid,text,numeric)'
  );
  v_definition text;
  v_old constant text := $old$  RETURN to_jsonb(v_dispatch) - ARRAY['restaurant_id', 'sent_by'];
$old$;
  v_new constant text := $new$  UPDATE public.direct_delivery_fulfillment_tickets
  SET status = 'dispatched',
      version = version + 1,
      dispatched_at = COALESCE(dispatched_at, now()),
      updated_by = (SELECT auth.uid()),
      updated_at = now()
  WHERE request_id = p_request_id
    AND restaurant_id = p_store_id
    AND status = 'ready';

  RETURN to_jsonb(v_dispatch) - ARRAY['restaurant_id', 'sent_by'];
$new$;
BEGIN
  IF v_dispatch IS NULL THEN
    RAISE EXCEPTION
      'DIRECT_ORDER_PILOT_SAFETY_MIGRATION_FAILED: dispatch missing';
  END IF;
  SELECT pg_get_functiondef(v_dispatch::oid) INTO v_definition;
  IF position(v_old IN v_definition) = 0 THEN
    RAISE EXCEPTION
      'DIRECT_ORDER_PILOT_SAFETY_MIGRATION_FAILED: dispatch return anchor missing';
  END IF;
  EXECUTE replace(v_definition, v_old, v_new);
END;
$restore_dispatch_transition$;

CREATE OR REPLACE FUNCTION public.direct_order_set_dispatch_with_payment_mode(
  p_store_id uuid,
  p_request_id uuid,
  p_grab_tracking_url text,
  p_actual_grab_fee numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_financial public.direct_order_financials%ROWTYPE;
  v_dispatch public.direct_order_dispatches%ROWTYPE;
  v_result jsonb;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  IF lower(COALESCE(p_grab_tracking_url, '')) !~
       '^(https://([[:alnum:]-]+[.])*grab[.]com([/:?#]|$)|https://grab[.]onelink[.]me([/:?#]|$))'
     OR char_length(p_grab_tracking_url) > 2000 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_DISPATCH_INPUT_INVALID';
  END IF;

  SELECT financial.* INTO v_financial
  FROM public.direct_order_financials financial
  WHERE financial.request_id = p_request_id
    AND financial.restaurant_id = p_store_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_NOT_APPROVED'; END IF;

  IF v_financial.delivery_payment_mode = 'store_prepaid' THEN
    IF p_actual_grab_fee IS NULL OR p_actual_grab_fee < 0 THEN
      RAISE EXCEPTION 'DIRECT_ORDER_DISPATCH_INPUT_INVALID';
    END IF;
    v_result := public.direct_order_set_dispatch(
      p_store_id, p_request_id, p_grab_tracking_url, p_actual_grab_fee
    );
    UPDATE public.direct_order_dispatches
    SET delivery_payment_mode = 'store_prepaid'
    WHERE request_id = p_request_id AND restaurant_id = p_store_id
    RETURNING * INTO v_dispatch;
    RETURN (to_jsonb(v_dispatch) - ARRAY['restaurant_id', 'sent_by']) ||
      jsonb_build_object('underlying_result', v_result);
  END IF;

  IF p_actual_grab_fee IS NOT NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CUSTOMER_DIRECT_FEE_MUST_BE_EMPTY';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('direct-order-dispatch:' || p_request_id::text, 0)
  );
  SELECT dispatch.* INTO v_dispatch
  FROM public.direct_order_dispatches dispatch
  WHERE dispatch.request_id = p_request_id
    AND dispatch.restaurant_id = p_store_id
  FOR UPDATE;

  IF FOUND THEN
    IF v_dispatch.actual_grab_fee IS NOT NULL
       OR v_dispatch.cash_paid_at IS NOT NULL
       OR v_dispatch.customer_delivery_fee <> 0 THEN
      RAISE EXCEPTION 'DIRECT_ORDER_DELIVERY_PAYMENT_MODE_CONFLICT';
    END IF;
    UPDATE public.direct_order_dispatches
    SET grab_tracking_url = p_grab_tracking_url,
        delivery_payment_mode = 'customer_direct',
        customer_delivery_fee = 0,
        actual_grab_fee = NULL,
        fee_variance = NULL,
        cash_paid_at = NULL,
        sent_by = (SELECT auth.uid()),
        sent_at = now(),
        updated_at = now()
    WHERE request_id = p_request_id
    RETURNING * INTO v_dispatch;
  ELSE
    INSERT INTO public.direct_order_dispatches(
      request_id, restaurant_id, grab_tracking_url,
      customer_delivery_fee, actual_grab_fee, fee_variance,
      cash_paid_at, delivery_payment_mode, sent_by
    ) VALUES (
      p_request_id, p_store_id, p_grab_tracking_url,
      0, NULL, NULL, NULL, 'customer_direct', (SELECT auth.uid())
    ) RETURNING * INTO v_dispatch;
  END IF;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, sender_auth_id,
    message_type, body, metadata
  ) VALUES (
    p_request_id, p_store_id, 'cashier', (SELECT auth.uid()),
    'grab_link', p_grab_tracking_url,
    jsonb_build_object('delivery_payment_mode', 'customer_direct')
  );

  UPDATE public.direct_delivery_fulfillment_tickets
  SET status = 'dispatched',
      version = version + 1,
      dispatched_at = COALESCE(dispatched_at, now()),
      updated_by = (SELECT auth.uid()),
      updated_at = now()
  WHERE request_id = p_request_id
    AND restaurant_id = p_store_id
    AND status = 'ready';

  RETURN to_jsonb(v_dispatch) - ARRAY['restaurant_id', 'sent_by'];
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_set_dispatch_with_payment_mode(
  uuid, uuid, text, numeric
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_set_dispatch_with_payment_mode(
  uuid, uuid, text, numeric
) TO authenticated, service_role;

DO $verification$
DECLARE
  v_approve_definition text;
BEGIN
  IF to_regprocedure(
    'public.direct_order_staff_quote_with_payment_mode(uuid,uuid,numeric,text,text)'
  ) IS NULL OR to_regprocedure(
    'public.direct_order_approve_verified_payment(uuid,uuid)'
  ) IS NULL OR to_regprocedure(
    'public.direct_order_customer_receipt_status(uuid,uuid)'
  ) IS NULL OR to_regprocedure(
    'public.enqueue_direct_order_customer_receipt(uuid,uuid,boolean)'
  ) IS NULL OR to_regprocedure(
    'public.direct_order_set_dispatch_with_payment_mode(uuid,uuid,text,numeric)'
  ) IS NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PILOT_SAFETY_VERIFY_FAILED: RPC missing';
  END IF;

  SELECT pg_get_functiondef(
    'public.direct_order_approve_payment(uuid,uuid,numeric,text)'::regprocedure
  ) INTO v_approve_definition;
  IF position('direct_order_sepay_candidates payment_link' IN v_approve_definition) = 0
     OR NOT has_function_privilege(
       'authenticated',
       'public.direct_order_approve_payment(uuid,uuid,numeric,text)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.direct_order_approve_verified_payment(uuid,uuid)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PILOT_SAFETY_VERIFY_FAILED: approval gate';
  END IF;
END;
$verification$;

COMMIT;
