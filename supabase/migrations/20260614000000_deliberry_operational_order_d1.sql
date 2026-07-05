-- ============================================================
-- Deliberry operational order D1
-- 2026-06-14
--
-- Adds a POS-scoped operational inbox and action event surface for
-- Deliberry orders. This is intentionally separate from settlement revenue.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.deliberry_operational_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  source_system TEXT NOT NULL DEFAULT 'deliberry'
    CHECK (source_system IN ('deliberry')),
  external_order_id TEXT NOT NULL,
  order_no TEXT NULL,
  trace_id TEXT NOT NULL,
  payload_version TEXT NOT NULL DEFAULT 'deliberry.operational_order.v1',
  channel_id TEXT NOT NULL DEFAULT 'DELIBERRY',
  status TEXT NOT NULL DEFAULT 'new'
    CHECK (
      status IN (
        'new',
        'accepted',
        'rejected',
        'ready',
        'delivered',
        'customer_cancelled'
      )
    ),
  state_version INTEGER NOT NULL DEFAULT 0 CHECK (state_version >= 0),
  last_event_sequence BIGINT NOT NULL DEFAULT 0,
  gross_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (gross_amount >= 0),
  payment_status TEXT NULL,
  payment_method TEXT NULL,
  collection_mode TEXT NULL,
  customer_name TEXT NULL,
  customer_note TEXT NULL,
  reject_reason TEXT NULL,
  payload JSONB NOT NULL DEFAULT '{}'::JSONB,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  accepted_at TIMESTAMPTZ NULL,
  rejected_at TIMESTAMPTZ NULL,
  ready_at TIMESTAMPTZ NULL,
  delivered_at TIMESTAMPTZ NULL,
  customer_cancelled_at TIMESTAMPTZ NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT deliberry_operational_orders_unique_external_order
    UNIQUE (restaurant_id, source_system, external_order_id)
);

CREATE INDEX IF NOT EXISTS idx_deliberry_operational_orders_store_status
  ON public.deliberry_operational_orders (restaurant_id, status, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_deliberry_operational_orders_trace
  ON public.deliberry_operational_orders (trace_id);

CREATE TABLE IF NOT EXISTS public.deliberry_operational_order_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operational_order_id UUID NOT NULL
    REFERENCES public.deliberry_operational_orders(id) ON DELETE CASCADE,
  restaurant_id UUID NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  source_system TEXT NOT NULL CHECK (source_system IN ('deliberry', 'pos')),
  destination_system TEXT NOT NULL CHECK (destination_system IN ('pos', 'deliberry')),
  event_id TEXT NOT NULL,
  trace_id TEXT NOT NULL,
  payload_version TEXT NOT NULL DEFAULT 'deliberry.operational_order.v1',
  channel_id TEXT NOT NULL DEFAULT 'DELIBERRY',
  event_sequence BIGINT NOT NULL DEFAULT 0,
  event_occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  event_type TEXT NOT NULL
    CHECK (
      event_type IN (
        'DELIBERRY_ORDER_RECEIVED',
        'DELIBERRY_ORDER_ACCEPTED',
        'DELIBERRY_ORDER_REJECTED',
        'DELIBERRY_ORDER_READY',
        'DELIBERRY_ORDER_DELIVERED',
        'DELIBERRY_ORDER_CUSTOMER_CANCELLED'
      )
    ),
  external_order_id TEXT NOT NULL,
  actor_id UUID NULL REFERENCES auth.users(id),
  reason TEXT NULL,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processed', 'failed', 'dead')),
  state_applied BOOLEAN NOT NULL DEFAULT false,
  state_error TEXT NULL,
  payload JSONB NOT NULL DEFAULT '{}'::JSONB,
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  last_error TEXT NULL,
  processed_at TIMESTAMPTZ NULL,
  dead_letter_at TIMESTAMPTZ NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT deliberry_operational_order_events_unique_event
    UNIQUE (restaurant_id, source_system, event_id)
);

