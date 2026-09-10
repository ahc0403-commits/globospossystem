-- Add customer order history, VAT/proof-review status, and cashier-confirmed
-- delivery completion without changing the V1 public response contract.
-- production-gate: self-verifying

BEGIN;

DROP INDEX IF EXISTS public.direct_order_requests_one_open_per_session;

DO $remove_single_open_guard$
DECLARE
  v_function regprocedure := to_regprocedure(
    'public.direct_order_public_submit(uuid,text,uuid,jsonb)'
  );
  v_definition text;
  v_guard constant text := $guard$
  IF EXISTS (
    SELECT 1 FROM public.direct_order_requests open_request
    WHERE open_request.session_id = p_session_id
      AND open_request.state IN (
        'awaiting_quote', 'quoted', 'awaiting_payment_review'
      )
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_OPEN_REQUEST_EXISTS';
  END IF;
$guard$;
BEGIN
  IF v_function IS NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CUSTOMER_STATUS_MIGRATION_FAILED: submit missing';
  END IF;
  SELECT pg_get_functiondef(v_function::oid) INTO v_definition;
  IF position(v_guard IN v_definition) = 0 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CUSTOMER_STATUS_MIGRATION_FAILED: open guard missing';
  END IF;
  EXECUTE replace(v_definition, v_guard, E'\n');
END;
$remove_single_open_guard$;

CREATE TABLE public.direct_order_proof_review_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL
    REFERENCES public.direct_order_requests(id) ON DELETE CASCADE,
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  quote_id uuid NOT NULL
    REFERENCES public.direct_order_quotes(id) ON DELETE RESTRICT,
  target_message_id uuid NOT NULL
    REFERENCES public.direct_order_messages(id) ON DELETE RESTRICT,
  replacement_message_id uuid
    REFERENCES public.direct_order_messages(id) ON DELETE RESTRICT,
  reason_code text NOT NULL CHECK (reason_code IN (
    'blurry', 'details_unreadable', 'wrong_transaction',
    'amount_unreadable', 'other'
  )),
  reason_note text,
  status text NOT NULL DEFAULT 'requested' CHECK (
    status IN ('requested', 'resubmitted', 'cancelled')
  ),
  requested_by uuid NOT NULL REFERENCES auth.users(id),
  requested_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  CONSTRAINT direct_order_proof_review_note_valid CHECK (
    reason_note IS NULL OR char_length(reason_note) <= 500
  ),
  CONSTRAINT direct_order_proof_review_resolution_valid CHECK (
    (status = 'requested' AND replacement_message_id IS NULL AND resolved_at IS NULL)
    OR
    (status <> 'requested' AND resolved_at IS NOT NULL)
  )
);

CREATE UNIQUE INDEX direct_order_proof_review_one_open
  ON public.direct_order_proof_review_requests(request_id)
  WHERE status = 'requested';
CREATE INDEX direct_order_proof_review_request_history
  ON public.direct_order_proof_review_requests(request_id, requested_at DESC, id DESC);
CREATE INDEX direct_order_proof_review_store_requested
  ON public.direct_order_proof_review_requests(restaurant_id, requested_at DESC);

