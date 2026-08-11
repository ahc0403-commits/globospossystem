BEGIN;

-- production-gate: self-verifying
-- Expand-only foundation for store print/paperless routing and customer
-- digital receipts. Payment remains authoritative and never depends on these
-- post-payment presentation records.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

ALTER TABLE public.restaurant_settings
  ADD COLUMN IF NOT EXISTS fulfillment_mode text NOT NULL DEFAULT 'pos_print';

ALTER TABLE public.restaurant_settings
  DROP CONSTRAINT IF EXISTS restaurant_settings_fulfillment_mode_check;
ALTER TABLE public.restaurant_settings
  ADD CONSTRAINT restaurant_settings_fulfillment_mode_check
  CHECK (fulfillment_mode IN ('pos_print', 'paperless'));

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS fulfillment_mode_snapshot text NOT NULL
  DEFAULT 'pos_print';
ALTER TABLE public.orders
  DROP CONSTRAINT IF EXISTS orders_fulfillment_mode_snapshot_check;
ALTER TABLE public.orders
  ADD CONSTRAINT orders_fulfillment_mode_snapshot_check
  CHECK (fulfillment_mode_snapshot IN ('pos_print', 'paperless'));

ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS fulfillment_mode_snapshot text NOT NULL
  DEFAULT 'pos_print';
ALTER TABLE public.order_items
  DROP CONSTRAINT IF EXISTS order_items_fulfillment_mode_snapshot_check;
ALTER TABLE public.order_items
  ADD CONSTRAINT order_items_fulfillment_mode_snapshot_check
  CHECK (fulfillment_mode_snapshot IN ('pos_print', 'paperless'));

ALTER TABLE public.print_jobs
  ADD COLUMN IF NOT EXISTS fulfillment_mode_snapshot text NOT NULL
  DEFAULT 'pos_print';
ALTER TABLE public.print_jobs
  DROP CONSTRAINT IF EXISTS print_jobs_fulfillment_mode_snapshot_check;
ALTER TABLE public.print_jobs
  ADD CONSTRAINT print_jobs_fulfillment_mode_snapshot_check
  CHECK (fulfillment_mode_snapshot IN ('pos_print', 'paperless'));

COMMENT ON COLUMN public.restaurant_settings.fulfillment_mode IS
  'pos_print prints operational tickets; paperless routes operational items to KDS. Customer receipts remain independently available.';
COMMENT ON COLUMN public.orders.fulfillment_mode_snapshot IS
  'Store fulfillment mode captured atomically when the order was created.';
COMMENT ON COLUMN public.order_items.fulfillment_mode_snapshot IS
  'Store fulfillment mode captured when this item/additional-order line was created.';

CREATE TABLE public.fulfillment_mode_changes (
  request_id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  previous_mode text NOT NULL CHECK (previous_mode IN ('pos_print', 'paperless')),
  next_mode text NOT NULL CHECK (next_mode IN ('pos_print', 'paperless')),
  reason text NOT NULL CHECK (btrim(reason) <> ''),
  actor_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX fulfillment_mode_changes_store_created
  ON public.fulfillment_mode_changes (restaurant_id, created_at DESC);

ALTER TABLE public.fulfillment_mode_changes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.fulfillment_mode_changes FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.fulfillment_mode_changes TO authenticated;
GRANT ALL ON public.fulfillment_mode_changes TO service_role;

CREATE POLICY fulfillment_mode_changes_store_read
ON public.fulfillment_mode_changes
FOR SELECT TO authenticated
USING (
  public.is_super_admin()
  OR EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(auth.uid()) scope(store_id)
    WHERE scope.store_id = restaurant_id
  )
);

CREATE OR REPLACE FUNCTION public.get_store_fulfillment_mode(
  p_store_id uuid
) RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
  SELECT COALESCE((
    SELECT settings.fulfillment_mode
    FROM public.restaurant_settings settings
    WHERE settings.restaurant_id = p_store_id
  ), 'pos_print');
$$;