CREATE INDEX IF NOT EXISTS idx_deliberry_operational_events_store_created
  ON public.deliberry_operational_order_events (restaurant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_deliberry_operational_events_retry
  ON public.deliberry_operational_order_events (
    restaurant_id,
    destination_system,
    status,
    created_at ASC
  );

CREATE INDEX IF NOT EXISTS idx_deliberry_operational_events_trace
  ON public.deliberry_operational_order_events (trace_id, created_at ASC);

ALTER TABLE public.deliberry_operational_orders
  ADD COLUMN IF NOT EXISTS state_version INTEGER NOT NULL DEFAULT 0 CHECK (state_version >= 0);

UPDATE public.deliberry_operational_orders
SET state_version = 0
WHERE state_version IS NULL;

ALTER TABLE public.deliberry_operational_orders
  ALTER COLUMN state_version SET DEFAULT 0,
  ALTER COLUMN state_version SET NOT NULL;

ALTER TABLE public.deliberry_operational_orders
  ADD COLUMN IF NOT EXISTS last_event_sequence BIGINT NOT NULL DEFAULT 0;

UPDATE public.deliberry_operational_orders
SET last_event_sequence = 0
WHERE last_event_sequence IS NULL;

ALTER TABLE public.deliberry_operational_orders
  ALTER COLUMN last_event_sequence SET DEFAULT 0,
  ALTER COLUMN last_event_sequence SET NOT NULL;

ALTER TABLE public.deliberry_operational_order_events
  ADD COLUMN IF NOT EXISTS event_sequence BIGINT NOT NULL DEFAULT 0;

UPDATE public.deliberry_operational_order_events
SET event_sequence = 0
WHERE event_sequence IS NULL;

ALTER TABLE public.deliberry_operational_order_events
  ALTER COLUMN event_sequence SET DEFAULT 0,
  ALTER COLUMN event_sequence SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_deliberry_operational_events_order_sequence
  ON public.deliberry_operational_order_events (
    restaurant_id,
    external_order_id,
    event_sequence
  );

ALTER TABLE public.deliberry_operational_order_events
  ADD COLUMN IF NOT EXISTS event_occurred_at TIMESTAMPTZ NOT NULL DEFAULT now();

UPDATE public.deliberry_operational_order_events
SET event_occurred_at = COALESCE(created_at, now())
WHERE event_occurred_at IS NULL;

ALTER TABLE public.deliberry_operational_order_events
  ALTER COLUMN event_occurred_at SET DEFAULT now(),
  ALTER COLUMN event_occurred_at SET NOT NULL;

ALTER TABLE public.deliberry_operational_order_events
  ADD COLUMN IF NOT EXISTS state_applied BOOLEAN NOT NULL DEFAULT false;

UPDATE public.deliberry_operational_order_events
SET state_applied = false
WHERE state_applied IS NULL;

ALTER TABLE public.deliberry_operational_order_events
  ALTER COLUMN state_applied SET DEFAULT false,
  ALTER COLUMN state_applied SET NOT NULL;

ALTER TABLE public.deliberry_operational_order_events
  ADD COLUMN IF NOT EXISTS state_error TEXT NULL;

ALTER TABLE public.deliberry_operational_order_events
  DROP CONSTRAINT IF EXISTS deliberry_operational_order_events_unique_event;

ALTER TABLE public.deliberry_operational_order_events
  ADD CONSTRAINT deliberry_operational_order_events_unique_event
  UNIQUE (restaurant_id, source_system, event_id);

ALTER TABLE public.deliberry_operational_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deliberry_operational_order_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS deliberry_operational_orders_scoped_read
  ON public.deliberry_operational_orders;
CREATE POLICY deliberry_operational_orders_scoped_read
  ON public.deliberry_operational_orders
  FOR SELECT
  TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id = deliberry_operational_orders.restaurant_id
    )
  );

DROP POLICY IF EXISTS deliberry_operational_order_events_scoped_read
  ON public.deliberry_operational_order_events;
CREATE POLICY deliberry_operational_order_events_scoped_read
  ON public.deliberry_operational_order_events
  FOR SELECT
  TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id = deliberry_operational_order_events.restaurant_id
    )
  );