ALTER TABLE public.direct_order_proof_review_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.direct_order_proof_review_requests
  FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.direct_order_proof_review_requests TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_staff_request_proof_resubmission(
  p_store_id uuid,
  p_request_id uuid,
  p_target_message_id uuid,
  p_reason_code text,
  p_reason_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_request public.direct_order_requests%ROWTYPE;
  v_quote public.direct_order_quotes%ROWTYPE;
  v_existing public.direct_order_proof_review_requests%ROWTYPE;
  v_review public.direct_order_proof_review_requests%ROWTYPE;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  IF p_reason_code NOT IN (
       'blurry', 'details_unreadable', 'wrong_transaction',
       'amount_unreadable', 'other'
     )
     OR (p_reason_code = 'other'
         AND NULLIF(btrim(COALESCE(p_reason_note, '')), '') IS NULL)
     OR char_length(COALESCE(p_reason_note, '')) > 500 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PROOF_REVIEW_INPUT_INVALID';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('direct-order-proof-review:' || p_request_id::text, 0)
  );
  SELECT * INTO v_request
  FROM public.direct_order_requests request_row
  WHERE request_row.id = p_request_id
    AND request_row.restaurant_id = p_store_id
  FOR UPDATE;
  IF NOT FOUND OR v_request.state <> 'awaiting_payment_review' THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PROOF_REVIEW_NOT_ALLOWED';
  END IF;

  SELECT * INTO v_quote
  FROM public.direct_order_quotes quote
  WHERE quote.request_id = p_request_id
    AND quote.restaurant_id = p_store_id
    AND quote.status = 'locked'
  ORDER BY quote.version DESC
  LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_NOT_FOUND'; END IF;

  PERFORM 1
  FROM public.direct_order_messages message
  WHERE message.id = p_target_message_id
    AND message.request_id = p_request_id
    AND message.restaurant_id = p_store_id
    AND message.message_type = 'payment_proof'
    AND message.attachment_storage_path IS NOT NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_PROOF_NOT_FOUND'; END IF;

  SELECT * INTO v_existing
  FROM public.direct_order_proof_review_requests review
  WHERE review.request_id = p_request_id
    AND review.status = 'requested'
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.target_message_id = p_target_message_id
       AND v_existing.reason_code = p_reason_code
       AND COALESCE(v_existing.reason_note, '') =
           COALESCE(NULLIF(btrim(COALESCE(p_reason_note, '')), ''), '') THEN
      RETURN (to_jsonb(v_existing) - ARRAY['restaurant_id', 'requested_by'])
        || jsonb_build_object('idempotent', true);
    END IF;
    RAISE EXCEPTION 'DIRECT_ORDER_PROOF_REVIEW_ALREADY_OPEN';
  END IF;

  INSERT INTO public.direct_order_proof_review_requests(
    request_id, restaurant_id, quote_id, target_message_id,
    reason_code, reason_note, requested_by
  ) VALUES (
    p_request_id, p_store_id, v_quote.id, p_target_message_id,
    p_reason_code, NULLIF(btrim(COALESCE(p_reason_note, '')), ''),
    (SELECT auth.uid())
  ) RETURNING * INTO v_review;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    (SELECT auth.uid()),
    'direct_order_proof_resubmission_requested',
    'direct_order_requests',
    p_request_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'review_request_id', v_review.id,
      'quote_id', v_quote.id,
      'target_message_id', p_target_message_id,
      'reason_code', p_reason_code
    )
  );

  RETURN (to_jsonb(v_review) - ARRAY['restaurant_id', 'requested_by'])
    || jsonb_build_object('idempotent', false);
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_staff_request_proof_resubmission(
  uuid, uuid, uuid, text, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_request_proof_resubmission(
  uuid, uuid, uuid, text, text
) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_public_commit_proof_v2(
  p_session_id uuid,
  p_secret_hash text,
  p_request_id uuid,
  p_quote_id uuid,
  p_storage_path text,
  p_review_request_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_session public.direct_order_sessions%ROWTYPE;
  v_request public.direct_order_requests%ROWTYPE;
  v_quote public.direct_order_quotes%ROWTYPE;
  v_review public.direct_order_proof_review_requests%ROWTYPE;
  v_message public.direct_order_messages%ROWTYPE;
  v_expected_prefix text;
BEGIN
  v_session := public.direct_order_validate_session(p_session_id, p_secret_hash);
  SELECT * INTO v_request
  FROM public.direct_order_requests request_row
  WHERE request_row.id = p_request_id
    AND request_row.session_id = v_session.id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;

  SELECT * INTO v_quote
  FROM public.direct_order_quotes quote
  WHERE quote.id = p_quote_id
    AND quote.request_id = v_request.id
    AND quote.restaurant_id = v_request.restaurant_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_NOT_FOUND'; END IF;

  v_expected_prefix := v_request.restaurant_id::text || '/'
    || v_request.id::text || '/';
  IF p_storage_path !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}[.](jpg|jpeg|png|webp)$'
     OR position(v_expected_prefix IN p_storage_path) <> 1 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PROOF_PATH_INVALID';
  END IF;

  SELECT * INTO v_message
  FROM public.direct_order_messages message
  WHERE message.request_id = v_request.id
    AND message.restaurant_id = v_request.restaurant_id
    AND message.message_type = 'payment_proof'
    AND message.attachment_storage_path = p_storage_path;

  IF FOUND THEN
    IF NULLIF(v_message.metadata->>'quote_id', '')::uuid IS DISTINCT FROM v_quote.id
       OR NULLIF(v_message.metadata->>'review_request_id', '')::uuid
          IS DISTINCT FROM p_review_request_id THEN
      RAISE EXCEPTION 'DIRECT_ORDER_PROOF_PATH_INVALID';
    END IF;
    RETURN jsonb_build_object(
      'message_id', v_message.id,
      'state', 'awaiting_payment_review',
      'review_request_id', p_review_request_id,
      'idempotent', true
    );
  END IF;

  IF p_review_request_id IS NULL THEN
    IF v_request.state <> 'quoted'
       OR v_quote.status <> 'active'
       OR v_quote.expires_at <= now() THEN
      RAISE EXCEPTION 'DIRECT_ORDER_PROOF_NOT_ALLOWED';
    END IF;
  ELSE
    SELECT * INTO v_review
    FROM public.direct_order_proof_review_requests review
    WHERE review.id = p_review_request_id
      AND review.request_id = v_request.id
      AND review.restaurant_id = v_request.restaurant_id
      AND review.quote_id = v_quote.id
    FOR UPDATE;
    IF NOT FOUND
       OR v_review.status <> 'requested'
       OR v_request.state <> 'awaiting_payment_review'
       OR v_quote.status <> 'locked' THEN
      RAISE EXCEPTION 'DIRECT_ORDER_PROOF_REVIEW_NOT_ALLOWED';
    END IF;
  END IF;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, message_type,
    attachment_storage_path, metadata
  ) VALUES (
    v_request.id,
    v_request.restaurant_id,
    'customer',
    'payment_proof',
    p_storage_path,
    jsonb_build_object(
      'quote_id', v_quote.id,
      'quote_version', v_quote.version,
      'review_request_id', p_review_request_id
    )
  ) RETURNING * INTO v_message;

  IF p_review_request_id IS NULL THEN
    UPDATE public.direct_order_quotes
    SET status = 'locked', locked_at = COALESCE(locked_at, now())
    WHERE id = v_quote.id;
    UPDATE public.direct_order_requests
    SET state = 'awaiting_payment_review', updated_at = now()
    WHERE id = v_request.id;
  ELSE
    UPDATE public.direct_order_proof_review_requests
    SET status = 'resubmitted',
        replacement_message_id = v_message.id,
        resolved_at = COALESCE(resolved_at, now())
    WHERE id = p_review_request_id
      AND status = 'requested';
    IF NOT FOUND THEN
      SELECT * INTO v_review
      FROM public.direct_order_proof_review_requests review
      WHERE review.id = p_review_request_id;
      IF v_review.replacement_message_id IS DISTINCT FROM v_message.id THEN
        RAISE EXCEPTION 'DIRECT_ORDER_PROOF_REVIEW_NOT_ALLOWED';
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'message_id', v_message.id,
    'state', 'awaiting_payment_review',
    'review_request_id', p_review_request_id,
    'idempotent', false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_public_commit_proof_v2(
  uuid, text, uuid, uuid, text, uuid
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_commit_proof_v2(
  uuid, text, uuid, uuid, text, uuid
) TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_public_status_v2(
  p_session_id uuid,
  p_secret_hash text,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_base jsonb;
  v_quote public.direct_order_quotes%ROWTYPE;
BEGIN
  v_base := public.direct_order_public_status(
    p_session_id, p_secret_hash, p_request_id
  );
  SELECT * INTO v_quote
  FROM public.direct_order_quotes quote
  WHERE quote.id = NULLIF(v_base->'quote'->>'id', '')::uuid;

  RETURN v_base || jsonb_build_object(
    'quote', CASE WHEN v_quote.id IS NULL THEN NULL ELSE
      (v_base->'quote') || jsonb_build_object(
        'version', v_quote.version,
        'menu_pretax', v_quote.menu_pretax,
        'menu_vat', v_quote.menu_vat,
        'service_charge_pretax', v_quote.service_charge_pretax,
        'service_charge_vat', v_quote.service_charge_vat,
        'delivery_fee_pretax', v_quote.delivery_fee_pretax,
        'delivery_fee_vat', v_quote.delivery_fee_vat,
        'vat_total', round(
          v_quote.menu_vat + v_quote.service_charge_vat + v_quote.delivery_fee_vat,
          2
        ),
        'delivery_payment_mode', v_quote.delivery_payment_mode
      ) END,
    'proof_review', (
      SELECT jsonb_build_object(
        'id', review.id,
        'reason_code', review.reason_code,
        'reason_note', review.reason_note,
        'requested_at', review.requested_at,
        'can_resubmit', true
      )
      FROM public.direct_order_proof_review_requests review
      WHERE review.request_id = p_request_id
        AND review.status = 'requested'
      ORDER BY review.requested_at DESC, review.id DESC
      LIMIT 1
    ),
    'fulfillment', (
      SELECT jsonb_build_object(
        'status', ticket.status,
        'pickup_code', ticket.pickup_code,
        'version', ticket.version,
        'updated_at', ticket.updated_at,
        'completed_at', ticket.completed_at
      )
      FROM public.direct_delivery_fulfillment_tickets ticket
      WHERE ticket.request_id = p_request_id
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_public_status_v2(uuid, text, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_status_v2(uuid, text, uuid)
  TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_public_orders_v2(
  p_session_id uuid,
  p_secret_hash text,
  p_limit integer DEFAULT 50
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_session public.direct_order_sessions%ROWTYPE;
BEGIN
  IF p_limit NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_LIMIT_INVALID';
  END IF;
  v_session := public.direct_order_validate_session(p_session_id, p_secret_hash);

  RETURN COALESCE((
    SELECT jsonb_agg(summary ORDER BY created_at DESC, id DESC)
    FROM (
      SELECT request_row.created_at, request_row.id, jsonb_build_object(
        'request_id', request_row.id,
        'reference_code', request_row.reference_code,
        'state', request_row.state,
        'created_at', request_row.created_at,
        'item_count', (
          SELECT COALESCE(sum(item.quantity), 0)
          FROM public.direct_order_request_items item
          WHERE item.request_id = request_row.id
        ),
        'final_total', quote.final_total,
        'fulfillment_status', ticket.status,
        'completed_at', ticket.completed_at,
        'has_open_proof_review', EXISTS (
          SELECT 1 FROM public.direct_order_proof_review_requests review
          WHERE review.request_id = request_row.id
            AND review.status = 'requested'
        )
      ) AS summary
      FROM public.direct_order_requests request_row
      LEFT JOIN LATERAL (
        SELECT row_quote.final_total
        FROM public.direct_order_quotes row_quote
        WHERE row_quote.request_id = request_row.id
          AND row_quote.status IN ('active', 'locked')
        ORDER BY row_quote.version DESC LIMIT 1
      ) quote ON true
      LEFT JOIN public.direct_delivery_fulfillment_tickets ticket
        ON ticket.request_id = request_row.id
      WHERE request_row.session_id = v_session.id
        AND request_row.restaurant_id = v_session.restaurant_id
        AND request_row.created_at >= v_session.created_at
      ORDER BY request_row.created_at DESC, request_row.id DESC
      LIMIT p_limit
    ) page
  ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_public_orders_v2(uuid, text, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_orders_v2(uuid, text, integer)
  TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_staff_list_v2(
  p_store_id uuid,
  p_states text[] DEFAULT NULL,
  p_limit integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_day_start timestamptz;
  v_day_end timestamptz;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  IF p_limit NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_LIMIT_INVALID';
  END IF;
  v_day_start := (
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp
    AT TIME ZONE 'Asia/Ho_Chi_Minh'
  );
  v_day_end := v_day_start + interval '1 day';

  RETURN COALESCE((
    SELECT jsonb_agg(summary ORDER BY created_at DESC, id DESC)
    FROM (
      SELECT request_row.created_at, request_row.id, jsonb_build_object(
        'id', request_row.id,
        'reference_code', request_row.reference_code,
        'state', request_row.state,
        'created_at', request_row.created_at,
        'customer_name', address.customer_name,
        'formatted_address', address.formatted_address,
        'district', address.district,
        'item_count', (
          SELECT COALESCE(sum(item.quantity), 0)
          FROM public.direct_order_request_items item
          WHERE item.request_id = request_row.id
        ),
        'final_total', quote.final_total,
        'has_payment_proof', EXISTS (
          SELECT 1 FROM public.direct_order_messages message
          WHERE message.request_id = request_row.id
            AND message.message_type = 'payment_proof'
        ),
        'has_open_proof_review', EXISTS (
          SELECT 1 FROM public.direct_order_proof_review_requests review
          WHERE review.request_id = request_row.id
            AND review.status = 'requested'
        ),
        'fulfillment_status', ticket.status,
        'fulfillment_version', ticket.version,
        'completed_at', ticket.completed_at,
        'last_message_at', (
          SELECT max(message.created_at)
          FROM public.direct_order_messages message
          WHERE message.request_id = request_row.id
        )
      ) AS summary
      FROM public.direct_order_requests request_row
      LEFT JOIN public.direct_order_request_addresses address
        ON address.request_id = request_row.id
      LEFT JOIN LATERAL (
        SELECT row_quote.final_total
        FROM public.direct_order_quotes row_quote
        WHERE row_quote.request_id = request_row.id
          AND row_quote.status IN ('active', 'locked')
        ORDER BY row_quote.version DESC LIMIT 1
      ) quote ON true
      LEFT JOIN public.direct_delivery_fulfillment_tickets ticket
        ON ticket.request_id = request_row.id
      WHERE request_row.restaurant_id = p_store_id
        AND (p_states IS NULL OR request_row.state = ANY(p_states))
        AND (
          request_row.created_at >= v_day_start
          AND request_row.created_at < v_day_end
          OR request_row.state IN ('awaiting_quote', 'quoted', 'awaiting_payment_review')
          OR ticket.status NOT IN ('completed', 'cancelled')
        )
      ORDER BY request_row.created_at DESC, request_row.id DESC
      LIMIT p_limit
    ) page
  ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_staff_list_v2(uuid, text[], integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_list_v2(uuid, text[], integer)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_staff_detail_v2(
  p_store_id uuid,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_base jsonb;
BEGIN
  v_base := public.direct_order_staff_detail(p_store_id, p_request_id);
  RETURN v_base || jsonb_build_object(
    'fulfillment', (
      SELECT to_jsonb(ticket) - ARRAY['restaurant_id', 'updated_by']
      FROM public.direct_delivery_fulfillment_tickets ticket
      WHERE ticket.request_id = p_request_id
        AND ticket.restaurant_id = p_store_id
    ),
    'proof_reviews', COALESCE((
      SELECT jsonb_agg(
        to_jsonb(review) - ARRAY['restaurant_id', 'requested_by']
        ORDER BY review.requested_at DESC, review.id DESC
      )
      FROM public.direct_order_proof_review_requests review
      WHERE review.request_id = p_request_id
        AND review.restaurant_id = p_store_id
    ), '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_staff_detail_v2(uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_detail_v2(uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_delivery_ticket_transition(
  p_store_id uuid,
  p_ticket_id uuid,
  p_expected_version integer,
  p_next_status text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_ticket public.direct_delivery_fulfillment_tickets%ROWTYPE;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    CASE WHEN p_next_status = 'completed'
      THEN ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
      ELSE ARRAY['kitchen', 'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
    END
  );
  SELECT * INTO v_ticket
  FROM public.direct_delivery_fulfillment_tickets ticket
  WHERE ticket.id = p_ticket_id
    AND ticket.restaurant_id = p_store_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_DELIVERY_TICKET_NOT_FOUND'; END IF;
  IF v_ticket.version <> p_expected_version THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_TICKET_VERSION_CONFLICT';
  END IF;
  IF NOT (
    (v_ticket.status = 'pending' AND p_next_status IN ('preparing', 'cancelled'))
    OR (v_ticket.status = 'preparing' AND p_next_status IN ('ready', 'cancelled'))
    OR (v_ticket.status = 'ready' AND p_next_status IN ('dispatched', 'cancelled'))
    OR (v_ticket.status = 'dispatched' AND p_next_status = 'completed')
  ) THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_TICKET_TRANSITION_INVALID';
  END IF;

  UPDATE public.direct_delivery_fulfillment_tickets
  SET status = p_next_status,
      version = version + 1,
      accepted_at = CASE WHEN p_next_status = 'preparing' THEN now() ELSE accepted_at END,
      ready_at = CASE WHEN p_next_status = 'ready' THEN now() ELSE ready_at END,
      dispatched_at = CASE WHEN p_next_status = 'dispatched' THEN now() ELSE dispatched_at END,
      completed_at = CASE WHEN p_next_status = 'completed' THEN now() ELSE completed_at END,
      cancelled_at = CASE WHEN p_next_status = 'cancelled' THEN now() ELSE cancelled_at END,
      updated_by = (SELECT auth.uid()),
      updated_at = now()
  WHERE id = v_ticket.id
  RETURNING * INTO v_ticket;

  RETURN to_jsonb(v_ticket) - ARRAY['restaurant_id', 'updated_by'];
END;
$$;

REVOKE ALL ON FUNCTION public.direct_delivery_ticket_transition(uuid, uuid, integer, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_delivery_ticket_transition(uuid, uuid, integer, text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_cashier_complete_delivery(
  p_store_id uuid,
  p_request_id uuid,
  p_expected_version integer
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_ticket public.direct_delivery_fulfillment_tickets%ROWTYPE;
  v_result jsonb;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  PERFORM pg_advisory_xact_lock(
    hashtextextended('direct-order-complete:' || p_request_id::text, 0)
  );
  SELECT * INTO v_ticket
  FROM public.direct_delivery_fulfillment_tickets ticket
  WHERE ticket.request_id = p_request_id
    AND ticket.restaurant_id = p_store_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_DELIVERY_TICKET_NOT_FOUND'; END IF;
  IF v_ticket.status = 'completed' THEN
    RETURN (to_jsonb(v_ticket) - ARRAY['restaurant_id', 'updated_by'])
      || jsonb_build_object('idempotent', true);
  END IF;
  IF v_ticket.status <> 'dispatched' THEN
    RAISE EXCEPTION 'DIRECT_ORDER_DELIVERY_NOT_DISPATCHED';
  END IF;

  v_result := public.direct_delivery_ticket_transition(
    p_store_id, v_ticket.id, p_expected_version, 'completed'
  );

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, sender_auth_id,
    message_type, body
  ) VALUES (
    p_request_id, p_store_id, 'cashier', (SELECT auth.uid()),
    'system', 'DIRECT_ORDER_DELIVERY_COMPLETED'
  );
  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    (SELECT auth.uid()),
    'direct_order_delivery_completed',
    'direct_order_requests',
    p_request_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'ticket_id', v_ticket.id,
      'from_status', 'dispatched',
      'to_status', 'completed',
      'expected_version', p_expected_version
    )
  );
  RETURN v_result || jsonb_build_object('idempotent', false);
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_cashier_complete_delivery(
  uuid, uuid, integer
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_cashier_complete_delivery(
  uuid, uuid, integer
) TO authenticated, service_role;

DO $block_approval_during_review$
DECLARE
  v_function regprocedure := to_regprocedure(
    'public.direct_order_approve_payment(uuid,uuid,numeric,text)'
  );
  v_definition text;
  v_anchor constant text := $anchor$
  IF v_request.state <> 'awaiting_payment_review' THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_APPROVABLE';
  END IF;
$anchor$;
  v_replacement constant text := $replacement$
  IF v_request.state <> 'awaiting_payment_review' THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_APPROVABLE';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.direct_order_proof_review_requests review
    WHERE review.request_id = p_request_id
      AND review.restaurant_id = p_store_id
      AND review.status = 'requested'
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PROOF_RESUBMISSION_PENDING';
  END IF;
$replacement$;
BEGIN
  IF v_function IS NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CUSTOMER_STATUS_MIGRATION_FAILED: approval missing';
  END IF;
  SELECT pg_get_functiondef(v_function::oid) INTO v_definition;
  IF position(v_anchor IN v_definition) = 0 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CUSTOMER_STATUS_MIGRATION_FAILED: approval anchor missing';
  END IF;
  EXECUTE replace(v_definition, v_anchor, v_replacement);
END;
$block_approval_during_review$;

DO $verify$
DECLARE
  v_submit text;
  v_approve text;
  v_transition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.direct_order_public_submit(uuid,text,uuid,jsonb)'::regprocedure
  ) INTO v_submit;
  SELECT pg_get_functiondef(
    'public.direct_order_approve_payment(uuid,uuid,numeric,text)'::regprocedure
  ) INTO v_approve;
  SELECT pg_get_functiondef(
    'public.direct_delivery_ticket_transition(uuid,uuid,integer,text)'::regprocedure
  ) INTO v_transition;
  IF to_regclass('public.direct_order_proof_review_requests') IS NULL
     OR to_regclass('public.direct_order_requests_one_open_per_session') IS NOT NULL
     OR NOT (
       SELECT class_row.relrowsecurity
       FROM pg_class class_row
       WHERE class_row.oid = 'public.direct_order_proof_review_requests'::regclass
     )
     OR has_table_privilege(
       'anon', 'public.direct_order_proof_review_requests', 'SELECT'
     )
     OR has_table_privilege(
       'authenticated', 'public.direct_order_proof_review_requests', 'SELECT'
     )
     OR NOT has_table_privilege(
       'service_role', 'public.direct_order_proof_review_requests',
       'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
     )
     OR to_regprocedure(
       'public.direct_order_staff_request_proof_resubmission(uuid,uuid,uuid,text,text)'
     ) IS NULL
     OR to_regprocedure(
       'public.direct_order_public_commit_proof_v2(uuid,text,uuid,uuid,text,uuid)'
     ) IS NULL
     OR to_regprocedure('public.direct_order_public_status_v2(uuid,text,uuid)') IS NULL
     OR to_regprocedure('public.direct_order_public_orders_v2(uuid,text,integer)') IS NULL
     OR to_regprocedure(
       'public.direct_order_staff_list_v2(uuid,text[],integer)'
     ) IS NULL
     OR to_regprocedure(
       'public.direct_order_staff_detail_v2(uuid,uuid)'
     ) IS NULL
     OR to_regprocedure('public.direct_order_cashier_complete_delivery(uuid,uuid,integer)') IS NULL
     OR position('DIRECT_ORDER_OPEN_REQUEST_EXISTS' IN v_submit) > 0
     OR position('DIRECT_ORDER_PROOF_RESUBMISSION_PENDING' IN v_approve) = 0
     OR position('CASE WHEN p_next_status = ''completed''' IN v_transition) = 0 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CUSTOMER_STATUS_MIGRATION_VERIFY_FAILED';
  END IF;
END;
$verify$;

COMMIT;