CREATE OR REPLACE FUNCTION public.capture_order_fulfillment_mode()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(
    hashtextextended('fulfillment-mode:' || NEW.restaurant_id::text, 0)
  );
  NEW.fulfillment_mode_snapshot :=
    public.get_store_fulfillment_mode(NEW.restaurant_id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS capture_order_fulfillment_mode_trigger
  ON public.orders;
CREATE TRIGGER capture_order_fulfillment_mode_trigger
BEFORE INSERT ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.capture_order_fulfillment_mode();

CREATE OR REPLACE FUNCTION public.capture_order_item_fulfillment_mode()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(
    hashtextextended('fulfillment-mode:' || NEW.restaurant_id::text, 0)
  );
  NEW.fulfillment_mode_snapshot :=
    public.get_store_fulfillment_mode(NEW.restaurant_id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS capture_order_item_fulfillment_mode_trigger
  ON public.order_items;
CREATE TRIGGER capture_order_item_fulfillment_mode_trigger
BEFORE INSERT ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.capture_order_item_fulfillment_mode();

-- The legacy emergency ledger remains the backing KDS ledger during the
-- compatibility window. Only paperless item snapshots may enter it.
CREATE OR REPLACE FUNCTION public.emergency_sync_order_item()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_session public.emergency_fulfillment_sessions%ROWTYPE;
  v_queue public.emergency_order_queue%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_table record;
  v_existing public.emergency_fulfillment_items%ROWTYPE;
  v_queue_created boolean := false;
  v_event_id uuid;
BEGIN
  IF NEW.fulfillment_mode_snapshot <> 'paperless' THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_session
  FROM public.emergency_fulfillment_sessions
  WHERE restaurant_id = NEW.restaurant_id AND status = 'active'
  FOR UPDATE;
  IF NOT FOUND THEN RETURN NEW; END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = NEW.order_id;
  IF NOT FOUND OR v_order.status IN ('completed', 'cancelled') THEN
    RETURN NEW;
  END IF;

  IF COALESCE(NEW.is_service_item, false)
     OR NEW.item_type IN ('wet_tissue_charge', 'buffet_cover_charge') THEN
    RETURN NEW;
  END IF;

  SELECT table_number, floor_label INTO v_table
  FROM public.tables WHERE id = v_order.table_id;

  SELECT * INTO v_queue
  FROM public.emergency_order_queue
  WHERE session_id = v_session.id AND order_id = NEW.order_id;

  IF NOT FOUND THEN
    INSERT INTO public.emergency_order_queue (
      session_id, restaurant_id, order_id, queue_no, table_number, floor_label
    ) VALUES (
      v_session.id,
      NEW.restaurant_id,
      NEW.order_id,
      COALESCE((SELECT max(queue_no) + 1
        FROM public.emergency_order_queue WHERE session_id = v_session.id), 1),
      COALESCE(v_table.table_number, 'STAFF'),
      public.emergency_floor_label(
        NEW.restaurant_id, v_table.floor_label, v_table.table_number
      )
    ) RETURNING * INTO v_queue;
    v_queue_created := true;
  END IF;

  SELECT * INTO v_existing
  FROM public.emergency_fulfillment_items
  WHERE session_id = v_session.id AND order_item_id = NEW.id
  FOR UPDATE;

  IF FOUND THEN
    UPDATE public.emergency_fulfillment_items
    SET source_quantity = NEW.quantity,
        ordered_quantity = greatest(
          NEW.quantity,
          kitchen_done_quantity,
          tray_received_quantity,
          tray_dispatched_quantity,
          floor_served_quantity
        ),
        is_cancelled = NEW.status = 'cancelled',
        needs_review = NEW.quantity < greatest(
          kitchen_done_quantity,
          tray_received_quantity,
          tray_dispatched_quantity,
          floor_served_quantity
        ),
        updated_at = now()
    WHERE id = v_existing.id;
  ELSE
    INSERT INTO public.emergency_fulfillment_items (
      session_id, restaurant_id, queue_id, order_id, order_item_id,
      source_quantity, ordered_quantity, is_cancelled
    ) VALUES (
      v_session.id, NEW.restaurant_id, v_queue.id, NEW.order_id, NEW.id,
      NEW.quantity, NEW.quantity, NEW.status = 'cancelled'
    );
  END IF;

  IF v_queue_created THEN
    v_event_id := gen_random_uuid();
    INSERT INTO public.emergency_fulfillment_events (
      event_id, session_id, restaurant_id, order_id, stage, delta, details
    ) VALUES (
      v_event_id, v_session.id, NEW.restaurant_id, NEW.order_id,
      'order_received', 1, jsonb_build_object(
        'queue_no', v_queue.queue_no,
        'fulfillment_mode', 'paperless'
      )
    );
    PERFORM public.emergency_enqueue_push(
      v_event_id, NEW.restaurant_id, NEW.order_id,
      'kitchen', v_queue.floor_label, 'order_received'
    );
  END IF;
  RETURN NEW;
END;
$$;

-- Route each operational print job by its captured item/order mode, never by
-- the store's current mode at claim time. Receipt jobs are always printable.
CREATE OR REPLACE FUNCTION public.emergency_hold_print_job()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_session_id uuid;
  v_order_mode text := 'pos_print';
  v_payload_mode text;
  v_payload_item_count integer := 0;
BEGIN
  SELECT order_row.fulfillment_mode_snapshot
  INTO v_order_mode
  FROM public.orders order_row
  WHERE order_row.id = NEW.order_id;

  SELECT
    CASE
      WHEN count(*) > 0
       AND bool_and(item.fulfillment_mode_snapshot = 'paperless')
        THEN 'paperless'
      WHEN count(*) > 0 THEN 'pos_print'
      ELSE NULL
    END,
    count(*)::integer
  INTO v_payload_mode, v_payload_item_count
  FROM jsonb_array_elements(COALESCE(NEW.payload->'items', '[]'::jsonb)) raw
  JOIN public.order_items item
    ON item.id::text = raw->>'item_id';

  NEW.fulfillment_mode_snapshot := COALESCE(
    v_payload_mode,
    v_order_mode,
    'pos_print'
  );

  IF NEW.copy_type = 'receipt'
     OR NEW.fulfillment_mode_snapshot <> 'paperless' THEN
    RETURN NEW;
  END IF;

  SELECT id INTO v_session_id
  FROM public.emergency_fulfillment_sessions
  WHERE restaurant_id = NEW.restaurant_id AND status = 'active';

  NEW.emergency_session_id := v_session_id;
  NEW.emergency_held_at := now();
  NEW.emergency_resolution := 'digital_completed';
  NEW.status := 'cancelled';
  NEW.last_error := 'PAPERLESS_DIGITAL_ROUTING';
  RETURN NEW;
END;
$$;

-- Preserve the established trigger name so applied clients and contract tests
-- continue to observe one operational routing hook.
DROP TRIGGER IF EXISTS emergency_hold_print_job_trigger ON public.print_jobs;
CREATE TRIGGER emergency_hold_print_job_trigger
BEFORE INSERT ON public.print_jobs
FOR EACH ROW EXECUTE FUNCTION public.emergency_hold_print_job();

CREATE OR REPLACE FUNCTION public.claim_print_jobs(
  p_store_id uuid,
  p_limit int DEFAULT 10
) RETURNS SETOF public.print_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50);
BEGIN
  IF NOT public.print_routing_actor_can_run(p_store_id) THEN
    RAISE EXCEPTION 'PRINT_CLAIM_FORBIDDEN';
  END IF;
  RETURN QUERY
  WITH candidates AS (
    SELECT id FROM public.print_jobs
    WHERE restaurant_id = p_store_id
      AND status IN ('pending', 'failed')
      AND destination_id IS NOT NULL
      AND next_retry_at <= now() AND attempts < 10
      AND emergency_held_at IS NULL
    ORDER BY created_at, id
    LIMIT v_limit FOR UPDATE SKIP LOCKED
  )
  UPDATE public.print_jobs job
  SET status = 'printing', claimed_by = auth.uid(),
      attempts = attempts + 1, updated_at = now()
  FROM candidates WHERE job.id = candidates.id
  RETURNING job.*;
END;
$$;

CREATE OR REPLACE FUNCTION public.super_admin_set_fulfillment_mode(
  p_store_id uuid,
  p_mode text,
  p_reason text,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_previous text;
  v_existing public.fulfillment_mode_changes%ROWTYPE;
  v_session public.emergency_fulfillment_sessions%ROWTYPE;
  v_unresolved integer := 0;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'FULFILLMENT_MODE_SUPER_ADMIN_REQUIRED';
  END IF;
  IF p_store_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.restaurants
    WHERE id = p_store_id AND is_active = true
  ) THEN
    RAISE EXCEPTION 'FULFILLMENT_MODE_STORE_UNAVAILABLE';
  END IF;
  IF p_mode NOT IN ('pos_print', 'paperless') THEN
    RAISE EXCEPTION 'FULFILLMENT_MODE_INVALID';
  END IF;
  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'FULFILLMENT_MODE_REQUEST_ID_REQUIRED';
  END IF;
  IF NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'FULFILLMENT_MODE_REASON_REQUIRED';
  END IF;

  SELECT * INTO v_existing
  FROM public.fulfillment_mode_changes
  WHERE request_id = p_request_id;
  IF FOUND THEN
    IF v_existing.restaurant_id <> p_store_id
       OR v_existing.next_mode <> p_mode THEN
      RAISE EXCEPTION 'FULFILLMENT_MODE_REQUEST_CONFLICT';
    END IF;
    RETURN jsonb_build_object(
      'mode', v_existing.next_mode,
      'previous_mode', v_existing.previous_mode,
      'deduplicated', true
    );
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('fulfillment-mode:' || p_store_id::text, 0)
  );
  v_previous := public.get_store_fulfillment_mode(p_store_id);

  INSERT INTO public.restaurant_settings (
    restaurant_id, fulfillment_mode, updated_at
  ) VALUES (
    p_store_id, p_mode, now()
  ) ON CONFLICT (restaurant_id) DO UPDATE SET
    fulfillment_mode = EXCLUDED.fulfillment_mode,
    updated_at = now();

  SELECT * INTO v_session
  FROM public.emergency_fulfillment_sessions
  WHERE restaurant_id = p_store_id AND status = 'active'
  FOR UPDATE;

  IF p_mode = 'paperless' AND NOT FOUND THEN
    INSERT INTO public.emergency_fulfillment_sessions (
      restaurant_id, reason, activated_by
    ) VALUES (
      p_store_id, 'paperless: ' || btrim(p_reason), v_actor.id
    ) RETURNING * INTO v_session;
  ELSIF p_mode = 'pos_print' AND FOUND THEN
    SELECT COALESCE(sum(
      item.ordered_quantity - item.floor_served_quantity
    ), 0)::integer
    INTO v_unresolved
    FROM public.emergency_fulfillment_items item
    WHERE item.session_id = v_session.id AND item.is_cancelled = false;

    IF v_unresolved = 0 THEN
      UPDATE public.emergency_fulfillment_sessions
      SET status = 'closed',
          closed_by = v_actor.id,
          closed_at = now(),
          close_reason = 'paperless mode drained',
          close_resolution = 'digital_completed',
          force_closed = false,
          updated_at = now()
      WHERE id = v_session.id;
    END IF;
  END IF;

  INSERT INTO public.fulfillment_mode_changes (
    request_id, restaurant_id, previous_mode, next_mode,
    reason, actor_user_id
  ) VALUES (
    p_request_id, p_store_id, v_previous, p_mode,
    btrim(p_reason), v_actor.id
  );

  INSERT INTO public.audit_logs (
    actor_id, action, entity_type, entity_id, details
  ) VALUES (
    auth.uid(), 'set_fulfillment_mode', 'restaurants', p_store_id,
    jsonb_build_object(
      'previous_mode', v_previous,
      'next_mode', p_mode,
      'reason', btrim(p_reason),
      'request_id', p_request_id,
      'unresolved_quantity', v_unresolved
    )
  );

  RETURN jsonb_build_object(
    'mode', p_mode,
    'previous_mode', v_previous,
    'deduplicated', false,
    'draining', p_mode = 'pos_print' AND v_unresolved > 0,
    'unresolved_quantity', v_unresolved,
    'session_id', v_session.id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.super_admin_get_fulfillment_store_statuses()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'FULFILLMENT_MODE_SUPER_ADMIN_REQUIRED';
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'restaurant_id', restaurant.id,
      'restaurant_name', restaurant.name,
      'mode', COALESCE(settings.fulfillment_mode, 'pos_print'),
      'session_id', session.id,
      'unresolved_quantity', COALESCE(summary.unresolved_quantity, 0),
      'order_count', COALESCE(summary.order_count, 0),
      'draining', COALESCE(settings.fulfillment_mode, 'pos_print') = 'pos_print'
        AND COALESCE(summary.unresolved_quantity, 0) > 0,
      'kds_ready', COALESCE(stations.kitchen_count, 0) > 0
        AND COALESCE(stations.tray_count, 0) > 0
        AND COALESCE(stations.floor_count, 0) > 0,
      'reason', change.reason,
      'changed_at', change.created_at
    ) ORDER BY restaurant.name)
    FROM public.restaurants restaurant
    LEFT JOIN public.restaurant_settings settings
      ON settings.restaurant_id = restaurant.id
    LEFT JOIN public.emergency_fulfillment_sessions session
      ON session.restaurant_id = restaurant.id AND session.status = 'active'
    LEFT JOIN LATERAL (
      SELECT
        COALESCE(sum(item.ordered_quantity - item.floor_served_quantity), 0)::integer
          AS unresolved_quantity,
        count(DISTINCT item.order_id)::integer AS order_count
      FROM public.emergency_fulfillment_items item
      WHERE item.session_id = session.id AND item.is_cancelled = false
    ) summary ON true
    LEFT JOIN LATERAL (
      SELECT
        count(*) FILTER (WHERE assignment.station_type = 'kitchen')::integer
          AS kitchen_count,
        count(*) FILTER (WHERE assignment.station_type = 'tray')::integer
          AS tray_count,
        count(*) FILTER (WHERE assignment.station_type = 'floor')::integer
          AS floor_count
      FROM public.emergency_station_assignments assignment
      WHERE assignment.restaurant_id = restaurant.id
        AND assignment.is_active = true
    ) stations ON true
    LEFT JOIN LATERAL (
      SELECT mode_change.reason, mode_change.created_at
      FROM public.fulfillment_mode_changes mode_change
      WHERE mode_change.restaurant_id = restaurant.id
      ORDER BY mode_change.created_at DESC
      LIMIT 1
    ) change ON true
    WHERE restaurant.is_active = true
  ), '[]'::jsonb);