CREATE OR REPLACE FUNCTION public.assert_deliberry_operational_store_action_scope(
  p_store_id UUID,
  p_allowed_roles TEXT[]
) RETURNS VOID AS $$
DECLARE
  v_role TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'DELIBERRY_ORDER_ACTOR_REQUIRED';
  END IF;

  SELECT role
  INTO v_role
  FROM public.users
  WHERE auth_id = auth.uid();

  IF v_role IS NULL OR NOT (v_role = ANY(p_allowed_roles)) THEN
    RAISE EXCEPTION 'DELIBERRY_ORDER_ROLE_DENIED';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'DELIBERRY_ORDER_STORE_SCOPE_DENIED';
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.deliberry_operational_transition_allowed(
  p_current_status TEXT,
  p_event_status TEXT
) RETURNS BOOLEAN AS $$
BEGIN
  IF p_event_status IS NULL THEN
    RETURN false;
  END IF;

  IF p_current_status IS NULL THEN
    RETURN p_event_status = 'new';
  END IF;

  IF p_event_status = 'new' THEN
    RETURN true;
  END IF;

  IF p_current_status = p_event_status THEN
    RETURN true;
  END IF;

  IF p_current_status = 'new'
     AND p_event_status IN ('accepted', 'rejected', 'customer_cancelled') THEN
    RETURN true;
  END IF;

  IF p_current_status = 'accepted'
     AND p_event_status IN ('ready', 'customer_cancelled') THEN
    RETURN true;
  END IF;

  IF p_current_status = 'ready'
     AND p_event_status IN ('delivered', 'customer_cancelled') THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION public.deliberry_operational_next_status(
  p_current_status TEXT,
  p_event_status TEXT
) RETURNS TEXT AS $$
BEGIN
  IF p_event_status IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_current_status IS NULL THEN
    IF p_event_status = 'new' THEN
      RETURN 'new';
    END IF;
    RETURN NULL;
  END IF;

  IF p_current_status IN ('rejected', 'delivered', 'customer_cancelled') THEN
    IF p_current_status = p_event_status THEN
      RETURN p_current_status;
    END IF;
    RETURN NULL;
  END IF;

  IF p_current_status = p_event_status THEN
    RETURN p_current_status;
  END IF;

  IF p_current_status = 'new'
     AND p_event_status IN ('accepted', 'rejected', 'customer_cancelled') THEN
    RETURN p_event_status;
  END IF;

  IF p_current_status = 'accepted'
     AND p_event_status IN ('ready', 'customer_cancelled') THEN
    RETURN p_event_status;
  END IF;

  IF p_current_status = 'ready'
     AND p_event_status IN ('delivered', 'customer_cancelled') THEN
    RETURN p_event_status;
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION public.apply_deliberry_operational_order_event(
  p_store_id UUID,
  p_external_order_id TEXT,
  p_event_id TEXT,
  p_event_type TEXT,
  p_payload JSONB DEFAULT '{}'::JSONB,
  p_actor_id UUID DEFAULT NULL,
  p_reason TEXT DEFAULT NULL,
  p_source_system TEXT DEFAULT 'deliberry',
  p_destination_system TEXT DEFAULT 'pos'
) RETURNS public.deliberry_operational_orders AS $$
DECLARE
  v_event public.deliberry_operational_order_events%ROWTYPE;
  v_existing_order public.deliberry_operational_orders%ROWTYPE;
  v_order public.deliberry_operational_orders%ROWTYPE;
  v_status TEXT;
  v_next_status TEXT;
  v_effective_status TEXT;
  v_trace_id TEXT;
  v_payload_version TEXT;
  v_channel_id TEXT;
  v_event_sequence BIGINT;
  v_event_occurred_at TIMESTAMPTZ;
  v_has_existing_order BOOLEAN := false;
  v_state_applied BOOLEAN := false;
  v_state_error TEXT;
  v_now TIMESTAMPTZ := now();
BEGIN
  IF NULLIF(btrim(COALESCE(p_external_order_id, '')), '') IS NULL THEN
    RAISE EXCEPTION 'DELIBERRY_EXTERNAL_ORDER_ID_REQUIRED';
  END IF;

  IF NULLIF(btrim(COALESCE(p_event_id, '')), '') IS NULL THEN
    RAISE EXCEPTION 'DELIBERRY_EVENT_ID_REQUIRED';
  END IF;

  v_status := CASE p_event_type
    WHEN 'DELIBERRY_ORDER_RECEIVED' THEN 'new'
    WHEN 'DELIBERRY_ORDER_ACCEPTED' THEN 'accepted'
    WHEN 'DELIBERRY_ORDER_REJECTED' THEN 'rejected'
    WHEN 'DELIBERRY_ORDER_READY' THEN 'ready'
    WHEN 'DELIBERRY_ORDER_DELIVERED' THEN 'delivered'
    WHEN 'DELIBERRY_ORDER_CUSTOMER_CANCELLED' THEN 'customer_cancelled'
    ELSE NULL
  END;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'DELIBERRY_ORDER_EVENT_TYPE_UNSUPPORTED';
  END IF;

  v_trace_id := COALESCE(
    NULLIF(btrim(COALESCE(p_payload->>'trace_id', '')), ''),
    'deliberry:' || p_store_id::TEXT || ':' || p_external_order_id
  );
  v_payload_version := COALESCE(
    NULLIF(btrim(COALESCE(p_payload->>'payload_version', '')), ''),
    'deliberry.operational_order.v1'
  );
  v_channel_id := COALESCE(
    NULLIF(btrim(COALESCE(p_payload->>'channel_id', '')), ''),
    'DELIBERRY'
  );
  v_event_sequence := COALESCE(
    NULLIF(btrim(COALESCE(p_payload->>'event_sequence', '')), '')::BIGINT,
    0
  );
  v_event_occurred_at := COALESCE(
    NULLIF(btrim(COALESCE(p_payload->>'event_occurred_at', '')), '')::TIMESTAMPTZ,
    NULLIF(btrim(COALESCE(p_payload->>'occurred_at', '')), '')::TIMESTAMPTZ,
    v_now
  );

  PERFORM pg_advisory_xact_lock(
    hashtext('deliberry_order:' || p_store_id::TEXT || ':' || p_external_order_id)
  );

  SELECT *
  INTO v_event
  FROM public.deliberry_operational_order_events
  WHERE restaurant_id = p_store_id
    AND source_system = p_source_system
    AND event_id = p_event_id
  LIMIT 1;

  IF FOUND THEN
    SELECT *
    INTO v_order
    FROM public.deliberry_operational_orders
    WHERE id = v_event.operational_order_id;
    RETURN v_order;
  END IF;

  SELECT *
  INTO v_existing_order
  FROM public.deliberry_operational_orders
  WHERE restaurant_id = p_store_id
    AND source_system = 'deliberry'
    AND external_order_id = p_external_order_id
  FOR UPDATE;

  v_has_existing_order := FOUND;
  v_next_status := public.deliberry_operational_next_status(
    CASE WHEN v_has_existing_order THEN v_existing_order.status END,
    v_status
  );

  IF v_has_existing_order
     AND v_event_sequence > 0
     AND v_existing_order.last_event_sequence > 0
     AND v_event_sequence <= v_existing_order.last_event_sequence THEN
    v_effective_status := v_existing_order.status;
    v_state_error := 'DELIBERRY_ORDER_STALE_EVENT_SEQUENCE';
  ELSIF v_next_status IS NULL THEN
    v_effective_status := CASE
      WHEN v_has_existing_order THEN v_existing_order.status
      ELSE 'new'
    END;
    v_state_error := 'DELIBERRY_ORDER_INVALID_STATE_TRANSITION';
  ELSE
    v_effective_status := v_next_status;
    v_state_applied := NOT v_has_existing_order
      OR v_next_status IS DISTINCT FROM v_existing_order.status;
  END IF;

  IF v_has_existing_order THEN
    UPDATE public.deliberry_operational_orders
    SET
      status = v_effective_status,
      state_version = state_version + CASE WHEN v_state_applied THEN 1 ELSE 0 END,
      last_event_sequence = CASE
        WHEN v_state_applied AND v_event_sequence > last_event_sequence THEN v_event_sequence
        ELSE last_event_sequence
      END,
      order_no = COALESCE(NULLIF(p_payload->>'order_no', ''), order_no),
      trace_id = COALESCE(NULLIF(btrim(COALESCE(p_payload->>'trace_id', '')), ''), trace_id),
      payload_version = COALESCE(NULLIF(btrim(COALESCE(p_payload->>'payload_version', '')), ''), payload_version),
      channel_id = COALESCE(NULLIF(btrim(COALESCE(p_payload->>'channel_id', '')), ''), channel_id),
      gross_amount = CASE
        WHEN COALESCE(NULLIF(p_payload->>'gross_amount', '')::NUMERIC, 0) > 0
          THEN COALESCE(NULLIF(p_payload->>'gross_amount', '')::NUMERIC, 0)
        ELSE gross_amount
      END,
      payment_status = COALESCE(NULLIF(p_payload->>'payment_status', ''), payment_status),
      payment_method = COALESCE(NULLIF(p_payload->>'payment_method', ''), payment_method),
      collection_mode = COALESCE(
        NULLIF(p_payload->>'collection_mode', ''),
        NULLIF(p_payload->>'settlement_collection_mode', ''),
        collection_mode
      ),
      customer_name = COALESCE(NULLIF(p_payload->>'customer_name', ''), customer_name),
      customer_note = COALESCE(NULLIF(p_payload->>'customer_note', ''), customer_note),
      reject_reason = COALESCE(NULLIF(COALESCE(p_reason, p_payload->>'reject_reason'), ''), reject_reason),
      payload = payload || COALESCE(p_payload, '{}'::JSONB),
      accepted_at = CASE
        WHEN v_state_applied AND v_effective_status = 'accepted' THEN COALESCE(accepted_at, v_now)
        ELSE accepted_at
      END,
      rejected_at = CASE
        WHEN v_state_applied AND v_effective_status = 'rejected' THEN COALESCE(rejected_at, v_now)
        ELSE rejected_at
      END,
      ready_at = CASE
        WHEN v_state_applied AND v_effective_status = 'ready' THEN COALESCE(ready_at, v_now)
        ELSE ready_at
      END,
      delivered_at = CASE
        WHEN v_state_applied AND v_effective_status = 'delivered' THEN COALESCE(delivered_at, v_now)
        ELSE delivered_at
      END,
      customer_cancelled_at = CASE
        WHEN v_state_applied AND v_effective_status = 'customer_cancelled'
          THEN COALESCE(customer_cancelled_at, v_now)
        ELSE customer_cancelled_at
      END,
      updated_at = CASE WHEN v_state_applied THEN v_now ELSE updated_at END
    WHERE id = v_existing_order.id
    RETURNING * INTO v_order;
  ELSE
    INSERT INTO public.deliberry_operational_orders (
      restaurant_id,
      source_system,
      external_order_id,
      order_no,
      trace_id,
      payload_version,
      channel_id,
      status,
      state_version,
      last_event_sequence,
      gross_amount,
      payment_status,
      payment_method,
      collection_mode,
      customer_name,
      customer_note,
      reject_reason,
      payload,
      received_at,
      accepted_at,
      rejected_at,
      ready_at,
      delivered_at,
      customer_cancelled_at,
      updated_at
    )
    VALUES (
      p_store_id,
      'deliberry',
      p_external_order_id,
      NULLIF(p_payload->>'order_no', ''),
      v_trace_id,
      v_payload_version,
      v_channel_id,
      v_effective_status,
      CASE WHEN v_state_applied THEN 1 ELSE 0 END,
      CASE WHEN v_state_applied THEN v_event_sequence ELSE 0 END,
      COALESCE(NULLIF(p_payload->>'gross_amount', '')::NUMERIC, 0),
      NULLIF(p_payload->>'payment_status', ''),
      NULLIF(p_payload->>'payment_method', ''),
      COALESCE(
        NULLIF(p_payload->>'collection_mode', ''),
        NULLIF(p_payload->>'settlement_collection_mode', '')
      ),
      NULLIF(p_payload->>'customer_name', ''),
      NULLIF(p_payload->>'customer_note', ''),
      NULLIF(COALESCE(p_reason, p_payload->>'reject_reason'), ''),
      COALESCE(p_payload, '{}'::JSONB),
      v_now,
      CASE WHEN v_state_applied AND v_effective_status = 'accepted' THEN v_now END,
      CASE WHEN v_state_applied AND v_effective_status = 'rejected' THEN v_now END,
      CASE WHEN v_state_applied AND v_effective_status = 'ready' THEN v_now END,
      CASE WHEN v_state_applied AND v_effective_status = 'delivered' THEN v_now END,
      CASE WHEN v_state_applied AND v_effective_status = 'customer_cancelled' THEN v_now END,
      v_now
    )
    RETURNING * INTO v_order;
  END IF;

  INSERT INTO public.deliberry_operational_order_events (
    operational_order_id,
    restaurant_id,
    source_system,
    destination_system,
    event_id,
    trace_id,
    payload_version,
    channel_id,
    event_sequence,
    event_occurred_at,
    event_type,
    external_order_id,
    actor_id,
    reason,
    status,
    state_applied,
    state_error,
    payload,
    processed_at
  )
  VALUES (
    v_order.id,
    p_store_id,
    p_source_system,
    p_destination_system,
    p_event_id,
    v_trace_id,
    v_payload_version,
    v_channel_id,
    v_event_sequence,
    v_event_occurred_at,
    p_event_type,
    p_external_order_id,
    p_actor_id,
    p_reason,
    CASE
      WHEN v_state_error IS NOT NULL THEN 'failed'
      WHEN p_destination_system = 'pos' THEN 'processed'
      ELSE 'pending'
    END,
    v_state_applied,
    v_state_error,
    COALESCE(p_payload, '{}'::JSONB),
    CASE
      WHEN v_state_error IS NULL AND p_destination_system = 'pos' THEN v_now
    END
  );

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.get_deliberry_operational_order_events_for_retry(
  p_store_id UUID,
  p_limit INTEGER DEFAULT 100
) RETURNS SETOF public.deliberry_operational_order_events AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    PERFORM public.assert_deliberry_operational_store_action_scope(
      p_store_id,
      ARRAY['admin', 'store_admin', 'brand_admin', 'super_admin']
    );
  END IF;

  RETURN QUERY
  SELECT *
  FROM public.deliberry_operational_order_events
  WHERE restaurant_id = p_store_id
    AND destination_system = 'deliberry'
    AND status IN ('pending', 'failed')
  ORDER BY created_at ASC, event_id ASC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.mark_deliberry_operational_event_processed(
  p_store_id UUID,
  p_event_id TEXT
) RETURNS public.deliberry_operational_order_events AS $$
DECLARE
  v_event public.deliberry_operational_order_events%ROWTYPE;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'DELIBERRY_EVENT_SERVICE_ROLE_REQUIRED';
  END IF;

  UPDATE public.deliberry_operational_order_events
  SET
    status = 'processed',
    last_error = NULL,
    processed_at = now(),
    updated_at = now()
  WHERE restaurant_id = p_store_id
    AND source_system = 'pos'
    AND destination_system = 'deliberry'
    AND event_id = p_event_id
  RETURNING * INTO v_event;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'DELIBERRY_EVENT_NOT_FOUND';
  END IF;

  RETURN v_event;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.mark_deliberry_operational_event_failed(
  p_store_id UUID,
  p_event_id TEXT,
  p_last_error TEXT,
  p_dead_after_attempts INTEGER DEFAULT 5
) RETURNS public.deliberry_operational_order_events AS $$
DECLARE
  v_event public.deliberry_operational_order_events%ROWTYPE;
  v_dead_after_attempts INTEGER;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'DELIBERRY_EVENT_SERVICE_ROLE_REQUIRED';
  END IF;

  v_dead_after_attempts := GREATEST(COALESCE(p_dead_after_attempts, 5), 1);

  UPDATE public.deliberry_operational_order_events
  SET
    attempt_count = attempt_count + 1,
    last_error = NULLIF(btrim(COALESCE(p_last_error, '')), ''),
    status = CASE
      WHEN attempt_count + 1 >= v_dead_after_attempts THEN 'dead'
      ELSE 'failed'
    END,
    dead_letter_at = CASE
      WHEN attempt_count + 1 >= v_dead_after_attempts THEN now()
      ELSE dead_letter_at
    END,
    updated_at = now()
  WHERE restaurant_id = p_store_id
    AND source_system = 'pos'
    AND destination_system = 'deliberry'
    AND event_id = p_event_id
    AND status IN ('pending', 'failed')
  RETURNING * INTO v_event;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'DELIBERRY_EVENT_NOT_RETRYABLE';
  END IF;

  RETURN v_event;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.reprocess_deliberry_operational_order_event(
  p_store_id UUID,
  p_event_id TEXT
) RETURNS public.deliberry_operational_order_events AS $$
DECLARE
  v_event public.deliberry_operational_order_events%ROWTYPE;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    PERFORM public.assert_deliberry_operational_store_action_scope(
      p_store_id,
      ARRAY['admin', 'store_admin', 'brand_admin', 'super_admin']
    );
  END IF;

  UPDATE public.deliberry_operational_order_events
  SET
    status = 'pending',
    attempt_count = attempt_count + 1,
    last_error = NULL,
    dead_letter_at = NULL,
    updated_at = now()
  WHERE restaurant_id = p_store_id
    AND source_system = 'pos'
    AND destination_system = 'deliberry'
    AND event_id = p_event_id
    AND status IN ('failed', 'dead')
  RETURNING * INTO v_event;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'DELIBERRY_EVENT_NOT_REPROCESSABLE';
  END IF;

  RETURN v_event;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