END;
$$;

-- Old app versions may still call the emergency RPC. Keep its signature but
-- route it through the same mode lock so an old client cannot close the KDS
-- ledger while the store setting remains paperless.
CREATE OR REPLACE FUNCTION public.super_admin_set_emergency_mode(
  p_store_id uuid,
  p_enabled boolean,
  p_reason text,
  p_resolution text DEFAULT 'digital_completed',
  p_force boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.super_admin_set_fulfillment_mode(
    p_store_id,
    CASE WHEN p_enabled THEN 'paperless' ELSE 'pos_print' END,
    p_reason,
    gen_random_uuid()
  );
  RETURN v_result || jsonb_build_object(
    'active', p_enabled,
    'compatibility_alias', true,
    'requested_resolution', p_resolution,
    'requested_force', p_force
  );
END;
$$;

-- Once a store has switched back to POS print, its legacy KDS session remains
-- available only while paperless orders are draining. Close it automatically
-- after the last item reaches the floor.
CREATE OR REPLACE FUNCTION public.close_drained_paperless_session()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_session public.emergency_fulfillment_sessions%ROWTYPE;
BEGIN
  IF public.get_store_fulfillment_mode(NEW.restaurant_id) <> 'pos_print' THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_session
  FROM public.emergency_fulfillment_sessions
  WHERE id = NEW.session_id AND status = 'active'
  FOR UPDATE;
  IF NOT FOUND OR EXISTS (
    SELECT 1
    FROM public.emergency_fulfillment_items item
    WHERE item.session_id = v_session.id
      AND item.is_cancelled = false
      AND item.floor_served_quantity < item.ordered_quantity
  ) THEN
    RETURN NEW;
  END IF;

  UPDATE public.emergency_fulfillment_sessions
  SET status = 'closed',
      closed_by = COALESCE((
        SELECT user_row.id FROM public.users user_row
        WHERE user_row.auth_id = auth.uid() LIMIT 1
      ), v_session.activated_by),
      closed_at = now(),
      close_reason = 'paperless mode drained',
      close_resolution = 'digital_completed',
      force_closed = false,
      updated_at = now()
  WHERE id = v_session.id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS close_drained_paperless_session_trigger
  ON public.emergency_fulfillment_items;
CREATE TRIGGER close_drained_paperless_session_trigger
AFTER UPDATE OF floor_served_quantity, is_cancelled
ON public.emergency_fulfillment_items
FOR EACH ROW EXECUTE FUNCTION public.close_drained_paperless_session();

REVOKE ALL ON FUNCTION public.get_store_fulfillment_mode(uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.super_admin_set_fulfillment_mode(
  uuid, text, text, uuid
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.super_admin_get_fulfillment_store_statuses()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_store_fulfillment_mode(uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.super_admin_set_fulfillment_mode(
  uuid, text, text, uuid
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.super_admin_get_fulfillment_store_statuses()
  TO authenticated;

CREATE TABLE public.digital_receipts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  combined_payment_group_id uuid
    REFERENCES public.combined_payment_groups(id) ON DELETE SET NULL,
  receipt_number text NOT NULL,
  snapshot jsonb NOT NULL CHECK (jsonb_typeof(snapshot) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  revoked_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  revocation_reason text,
  UNIQUE (order_id),
  CONSTRAINT digital_receipt_revocation_contract CHECK (
    (revoked_at IS NULL AND revoked_by IS NULL AND revocation_reason IS NULL)
    OR (revoked_at IS NOT NULL AND revocation_reason IS NOT NULL)
  )
);

CREATE TABLE public.digital_receipt_links (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  digital_receipt_id uuid NOT NULL
    REFERENCES public.digital_receipts(id) ON DELETE CASCADE,
  token_hash bytea NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '90 days'),
  last_presented_at timestamptz,
  revoked_at timestamptz,
  CONSTRAINT digital_receipt_link_lifetime CHECK (expires_at > created_at)
);

-- Only HMAC-SHA256 digests of client network identifiers reach Postgres.
-- Raw IP addresses and public receipt tokens are never retained here.
CREATE TABLE public.digital_receipt_access_limits (
  request_key bytea PRIMARY KEY,
  window_started_at timestamptz NOT NULL,
  request_count integer NOT NULL CHECK (request_count > 0),
  blocked_until timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT digital_receipt_access_key_length
    CHECK (octet_length(request_key) = 32)
);

CREATE INDEX digital_receipts_store_created
  ON public.digital_receipts (restaurant_id, created_at DESC);
CREATE INDEX digital_receipts_number
  ON public.digital_receipts (receipt_number);
CREATE INDEX digital_receipt_links_receipt_created
  ON public.digital_receipt_links (digital_receipt_id, created_at DESC);
CREATE INDEX digital_receipt_links_active_receipt_created
  ON public.digital_receipt_links (digital_receipt_id, created_at DESC)
  WHERE revoked_at IS NULL;
CREATE INDEX digital_receipt_links_expiry
  ON public.digital_receipt_links (expires_at);
CREATE INDEX digital_receipt_access_limits_updated
  ON public.digital_receipt_access_limits (updated_at);

ALTER TABLE public.digital_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.digital_receipt_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.digital_receipt_access_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.digital_receipts, public.digital_receipt_links,
  public.digital_receipt_access_limits
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.digital_receipts TO authenticated;
GRANT ALL ON public.digital_receipts, public.digital_receipt_links,
  public.digital_receipt_access_limits
  TO service_role;

CREATE POLICY digital_receipts_store_read
ON public.digital_receipts
FOR SELECT TO authenticated
USING (
  public.is_super_admin()
  OR EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(auth.uid()) scope(store_id)
    WHERE scope.store_id = restaurant_id
  )
);

CREATE OR REPLACE FUNCTION public.ensure_digital_receipt(
  p_order_id uuid,
  p_received_amount numeric DEFAULT NULL,
  p_change_amount numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_order record;
  v_receipt public.digital_receipts%ROWTYPE;
  v_items jsonb := '[]'::jsonb;
  v_payments jsonb := '[]'::jsonb;
  v_payment_count integer := 0;
  v_total numeric(15,2) := 0;
  v_subtotal numeric(15,2) := 0;
  v_discount numeric(15,2) := 0;
  v_vat numeric(15,2) := 0;
  v_service_charge numeric(15,2) := 0;
  v_paid_at timestamptz;
  v_method text := 'OTHER';
  v_is_service boolean := false;
  v_received numeric(15,2);
  v_change numeric(15,2);
  v_group_id uuid;
  v_receipt_number text;
  v_cashier text := 'CASHIER';
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_FORBIDDEN';
  END IF;

  SELECT
    order_row.id,
    order_row.restaurant_id,
    order_row.status,
    order_row.order_purpose,
    COALESCE(table_row.table_number, 'STAFF') AS table_number,
    restaurant.name AS restaurant_name,
    restaurant.address,
    CASE WHEN lower(COALESCE(brand.name, restaurant.name)) LIKE '%bunsik%'
      THEN 'BUNSIK CLUB' ELSE COALESCE(brand.name, restaurant.name) END
      AS brand_name,
    CASE WHEN lower(COALESCE(brand.name, restaurant.name)) LIKE '%bunsik%'
      THEN 'CÔNG TY TNHH AKJ INTERNATIONAL' ELSE tax_entity.name END
      AS legal_name,
    CASE WHEN lower(COALESCE(brand.name, restaurant.name)) LIKE '%bunsik%'
      THEN '0318453298' ELSE NULLIF(tax_entity.tax_code, 'PLACEHOLDER_DEV_000') END
      AS tax_code
  INTO v_order
  FROM public.orders order_row
  JOIN public.restaurants restaurant
    ON restaurant.id = order_row.restaurant_id
  LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
  LEFT JOIN public.brands brand ON brand.id = restaurant.brand_id
  LEFT JOIN public.tax_entity tax_entity
    ON tax_entity.id = restaurant.tax_entity_id
  WHERE order_row.id = p_order_id
  FOR UPDATE OF order_row;

  IF NOT FOUND OR v_order.status <> 'completed' THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_PAYMENT_REQUIRED';
  END IF;
  IF NOT public.is_super_admin() AND NOT EXISTS (
    SELECT 1 FROM public.user_accessible_stores(auth.uid()) scope(store_id)
    WHERE scope.store_id = v_order.restaurant_id
  ) THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_FORBIDDEN';
  END IF;

  SELECT * INTO v_receipt
  FROM public.digital_receipts
  WHERE order_id = p_order_id;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'receipt_id', v_receipt.id,
      'receipt_number', v_receipt.receipt_number,
      'created', false,
      'snapshot', v_receipt.snapshot
    );
  END IF;

  SELECT
    count(*)::integer,
    ROUND(COALESCE(sum(COALESCE(payment.amount_portion, payment.amount)), 0), 2),
    max(payment.created_at),
    bool_and(NOT COALESCE(payment.is_revenue, true))
  INTO v_payment_count, v_total, v_paid_at, v_is_service
  FROM public.payments payment
  WHERE payment.order_id = p_order_id
    AND payment.restaurant_id = v_order.restaurant_id;

  IF v_payment_count = 0 THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_PAYMENT_REQUIRED';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'method', upper(COALESCE(payment.method, 'OTHER')),
    'amount', ROUND(COALESCE(payment.amount_portion, payment.amount), 2),
    'is_revenue', COALESCE(payment.is_revenue, true)
  ) ORDER BY payment.created_at, payment.id), '[]'::jsonb)
  INTO v_payments
  FROM public.payments payment
  WHERE payment.order_id = p_order_id
    AND payment.restaurant_id = v_order.restaurant_id;

  IF v_is_service THEN
    v_method := 'SERVICE';
  ELSIF v_payment_count > 1 THEN
    v_method := 'SPLIT';
  ELSE
    SELECT upper(COALESCE(payment.method, 'OTHER'))
    INTO v_method
    FROM public.payments payment
    WHERE payment.order_id = p_order_id
      AND payment.restaurant_id = v_order.restaurant_id
    ORDER BY payment.created_at DESC, payment.id DESC
    LIMIT 1;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'label', COALESCE(
      NULLIF(item.label, ''), NULLIF(item.display_name, ''), 'Item'
    ),
    'quantity', item.quantity,
    'unit_price', item.unit_price,
    'line_total', ROUND(item.unit_price * item.quantity, 2),
    'paying_amount_inc_tax', item.paying_amount_inc_tax,
    'vat_amount', COALESCE(item.vat_amount, 0),
    'item_type', item.item_type,
    'is_service_item', COALESCE(item.is_service_item, false)
  ) ORDER BY item.created_at, item.id), '[]'::jsonb),
  ROUND(COALESCE(sum(item.unit_price * item.quantity)
    FILTER (WHERE NOT COALESCE(item.is_service_item, false)), 0), 2),
  ROUND(COALESCE(sum(item.vat_amount)
    FILTER (WHERE NOT COALESCE(item.is_service_item, false)), 0), 2),
  ROUND(COALESCE(sum(COALESCE(
    item.paying_amount_inc_tax, item.unit_price * item.quantity
  )) FILTER (WHERE item.item_type = 'service_charge'), 0), 2)
  INTO v_items, v_subtotal, v_vat, v_service_charge
  FROM public.order_items item
  WHERE item.order_id = p_order_id AND item.status <> 'cancelled';

  SELECT ROUND(COALESCE(sum(discount.discount_amount), 0), 2)
  INTO v_discount
  FROM public.order_discounts discount
  WHERE discount.order_id = p_order_id
    AND discount.status IN ('active', 'consumed');

  SELECT payment.combined_payment_group_id
  INTO v_group_id
  FROM public.payments payment
  WHERE payment.order_id = p_order_id
    AND payment.combined_payment_group_id IS NOT NULL
  ORDER BY payment.created_at DESC
  LIMIT 1;

  SELECT COALESCE(NULLIF(user_row.fixed_account_code, ''),
    NULLIF(user_row.full_name, ''), 'CASHIER')
  INTO v_cashier
  FROM public.payments payment
  LEFT JOIN public.users user_row ON user_row.auth_id = payment.processed_by
  WHERE payment.order_id = p_order_id
  ORDER BY payment.created_at DESC, payment.id DESC
  LIMIT 1;

  SELECT
    COALESCE(NULLIF(job.payload->>'received_amount', '')::numeric, v_total),
    COALESCE(NULLIF(job.payload->>'change_amount', '')::numeric, 0)
  INTO v_received, v_change
  FROM public.print_jobs job
  WHERE job.order_id = p_order_id AND job.copy_type = 'receipt'
    AND job.batch_no = 1
  ORDER BY job.created_at DESC
  LIMIT 1;

  v_received := ROUND(COALESCE(p_received_amount, v_received, v_total), 2);
  v_change := ROUND(COALESCE(
    p_change_amount,
    v_change,
    GREATEST(v_received - v_total, 0)
  ), 2);
  v_receipt_number := 'BC-' ||
    to_char(v_paid_at AT TIME ZONE 'Asia/Ho_Chi_Minh', 'YYYYMMDD') ||
    '-' || lpad((('x' || substr(md5(p_order_id::text), 1, 8))::bit(32)::bigint
      % 1000000)::text, 6, '0');

  INSERT INTO public.digital_receipts (
    restaurant_id, order_id, combined_payment_group_id,
    receipt_number, snapshot
  ) VALUES (
    v_order.restaurant_id,
    p_order_id,
    v_group_id,
    v_receipt_number,
    jsonb_build_object(
      'receipt_number', v_receipt_number,
      'order_id', p_order_id,
      'restaurant_name', v_order.brand_name,
      'legal_name', v_order.legal_name,
      'tax_code', v_order.tax_code,
      'address_lines', CASE
        WHEN lower(COALESCE(v_order.brand_name, '')) LIKE '%bunsik%'
          THEN jsonb_build_array(
            '69/1A2 Nguyễn Gia Trí',
            'Phường Thạnh Mỹ Tây',
            'Thành phố Hồ Chí Minh'
          )
        WHEN NULLIF(v_order.address, '') IS NOT NULL
          THEN jsonb_build_array(v_order.address)
        ELSE '[]'::jsonb
      END,
      'table_number', v_order.table_number,
      'cashier_code', COALESCE(v_cashier, 'CASHIER'),
      'paid_at', v_paid_at,
      'items', v_items,
      'subtotal_amount', v_subtotal,
      'service_charge_amount', v_service_charge,
      'discount_amount', v_discount,
      'vat_amount', v_vat,
      'total_amount', v_total,
      'payment_method', v_method,
      'payments', v_payments,
      'received_amount', v_received,
      'change_amount', v_change,
      'is_service', v_is_service,
      'currency', 'VND'
    )
  )
  ON CONFLICT (order_id) DO NOTHING
  RETURNING * INTO v_receipt;

  IF NOT FOUND THEN
    SELECT * INTO v_receipt
    FROM public.digital_receipts
    WHERE order_id = p_order_id;
  END IF;

  INSERT INTO public.audit_logs (
    actor_id, action, entity_type, entity_id, details
  ) VALUES (
    auth.uid(), 'ensure_digital_receipt', 'digital_receipts', v_receipt.id,
    jsonb_build_object(
      'store_id', v_order.restaurant_id,
      'order_id', p_order_id,
      'receipt_number', v_receipt.receipt_number
    )
  );

  RETURN jsonb_build_object(
    'receipt_id', v_receipt.id,
    'receipt_number', v_receipt.receipt_number,
    'created', true,
    'snapshot', v_receipt.snapshot
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.issue_digital_receipt_link(
  p_receipt_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_receipt public.digital_receipts%ROWTYPE;
  v_token text;
  v_link_id uuid;
  v_expires_at timestamptz;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'customer_display', 'admin', 'store_admin',
    'brand_admin', 'super_admin'
  ) THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_LINK_FORBIDDEN';
  END IF;

  SELECT * INTO v_receipt
  FROM public.digital_receipts
  WHERE id = p_receipt_id AND revoked_at IS NULL
  FOR UPDATE;
  IF NOT FOUND OR (
    NOT public.is_super_admin() AND NOT EXISTS (
      SELECT 1 FROM public.user_accessible_stores(auth.uid()) scope(store_id)
      WHERE scope.store_id = v_receipt.restaurant_id
    )
  ) THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_LINK_FORBIDDEN';
  END IF;

  v_token := rtrim(translate(
    encode(gen_random_bytes(24), 'base64'), '+/', '-_'
  ), '=');

  -- Keep at most three concurrently usable links. Locking the receipt above
  -- serializes issuance for the same receipt without blocking other stores.
  UPDATE public.digital_receipt_links
  SET revoked_at = COALESCE(revoked_at, now())
  WHERE id IN (
    SELECT link.id
    FROM public.digital_receipt_links link
    WHERE link.digital_receipt_id = v_receipt.id
      AND link.revoked_at IS NULL
      AND link.expires_at > now()
    ORDER BY link.created_at DESC, link.id DESC
    OFFSET 2
  );

  INSERT INTO public.digital_receipt_links (
    digital_receipt_id, token_hash
  ) VALUES (
    v_receipt.id, digest(v_token, 'sha256')
  ) RETURNING id, expires_at INTO v_link_id, v_expires_at;

  RETURN jsonb_build_object(
    'receipt_id', v_receipt.id,
    'link_id', v_link_id,
    'token', v_token,
    'expires_at', v_expires_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.consume_digital_receipt_rate_limit(
  p_request_key text
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_key bytea;
  v_now timestamptz := clock_timestamp();
  v_limit public.digital_receipt_access_limits%ROWTYPE;
BEGIN
  IF p_request_key !~ '^[0-9a-f]{64}$' THEN
    RETURN false;
  END IF;
  v_key := decode(p_request_key, 'hex');

  INSERT INTO public.digital_receipt_access_limits AS access (
    request_key, window_started_at, request_count, updated_at
  ) VALUES (v_key, v_now, 1, v_now)
  ON CONFLICT (request_key) DO NOTHING
  RETURNING access.* INTO v_limit;

  IF FOUND THEN
    RETURN true;
  END IF;

  SELECT * INTO v_limit
  FROM public.digital_receipt_access_limits
  WHERE request_key = v_key
  FOR UPDATE;

  IF v_limit.blocked_until IS NOT NULL
     AND v_limit.blocked_until > v_now THEN
    UPDATE public.digital_receipt_access_limits
    SET updated_at = v_now
    WHERE request_key = v_key;
    RETURN false;
  END IF;

  IF v_limit.window_started_at <= v_now - interval '1 minute' THEN
    UPDATE public.digital_receipt_access_limits
    SET window_started_at = v_now,
        request_count = 1,
        blocked_until = NULL,
        updated_at = v_now
    WHERE request_key = v_key;
    RETURN true;
  END IF;

  IF v_limit.request_count >= 30 THEN
    UPDATE public.digital_receipt_access_limits
    SET request_count = request_count + 1,
        blocked_until = v_now + interval '5 minutes',
        updated_at = v_now
    WHERE request_key = v_key;
    RETURN false;
  END IF;

  UPDATE public.digital_receipt_access_limits
  SET request_count = request_count + 1,
      blocked_until = NULL,
      updated_at = v_now
  WHERE request_key = v_key;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_public_receipt(
  p_token text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_snapshot jsonb;
  v_receipt_id uuid;
  v_issued_at timestamptz;
  v_expires_at timestamptz;
  v_link_id uuid;
BEGIN
  IF COALESCE(p_token, '') !~ '^[A-Za-z0-9_-]{32}$' THEN
    RETURN NULL;
  END IF;

  SELECT receipt.snapshot, receipt.id, receipt.created_at,
    link.expires_at, link.id
  INTO v_snapshot, v_receipt_id, v_issued_at, v_expires_at, v_link_id
  FROM public.digital_receipt_links link
  JOIN public.digital_receipts receipt
    ON receipt.id = link.digital_receipt_id
  WHERE link.token_hash = digest(p_token, 'sha256')
    AND link.revoked_at IS NULL
    AND link.expires_at > now()
    AND receipt.revoked_at IS NULL
  LIMIT 1;

  IF NOT FOUND THEN RETURN NULL; END IF;

  UPDATE public.digital_receipt_links
  SET last_presented_at = now()
  WHERE id = v_link_id
    AND (
      last_presented_at IS NULL
      OR last_presented_at < now() - interval '1 day'
    );

  RETURN v_snapshot || jsonb_build_object(
    'receipt_id', v_receipt_id,
    'issued_at', v_issued_at,
    'link_expires_at', v_expires_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.cleanup_digital_receipt_security_state(
  p_batch_size integer DEFAULT 1000
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(COALESCE(p_batch_size, 1000), 1), 5000);
  v_links_deleted integer := 0;
  v_limits_deleted integer := 0;
BEGIN
  WITH targets AS (
    SELECT link.id
    FROM public.digital_receipt_links link
    WHERE link.expires_at < now() - interval '30 days'
    ORDER BY link.expires_at, link.id
    LIMIT v_limit
    FOR UPDATE SKIP LOCKED
  ), deleted AS (
    DELETE FROM public.digital_receipt_links link
    USING targets
    WHERE link.id = targets.id
    RETURNING 1
  )
  SELECT count(*)::integer INTO v_links_deleted FROM deleted;

  WITH targets AS (
    SELECT access.request_key
    FROM public.digital_receipt_access_limits access
    WHERE access.updated_at < now() - interval '2 days'
    ORDER BY access.updated_at, access.request_key
    LIMIT v_limit
    FOR UPDATE SKIP LOCKED
  ), deleted AS (
    DELETE FROM public.digital_receipt_access_limits access
    USING targets
    WHERE access.request_key = targets.request_key
    RETURNING 1
  )
  SELECT count(*)::integer INTO v_limits_deleted FROM deleted;

  RETURN jsonb_build_object(
    'links_deleted', v_links_deleted,
    'rate_limits_deleted', v_limits_deleted
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.revoke_digital_receipt(
  p_receipt_id uuid,
  p_reason text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_receipt public.digital_receipts%ROWTYPE;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND OR v_actor.role NOT IN (
    'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) OR NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_REVOKE_FORBIDDEN';
  END IF;

  SELECT * INTO v_receipt
  FROM public.digital_receipts
  WHERE id = p_receipt_id
  FOR UPDATE;
  IF NOT FOUND OR (
    v_actor.role <> 'super_admin' AND NOT EXISTS (
      SELECT 1 FROM public.user_accessible_stores(auth.uid()) scope(store_id)
      WHERE scope.store_id = v_receipt.restaurant_id
    )
  ) THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_REVOKE_FORBIDDEN';
  END IF;

  UPDATE public.digital_receipts
  SET revoked_at = COALESCE(revoked_at, now()),
      revoked_by = COALESCE(revoked_by, v_actor.id),
      revocation_reason = COALESCE(revocation_reason, btrim(p_reason))
  WHERE id = p_receipt_id;
  UPDATE public.digital_receipt_links
  SET revoked_at = COALESCE(revoked_at, now())
  WHERE digital_receipt_id = p_receipt_id;

  INSERT INTO public.audit_logs (
    actor_id, action, entity_type, entity_id, details
  ) VALUES (
    auth.uid(), 'revoke_digital_receipt', 'digital_receipts', p_receipt_id,
    jsonb_build_object(
      'store_id', v_receipt.restaurant_id,
      'order_id', v_receipt.order_id,
      'reason', btrim(p_reason)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.ensure_digital_receipt(uuid, numeric, numeric)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.issue_digital_receipt_link(uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_public_receipt(text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.consume_digital_receipt_rate_limit(text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cleanup_digital_receipt_security_state(integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.revoke_digital_receipt(uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ensure_digital_receipt(uuid, numeric, numeric)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.issue_digital_receipt_link(uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_public_receipt(text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.consume_digital_receipt_rate_limit(text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.cleanup_digital_receipt_security_state(integer)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.revoke_digital_receipt(uuid, text)
  TO authenticated;

-- Extend the existing customer-facing display without persisting a raw public
-- receipt token. The display device issues its own in-memory link after it
-- receives the receipt ID.
ALTER TABLE public.customer_payment_displays
  DROP CONSTRAINT IF EXISTS customer_payment_displays_state_check;
ALTER TABLE public.customer_payment_displays
  ADD CONSTRAINT customer_payment_displays_state_check CHECK (
    (status = 'idle' AND order_id IS NULL AND payload IS NULL)
    OR (
      status = 'showing'
      AND order_id IS NOT NULL
      AND payload IS NOT NULL
      AND jsonb_typeof(payload) = 'object'
      AND payload ? 'order_id'
      AND payload->>'order_id' = order_id::text
      AND (
        (
          COALESCE(payload->>'phase', 'payment') = 'payment'
          AND jsonb_typeof(payload->'items') = 'array'
          AND jsonb_typeof(payload->'total') = 'number'
        )
        OR (
          payload->>'phase' = 'receipt'
          AND NULLIF(payload->>'receipt_id', '') IS NOT NULL
          AND jsonb_typeof(payload->'total') = 'number'
        )
      )
    )
  );

CREATE OR REPLACE FUNCTION public.show_customer_receipt_display(
  p_store_id uuid,
  p_order_id uuid,
  p_receipt_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_receipt public.digital_receipts%ROWTYPE;
  v_table_number text;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) OR (
    v_actor.role <> 'super_admin' AND NOT EXISTS (
      SELECT 1 FROM public.user_accessible_stores(auth.uid()) scope(store_id)
      WHERE scope.store_id = p_store_id
    )
  ) THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_DISPLAY_FORBIDDEN';
  END IF;

  SELECT * INTO v_receipt
  FROM public.digital_receipts
  WHERE id = p_receipt_id
    AND order_id = p_order_id
    AND restaurant_id = p_store_id
    AND revoked_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_DISPLAY_UNAVAILABLE';
  END IF;

  SELECT COALESCE(table_row.table_number, 'STAFF')
  INTO v_table_number
  FROM public.orders order_row
  LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
  WHERE order_row.id = p_order_id
    AND order_row.restaurant_id = p_store_id
    AND order_row.status = 'completed';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_DISPLAY_UNAVAILABLE';
  END IF;

  INSERT INTO public.customer_payment_displays (
    store_id, order_id, status, payload,
    shown_by_user_id, shown_at, updated_at
  ) VALUES (
    p_store_id,
    p_order_id,
    'showing',
    jsonb_build_object(
      'phase', 'receipt',
      'display_revision', gen_random_uuid(),
      'order_id', p_order_id,
      'receipt_id', p_receipt_id,
      'table_number', v_table_number,
      'total', COALESCE((v_receipt.snapshot->>'total_amount')::numeric, 0)
    ),
    v_actor.id,
    now(),
    now()
  ) ON CONFLICT (store_id) DO UPDATE SET
    order_id = EXCLUDED.order_id,
    status = EXCLUDED.status,
    payload = EXCLUDED.payload,
    shown_by_user_id = EXCLUDED.shown_by_user_id,
    shown_at = EXCLUDED.shown_at,
    updated_at = EXCLUDED.updated_at;
END;
$$;

REVOKE ALL ON FUNCTION public.show_customer_receipt_display(uuid, uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.show_customer_receipt_display(uuid, uuid, uuid)
  TO authenticated;

DO $schedule$
DECLARE
  v_job_id bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    FOR v_job_id IN
      SELECT jobid
      FROM cron.job
      WHERE jobname = 'digital-receipt-security-retention-daily'
    LOOP
      PERFORM cron.unschedule(v_job_id);
    END LOOP;

    PERFORM cron.schedule(
      'digital-receipt-security-retention-daily',
      '37 18 * * *',
      $command$SELECT public.cleanup_digital_receipt_security_state()$command$
    );
  ELSE
    RAISE NOTICE 'pg_cron unavailable; skipped digital receipt retention schedule.';
  END IF;
EXCEPTION
  WHEN invalid_schema_name OR undefined_function OR insufficient_privilege THEN
    RAISE NOTICE 'pg_cron unavailable; skipped digital receipt retention schedule.';
END;
$schedule$;

DO $verify$
DECLARE
  v_definition text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'orders'
      AND column_name = 'fulfillment_mode_snapshot'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'order_items'
      AND column_name = 'fulfillment_mode_snapshot'
  ) THEN
    RAISE EXCEPTION 'FULFILLMENT_MODE_CAPTURE_COLUMNS_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.claim_print_jobs(uuid,integer)'::regprocedure
  ) INTO v_definition;
  IF position('emergency_held_at IS NULL' IN v_definition) = 0
     OR position('NOT EXISTS' IN v_definition) > 0 THEN
    RAISE EXCEPTION 'FULFILLMENT_MODE_PRINT_CLAIM_UNSAFE';
  END IF;

  SELECT pg_get_functiondef(
    'public.get_public_receipt(text)'::regprocedure
  ) INTO v_definition;
  IF position('digest(p_token' IN v_definition) = 0
     OR position('link.expires_at > now()' IN v_definition) = 0
     OR position('last_presented_at < now() - interval ''1 day''' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_PUBLIC_LOOKUP_UNSAFE';
  END IF;

  IF has_table_privilege('anon', 'public.digital_receipts', 'SELECT')
     OR has_table_privilege('anon', 'public.digital_receipt_links', 'SELECT')
     OR has_table_privilege('authenticated', 'public.digital_receipt_links', 'SELECT')
     OR has_table_privilege(
       'anon', 'public.digital_receipt_access_limits', 'SELECT'
     ) OR has_function_privilege(
       'anon', 'public.get_public_receipt(text)', 'EXECUTE'
     ) OR NOT has_function_privilege(
       'service_role', 'public.get_public_receipt(text)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_DIRECT_READ_FORBIDDEN';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'digital_receipt_links'
      AND column_name = 'expires_at'
  ) OR to_regprocedure(
    'public.consume_digital_receipt_rate_limit(text)'
  ) IS NULL OR to_regprocedure(
    'public.cleanup_digital_receipt_security_state(integer)'
  ) IS NULL THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_SECURITY_STATE_MISSING';
  END IF;

  IF to_regprocedure(
    'public.super_admin_set_fulfillment_mode(uuid,text,text,uuid)'
  ) IS NULL OR to_regprocedure(
    'public.ensure_digital_receipt(uuid,numeric,numeric)'
  ) IS NULL OR to_regprocedure(
    'public.revoke_digital_receipt(uuid,text)'
  ) IS NULL OR to_regprocedure(
    'public.show_customer_receipt_display(uuid,uuid,uuid)'
  ) IS NULL THEN
    RAISE EXCEPTION 'PAPERLESS_RECEIPT_RPC_MISSING';
  END IF;
END;
$verify$;

COMMIT;