DROP FUNCTION IF EXISTS public.get_deliberry_operational_reconciliation(UUID);

CREATE OR REPLACE FUNCTION public.get_deliberry_operational_reconciliation(
  p_store_id UUID
) RETURNS TABLE (
  order_status TEXT,
  order_count BIGINT,
  event_count BIGINT,
  failed_event_count BIGINT,
  dead_event_count BIGINT,
  pending_outbound_count BIGINT,
  stale_event_count BIGINT,
  invalid_transition_count BIGINT,
  revenue_row_count BIGINT
) AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    PERFORM public.assert_deliberry_operational_store_action_scope(
      p_store_id,
      ARRAY['admin', 'store_admin', 'brand_admin', 'super_admin']
    );
  END IF;

  RETURN QUERY
  WITH order_counts AS (
    SELECT status, COUNT(*) AS order_count
    FROM public.deliberry_operational_orders
    WHERE restaurant_id = p_store_id
    GROUP BY status
  ),
  event_counts AS (
    SELECT
      COUNT(*) AS event_count,
      COUNT(*) FILTER (WHERE status = 'failed') AS failed_event_count,
      COUNT(*) FILTER (WHERE status = 'dead') AS dead_event_count,
      COUNT(*) FILTER (
        WHERE destination_system = 'deliberry'
          AND status IN ('pending', 'failed')
      ) AS pending_outbound_count,
      COUNT(*) FILTER (
        WHERE state_error = 'DELIBERRY_ORDER_STALE_EVENT_SEQUENCE'
      ) AS stale_event_count,
      COUNT(*) FILTER (
        WHERE state_error = 'DELIBERRY_ORDER_INVALID_STATE_TRANSITION'
      ) AS invalid_transition_count
    FROM public.deliberry_operational_order_events
    WHERE restaurant_id = p_store_id
  )
  SELECT
    oc.status AS order_status,
    oc.order_count,
    ec.event_count,
    ec.failed_event_count,
    ec.dead_event_count,
    ec.pending_outbound_count,
    ec.stale_event_count,
    ec.invalid_transition_count,
    0::BIGINT AS revenue_row_count
  FROM order_counts oc
  CROSS JOIN event_counts ec
  ORDER BY oc.status ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.receive_deliberry_operational_order(
  p_store_id UUID,
  p_external_order_id TEXT,
  p_event_id TEXT,
  p_payload JSONB DEFAULT '{}'::JSONB
) RETURNS public.deliberry_operational_orders AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    PERFORM public.assert_deliberry_operational_store_action_scope(
      p_store_id,
      ARRAY['admin', 'store_admin', 'brand_admin', 'super_admin']
    );
  END IF;

  RETURN public.apply_deliberry_operational_order_event(
    p_store_id,
    p_external_order_id,
    p_event_id,
    'DELIBERRY_ORDER_RECEIVED',
    p_payload,
    NULL,
    NULL,
    'deliberry',
    'pos'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.get_deliberry_operational_order_inbox(
  p_store_id UUID
) RETURNS SETOF public.deliberry_operational_orders AS $$
BEGIN
  PERFORM public.assert_deliberry_operational_store_action_scope(
    p_store_id,
    ARRAY['admin', 'store_admin', 'brand_admin', 'super_admin', 'kitchen']
  );

  RETURN QUERY
  SELECT *
  FROM public.deliberry_operational_orders
  WHERE restaurant_id = p_store_id
  ORDER BY updated_at DESC, external_order_id ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.accept_deliberry_operational_order(
  p_store_id UUID,
  p_external_order_id TEXT,
  p_event_id TEXT
) RETURNS public.deliberry_operational_orders AS $$
BEGIN
  PERFORM public.assert_deliberry_operational_store_action_scope(
    p_store_id,
    ARRAY['admin', 'store_admin', 'brand_admin', 'super_admin']
  );

  RETURN public.apply_deliberry_operational_order_event(
    p_store_id,
    p_external_order_id,
    p_event_id,
    'DELIBERRY_ORDER_ACCEPTED',
    '{}'::JSONB,
    auth.uid(),
    NULL,
    'pos',
    'deliberry'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.reject_deliberry_operational_order(
  p_store_id UUID,
  p_external_order_id TEXT,
  p_event_id TEXT,
  p_reason TEXT
) RETURNS public.deliberry_operational_orders AS $$
DECLARE
  v_reason TEXT;
BEGIN
  v_reason := NULLIF(btrim(COALESCE(p_reason, '')), '');
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'DELIBERRY_ORDER_REJECT_REASON_REQUIRED';
  END IF;

  PERFORM public.assert_deliberry_operational_store_action_scope(
    p_store_id,
    ARRAY['admin', 'store_admin', 'brand_admin', 'super_admin']
  );

  RETURN public.apply_deliberry_operational_order_event(
    p_store_id,
    p_external_order_id,
    p_event_id,
    'DELIBERRY_ORDER_REJECTED',
    jsonb_build_object('reject_reason', v_reason),
    auth.uid(),
    v_reason,
    'pos',
    'deliberry'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.mark_deliberry_operational_order_ready(
  p_store_id UUID,
  p_external_order_id TEXT,
  p_event_id TEXT
) RETURNS public.deliberry_operational_orders AS $$
BEGIN
  PERFORM public.assert_deliberry_operational_store_action_scope(
    p_store_id,
    ARRAY['admin', 'store_admin', 'brand_admin', 'super_admin', 'kitchen']
  );

  RETURN public.apply_deliberry_operational_order_event(
    p_store_id,
    p_external_order_id,
    p_event_id,
    'DELIBERRY_ORDER_READY',
    '{}'::JSONB,
    auth.uid(),
    NULL,
    'pos',
    'deliberry'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

GRANT SELECT ON public.deliberry_operational_orders TO authenticated;
GRANT SELECT ON public.deliberry_operational_order_events TO authenticated;
GRANT ALL ON public.deliberry_operational_orders TO service_role;
GRANT ALL ON public.deliberry_operational_order_events TO service_role;

REVOKE EXECUTE ON FUNCTION public.assert_deliberry_operational_store_action_scope(UUID, TEXT[])
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.deliberry_operational_transition_allowed(TEXT, TEXT)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.deliberry_operational_next_status(TEXT, TEXT)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.apply_deliberry_operational_order_event(
  UUID,
  TEXT,
  TEXT,
  TEXT,
  JSONB,
  UUID,
  TEXT,
  TEXT,
  TEXT
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.receive_deliberry_operational_order(UUID, TEXT, TEXT, JSONB)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_deliberry_operational_order_inbox(UUID)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.accept_deliberry_operational_order(UUID, TEXT, TEXT)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.reject_deliberry_operational_order(UUID, TEXT, TEXT, TEXT)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.mark_deliberry_operational_order_ready(UUID, TEXT, TEXT)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_deliberry_operational_order_events_for_retry(UUID, INTEGER)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.mark_deliberry_operational_event_processed(UUID, TEXT)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.mark_deliberry_operational_event_failed(UUID, TEXT, TEXT, INTEGER)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.reprocess_deliberry_operational_order_event(UUID, TEXT)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_deliberry_operational_reconciliation(UUID)
  FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.apply_deliberry_operational_order_event(
  UUID,
  TEXT,
  TEXT,
  TEXT,
  JSONB,
  UUID,
  TEXT,
  TEXT,
  TEXT
) TO service_role;
GRANT EXECUTE ON FUNCTION public.receive_deliberry_operational_order(UUID, TEXT, TEXT, JSONB)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_deliberry_operational_order_inbox(UUID)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_deliberry_operational_order(UUID, TEXT, TEXT)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.reject_deliberry_operational_order(UUID, TEXT, TEXT, TEXT)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_deliberry_operational_order_ready(UUID, TEXT, TEXT)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_deliberry_operational_order_events_for_retry(UUID, INTEGER)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_deliberry_operational_event_processed(UUID, TEXT)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.mark_deliberry_operational_event_failed(UUID, TEXT, TEXT, INTEGER)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.reprocess_deliberry_operational_order_event(UUID, TEXT)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_deliberry_operational_reconciliation(UUID)
  TO authenticated, service_role;
