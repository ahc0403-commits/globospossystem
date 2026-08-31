BEGIN;

-- production-gate: self-verifying
--
-- Additive KDS realtime transport. Existing fulfillment tables, RPCs, status
-- values, triggers, printer/payment behavior, and client polling stay intact
-- until a store is explicitly moved from legacy to shadow/active.

CREATE TABLE IF NOT EXISTS public.kds_realtime_rollouts (
  restaurant_id uuid PRIMARY KEY
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  mode text NOT NULL DEFAULT 'legacy'
    CHECK (mode IN ('legacy', 'shadow', 'active')),
  updated_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.kds_store_revisions (
  restaurant_id uuid PRIMARY KEY
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  current_revision bigint NOT NULL DEFAULT 0
    CHECK (current_revision >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.kds_shadow_health (
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  station_type text NOT NULL
    CHECK (station_type IN ('kitchen', 'tray', 'floor')),
  floor_key text NOT NULL DEFAULT ''
    CHECK (floor_key IN ('', '1F', '2F')),
  observation_count bigint NOT NULL DEFAULT 0
    CHECK (observation_count >= 0),
  mismatch_count bigint NOT NULL DEFAULT 0
    CHECK (mismatch_count >= 0),
  last_revision bigint NOT NULL DEFAULT 0
    CHECK (last_revision >= 0),
  last_match boolean,
  last_mismatch_at timestamptz,
  shadow_started_at timestamptz NOT NULL,
  last_observed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (restaurant_id, station_type, floor_key)
);

CREATE TABLE IF NOT EXISTS public.kds_change_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  revision bigint NOT NULL CHECK (revision > 0),
  session_id uuid
    REFERENCES public.emergency_fulfillment_sessions(id) ON DELETE SET NULL,
  event_id uuid NOT NULL,
  event_type text NOT NULL CHECK (btrim(event_type) <> ''),
  target_stations text[] NOT NULL DEFAULT ARRAY['control']::text[],
  target_floor_label text,
  queue_id uuid
    REFERENCES public.emergency_order_queue(id) ON DELETE SET NULL,
  order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  order_item_id uuid REFERENCES public.order_items(id) ON DELETE SET NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  dedupe_key text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT kds_change_log_store_revision_unique
    UNIQUE (restaurant_id, revision),
  CONSTRAINT kds_change_log_event_unique UNIQUE (event_id),
  CONSTRAINT kds_change_log_dedupe_unique
    UNIQUE (restaurant_id, dedupe_key),
  CONSTRAINT kds_change_log_targets_present CHECK (
    cardinality(target_stations) > 0
    AND target_stations <@ ARRAY['kitchen', 'tray', 'floor', 'control']::text[]
  ),
  CONSTRAINT kds_change_log_floor_target CHECK (
    target_floor_label IS NULL OR target_floor_label IN ('1F', '2F')
  )
);

CREATE INDEX IF NOT EXISTS kds_change_log_store_revision_idx
  ON public.kds_change_log (restaurant_id, revision);
CREATE INDEX IF NOT EXISTS kds_change_log_store_created_idx
  ON public.kds_change_log (restaurant_id, created_at);
CREATE INDEX IF NOT EXISTS kds_change_log_queue_revision_idx
  ON public.kds_change_log (restaurant_id, queue_id, revision)
  WHERE queue_id IS NOT NULL;

ALTER TABLE public.kds_realtime_rollouts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kds_store_revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kds_shadow_health ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kds_change_log ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.kds_realtime_rollouts
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.kds_store_revisions
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.kds_shadow_health
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.kds_change_log
  FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.kds_realtime_rollouts TO service_role;
GRANT ALL ON public.kds_store_revisions TO service_role;
GRANT ALL ON public.kds_shadow_health TO service_role;
GRANT ALL ON public.kds_change_log TO service_role;

CREATE OR REPLACE FUNCTION public.kds_change_envelope(
  p_change public.kds_change_log
) RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
  SELECT jsonb_build_object(
    'schema_version', 1,
    'restaurant_id', p_change.restaurant_id,
    'session_id', p_change.session_id,
    'revision', p_change.revision,
    'event_id', p_change.event_id,
    'event_type', p_change.event_type,
    'target_stations', p_change.target_stations,
    'target_floor_label', p_change.target_floor_label,
    'queue_id', p_change.queue_id,
    'order_id', p_change.order_id,
    'order_item_id', p_change.order_item_id,
    'payload', p_change.payload,
    'occurred_at', p_change.created_at
  );
$$;

REVOKE ALL ON FUNCTION public.kds_change_envelope(public.kds_change_log)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.kds_append_change(
  p_restaurant_id uuid,
  p_session_id uuid,
  p_event_id uuid,
  p_event_type text,
  p_target_stations text[],
  p_target_floor_label text,
  p_queue_id uuid,
  p_order_id uuid,
  p_order_item_id uuid,
  p_payload jsonb,
  p_dedupe_key text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_revision bigint;
  v_change public.kds_change_log%ROWTYPE;
BEGIN
  IF p_restaurant_id IS NULL OR p_event_id IS NULL
     OR NULLIF(btrim(COALESCE(p_event_type, '')), '') IS NULL
     OR COALESCE(cardinality(p_target_stations), 0) = 0
     OR NOT p_target_stations
       <@ ARRAY['kitchen', 'tray', 'floor', 'control']::text[] THEN
    RAISE EXCEPTION 'KDS_CHANGE_INPUT_INVALID';
  END IF;

  INSERT INTO public.kds_store_revisions (restaurant_id)
  VALUES (p_restaurant_id)
  ON CONFLICT (restaurant_id) DO NOTHING;

  SELECT revision.* INTO v_change
  FROM public.kds_change_log revision
  WHERE revision.event_id = p_event_id
     OR (
       p_dedupe_key IS NOT NULL
       AND revision.restaurant_id = p_restaurant_id
       AND revision.dedupe_key = p_dedupe_key
     )
  ORDER BY revision.revision
  LIMIT 1;
  IF FOUND THEN
    UPDATE public.kds_change_log change
    SET target_stations = CASE
          WHEN 'control' = ANY(change.target_stations || p_target_stations)
            THEN ARRAY['control']::text[]
          ELSE ARRAY(
            SELECT DISTINCT target
            FROM unnest(change.target_stations || p_target_stations) target
            ORDER BY target
          )
        END,
        target_floor_label = COALESCE(
          change.target_floor_label, p_target_floor_label
        )
    WHERE change.id = v_change.id
    RETURNING * INTO v_change;
    RETURN public.kds_change_envelope(v_change);
  END IF;

  SELECT current_revision INTO v_revision
  FROM public.kds_store_revisions
  WHERE restaurant_id = p_restaurant_id
  FOR UPDATE;

  -- Recheck after the store lock so concurrent retries cannot allocate two
  -- revisions for the same logical event.
  SELECT revision.* INTO v_change
  FROM public.kds_change_log revision
  WHERE revision.event_id = p_event_id
     OR (
       p_dedupe_key IS NOT NULL
       AND revision.restaurant_id = p_restaurant_id
       AND revision.dedupe_key = p_dedupe_key
     )
  ORDER BY revision.revision
  LIMIT 1;
  IF FOUND THEN
    UPDATE public.kds_change_log change
    SET target_stations = CASE
          WHEN 'control' = ANY(change.target_stations || p_target_stations)
            THEN ARRAY['control']::text[]
          ELSE ARRAY(
            SELECT DISTINCT target
            FROM unnest(change.target_stations || p_target_stations) target
            ORDER BY target
          )
        END,
        target_floor_label = COALESCE(
          change.target_floor_label, p_target_floor_label
        )
    WHERE change.id = v_change.id
    RETURNING * INTO v_change;
    RETURN public.kds_change_envelope(v_change);
  END IF;

  v_revision := v_revision + 1;
  UPDATE public.kds_store_revisions
  SET current_revision = v_revision, updated_at = now()
  WHERE restaurant_id = p_restaurant_id;

  INSERT INTO public.kds_change_log (
    restaurant_id, revision, session_id, event_id, event_type,
    target_stations, target_floor_label, queue_id, order_id, order_item_id,
    payload, dedupe_key
  ) VALUES (
    p_restaurant_id, v_revision, p_session_id, p_event_id, p_event_type,
    p_target_stations, p_target_floor_label, p_queue_id, p_order_id,
    p_order_item_id, COALESCE(p_payload, '{}'::jsonb), p_dedupe_key
  ) RETURNING * INTO v_change;

  RETURN public.kds_change_envelope(v_change);
END;
$$;

REVOKE ALL ON FUNCTION public.kds_append_change(
  uuid, uuid, uuid, text, text[], text, uuid, uuid, uuid, jsonb, text
) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.kds_can_access_topic(p_topic text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_parts text[] := string_to_array(COALESCE(p_topic, ''), ':');
  v_store_id uuid;
  v_station text;
  v_floor text;
  v_assignment public.emergency_station_assignments%ROWTYPE;
BEGIN
  IF cardinality(v_parts) NOT IN (3, 4) OR v_parts[1] <> 'kds' THEN
    RETURN false;
  END IF;
  BEGIN
    v_store_id := v_parts[2]::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN false;
  END;
  v_station := v_parts[3];
  v_floor := CASE WHEN cardinality(v_parts) = 4 THEN v_parts[4] END;
  IF v_station NOT IN ('kitchen', 'tray', 'floor', 'control') THEN
    RETURN false;
  END IF;

  SELECT assignment.* INTO v_assignment
  FROM public.users user_row
  JOIN public.emergency_station_assignments assignment
    ON assignment.user_id = user_row.id
   AND assignment.restaurant_id = v_store_id
   AND assignment.is_active = true
  WHERE user_row.auth_id = auth.uid()
    AND user_row.is_active = true
  LIMIT 1;
  IF NOT FOUND THEN RETURN false; END IF;

  IF v_station = 'control' THEN
    RETURN cardinality(v_parts) = 3;
  END IF;
  IF v_assignment.station_type <> v_station THEN RETURN false; END IF;
  IF v_station = 'floor' THEN
    RETURN cardinality(v_parts) = 4
      AND v_assignment.floor_label = v_floor;
  END IF;
  RETURN cardinality(v_parts) = 3;
END;
$$;

REVOKE ALL ON FUNCTION public.kds_can_access_topic(text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.kds_can_access_topic(text)
  TO authenticated;

DO $policy$
BEGIN
  IF to_regclass('realtime.messages') IS NOT NULL THEN
    EXECUTE 'DROP POLICY IF EXISTS kds_private_broadcast_read ON realtime.messages';
    EXECUTE $sql$
      CREATE POLICY kds_private_broadcast_read
      ON realtime.messages
      FOR SELECT
      TO authenticated
      USING (public.kds_can_access_topic(realtime.topic()))
    $sql$;
  END IF;
END;
$policy$;

CREATE OR REPLACE FUNCTION public.kds_broadcast_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, realtime, pg_catalog
AS $$
DECLARE
  v_station text;
  v_topic text;
  v_change public.kds_change_log%ROWTYPE;
BEGIN
  -- The trigger is deferred so coalesced source rows can merge their station
  -- targets before one final Broadcast is emitted at transaction end.
  SELECT change.* INTO v_change
  FROM public.kds_change_log change
  WHERE change.id = NEW.id;
  IF NOT FOUND THEN RETURN NEW; END IF;
  FOREACH v_station IN ARRAY v_change.target_stations LOOP
    v_topic := CASE
      WHEN v_station = 'floor' THEN
        'kds:' || v_change.restaurant_id::text || ':floor:'
          || COALESCE(v_change.target_floor_label, '')
      ELSE 'kds:' || v_change.restaurant_id::text || ':' || v_station
    END;
    IF v_station <> 'floor' OR v_change.target_floor_label IS NOT NULL THEN
      PERFORM realtime.send(
        public.kds_change_envelope(v_change),
        'kds_change',
        v_topic,
        true
      );
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.kds_broadcast_change()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS kds_change_log_broadcast_trigger
  ON public.kds_change_log;
CREATE CONSTRAINT TRIGGER kds_change_log_broadcast_trigger
AFTER INSERT ON public.kds_change_log
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION public.kds_broadcast_change();

CREATE OR REPLACE FUNCTION public.kds_capture_fulfillment_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_queue public.emergency_order_queue%ROWTYPE;
  v_action_id uuid;
  v_action public.emergency_fulfillment_actions%ROWTYPE;
  v_targets text[] := ARRAY['control']::text[];
  v_dedupe_key text;
  v_event_type text := NEW.stage;
  v_payload jsonb;
  v_request public.leftover_packaging_requests%ROWTYPE;
  v_queue_no integer;
  v_delivery boolean := false;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.kds_realtime_rollouts rollout
    WHERE rollout.restaurant_id = NEW.restaurant_id
      AND rollout.mode IN ('shadow', 'active')
  ) THEN
    RETURN NEW;
  END IF;

  SELECT queue.* INTO v_queue
  FROM public.emergency_order_queue queue
  WHERE queue.session_id = NEW.session_id
    AND queue.order_id = NEW.order_id
  LIMIT 1;

  BEGIN
    v_action_id := COALESCE(
      NEW.action_id,
      CASE WHEN COALESCE(NEW.details->>'order_action_id', '') ~*
        '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        THEN (NEW.details->>'order_action_id')::uuid END,
      CASE WHEN COALESCE(NEW.details->>'revert_action_id', '') ~*
        '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        THEN (NEW.details->>'revert_action_id')::uuid END
    );
  EXCEPTION WHEN invalid_text_representation THEN
    v_action_id := NEW.action_id;
  END;

  SELECT COALESCE(order_row.sales_channel, 'dine_in') = 'delivery'
  INTO v_delivery
  FROM public.orders order_row
  WHERE order_row.id = NEW.order_id;

  IF v_action_id IS NOT NULL THEN
    SELECT action.* INTO v_action
    FROM public.emergency_fulfillment_actions action
    WHERE action.action_id = v_action_id;
    v_targets := CASE v_action.station_type
      WHEN 'kitchen' THEN ARRAY['kitchen', 'tray']::text[]
      WHEN 'tray' THEN CASE WHEN v_delivery
        THEN ARRAY['tray']::text[]
        ELSE ARRAY['tray', 'floor']::text[] END
      WHEN 'floor' THEN ARRAY['floor']::text[]
      ELSE ARRAY['control']::text[]
    END;
    v_event_type := CASE WHEN v_action.action_kind = 'revert'
      THEN 'order_reverted' ELSE 'order_completed' END;
    v_dedupe_key := 'action:' || v_action_id::text;
  ELSIF NEW.stage = 'order_received' THEN
    -- A new order can create kitchen and floor-direct lines together, while
    -- an additional kitchen line only affects the kitchen until handoff.
    v_targets := CASE WHEN NEW.details->>'event_scope' = 'queue'
      THEN ARRAY['control']::text[]
      ELSE ARRAY['kitchen']::text[] END;
    v_event_type := 'ticket_changed';
  ELSIF NEW.stage = 'floor_direct_ready' THEN
    v_targets := ARRAY['floor']::text[];
    v_event_type := 'ticket_changed';
  ELSIF NEW.stage = 'kitchen_done' THEN
    v_targets := ARRAY['kitchen', 'tray']::text[];
  ELSIF NEW.stage = 'tray_received' THEN
    v_targets := ARRAY['tray']::text[];
  ELSIF NEW.stage = 'tray_dispatched' THEN
    v_targets := CASE WHEN v_delivery
      THEN ARRAY['tray']::text[]
      ELSE ARRAY['tray', 'floor']::text[] END;
  ELSIF NEW.stage = 'floor_served' THEN
    v_targets := ARRAY['floor']::text[];
  END IF;

  IF NEW.leftover_packaging_request_id IS NOT NULL THEN
    SELECT request.* INTO v_request
    FROM public.leftover_packaging_requests request
    WHERE request.id = NEW.leftover_packaging_request_id;
    SELECT queue_no INTO v_queue_no
    FROM public.emergency_order_queue
    WHERE id = v_request.queue_id;
    v_event_type := 'leftover_changed';
    v_targets := CASE NEW.stage
      WHEN 'leftover_requested' THEN ARRAY['floor']::text[]
      WHEN 'leftover_floor_to_tray' THEN ARRAY['floor', 'tray']::text[]
      WHEN 'leftover_tray_to_kitchen' THEN ARRAY['tray', 'kitchen']::text[]
      WHEN 'leftover_kitchen_packaged' THEN ARRAY['kitchen', 'tray']::text[]
      WHEN 'leftover_tray_to_floor' THEN ARRAY['tray', 'floor']::text[]
      WHEN 'leftover_floor_delivered' THEN ARRAY['floor']::text[]
      ELSE ARRAY['control']::text[]
    END;
    v_payload := jsonb_build_object(
      'kind', 'leftover_changed',
      'task', jsonb_build_object(
        'id', v_request.id,
        'order_id', v_request.order_id,
        'queue_id', v_request.queue_id,
        'queue_no', v_queue_no,
        'table_number', v_request.table_number,
        'floor_label', v_request.floor_label,
        'status', v_request.status,
        'requested_at', v_request.requested_at,
        'updated_at', v_request.updated_at
      )
    );
  ELSE
    v_payload := jsonb_build_object(
      'kind', 'ticket_invalidated',
      'queue_id', v_queue.id,
      'order_id', NEW.order_id,
      'reason', v_event_type,
      'stage', NEW.stage
    );
  END IF;

  IF v_dedupe_key IS NULL THEN
    -- Every non-order-action source mutation in one transaction/order is one
    -- logical invalidation even when several derived ledgers are updated.
    v_dedupe_key := 'source:' || txid_current()::text || ':'
      || NEW.order_id::text;
  END IF;

  PERFORM public.kds_append_change(
    NEW.restaurant_id,
    NEW.session_id,
    COALESCE(v_action_id, NEW.event_id),
    v_event_type,
    v_targets,
    v_queue.floor_label,
    v_queue.id,
    NEW.order_id,
    NEW.order_item_id,
    v_payload,
    v_dedupe_key
  );
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.kds_capture_fulfillment_event()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS kds_capture_fulfillment_event_trigger
  ON public.emergency_fulfillment_events;
CREATE TRIGGER kds_capture_fulfillment_event_trigger
AFTER INSERT ON public.emergency_fulfillment_events
FOR EACH ROW EXECUTE FUNCTION public.kds_capture_fulfillment_event();

CREATE OR REPLACE FUNCTION public.kds_capture_session_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.kds_realtime_rollouts rollout
    WHERE rollout.restaurant_id = NEW.restaurant_id
      AND rollout.mode IN ('shadow', 'active')
  ) THEN
    RETURN NEW;
  END IF;
  PERFORM public.kds_append_change(
    NEW.restaurant_id,
    NEW.id,
    gen_random_uuid(),
    'session_changed',
    ARRAY['control']::text[],
    NULL,
    NULL,
    NULL,
    NULL,
    jsonb_build_object(
      'kind', 'bootstrap_required',
      'session_id', NEW.id,
      'status', NEW.status
    ),
    NULL
  );
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.kds_capture_session_change()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS kds_capture_session_change_trigger
  ON public.emergency_fulfillment_sessions;
CREATE TRIGGER kds_capture_session_change_trigger
AFTER INSERT OR UPDATE OF status ON public.emergency_fulfillment_sessions
FOR EACH ROW EXECUTE FUNCTION public.kds_capture_session_change();

-- Order-item synchronization is the source of truth for base, combo, and
-- floor-direct membership. This alphabetically-last trigger runs after the
-- established synchronization triggers and covers quantity reductions and
-- cancellations, which do not always create a fulfillment event today.
CREATE OR REPLACE FUNCTION public.kds_capture_order_item_source_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_session_id uuid;
  v_queue public.emergency_order_queue%ROWTYPE;
BEGIN
  IF TG_OP = 'INSERT' THEN RETURN NEW; END IF;
  IF NEW.quantity >= OLD.quantity
     AND NEW.status IS NOT DISTINCT FROM OLD.status
     AND NEW.combo_components IS NOT DISTINCT FROM OLD.combo_components
     AND NEW.fulfillment_route_snapshot
       IS NOT DISTINCT FROM OLD.fulfillment_route_snapshot THEN
    RETURN NEW;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.kds_realtime_rollouts rollout
    WHERE rollout.restaurant_id = NEW.restaurant_id
      AND rollout.mode IN ('shadow', 'active')
  ) THEN
    RETURN NEW;
  END IF;
  SELECT session.id INTO v_session_id
  FROM public.emergency_fulfillment_sessions session
  WHERE session.restaurant_id = NEW.restaurant_id
    AND session.status = 'active';
  IF v_session_id IS NULL THEN RETURN NEW; END IF;
  SELECT queue.* INTO v_queue
  FROM public.emergency_order_queue queue
  WHERE queue.session_id = v_session_id
    AND queue.order_id = NEW.order_id;
  IF NOT FOUND THEN RETURN NEW; END IF;

  PERFORM public.kds_append_change(
    NEW.restaurant_id,
    v_session_id,
    gen_random_uuid(),
    'ticket_changed',
    ARRAY['control']::text[],
    v_queue.floor_label,
    v_queue.id,
    NEW.order_id,
    NEW.id,
    jsonb_build_object(
      'kind', 'ticket_invalidated',
      'queue_id', v_queue.id,
      'order_id', NEW.order_id,
      'reason', 'order_item_source_changed'
    ),
    'source:' || txid_current()::text || ':' || NEW.order_id::text
  );
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.kds_capture_order_item_source_change()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS zzz_kds_capture_order_item_source_change_trigger
  ON public.order_items;
CREATE TRIGGER zzz_kds_capture_order_item_source_change_trigger
AFTER INSERT OR UPDATE OF quantity, status, combo_components,
  fulfillment_route_snapshot
ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.kds_capture_order_item_source_change();

-- Mode changes are rare control-plane changes. They require a bootstrap so
-- the established active/draining and print/paperless UI semantics stay exact.
CREATE OR REPLACE FUNCTION public.kds_capture_fulfillment_mode_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_session_id uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.kds_realtime_rollouts rollout
    WHERE rollout.restaurant_id = NEW.restaurant_id
      AND rollout.mode IN ('shadow', 'active')
  ) THEN
    RETURN NEW;
  END IF;
  SELECT session.id INTO v_session_id
  FROM public.emergency_fulfillment_sessions session
  WHERE session.restaurant_id = NEW.restaurant_id
    AND session.status = 'active';
  PERFORM public.kds_append_change(
    NEW.restaurant_id,
    v_session_id,
    gen_random_uuid(),
    'fulfillment_mode_changed',
    ARRAY['control']::text[],
    NULL,
    NULL,
    NULL,
    NULL,
    jsonb_build_object(
      'kind', 'bootstrap_required',
      'mode', NEW.next_mode
    ),
    'mode-change:' || NEW.id::text
  );
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.kds_capture_fulfillment_mode_change()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS kds_capture_fulfillment_mode_change_trigger
  ON public.fulfillment_mode_changes;
CREATE TRIGGER kds_capture_fulfillment_mode_change_trigger
AFTER INSERT ON public.fulfillment_mode_changes
FOR EACH ROW EXECUTE FUNCTION public.kds_capture_fulfillment_mode_change();

CREATE OR REPLACE FUNCTION public.get_kds_sync_config()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_session_id uuid;
  v_mode text := 'legacy';
  v_revision bigint := 0;
BEGIN
  SELECT * INTO v_user FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;
  SELECT * INTO v_assignment
  FROM public.emergency_station_assignments
  WHERE user_id = v_user.id
    AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'mode', 'legacy', 'assigned', false,
      'restaurant_id', v_user.restaurant_id, 'revision', 0
    );
  END IF;
  SELECT session.id INTO v_session_id
  FROM public.emergency_fulfillment_sessions session
  WHERE session.restaurant_id = v_assignment.restaurant_id
    AND session.status = 'active';
  SELECT COALESCE(rollout.mode, 'legacy') INTO v_mode
  FROM (SELECT 1) seed
  LEFT JOIN public.kds_realtime_rollouts rollout
    ON rollout.restaurant_id = v_assignment.restaurant_id;
  SELECT COALESCE(revision.current_revision, 0) INTO v_revision
  FROM (SELECT 1) seed
  LEFT JOIN public.kds_store_revisions revision
    ON revision.restaurant_id = v_assignment.restaurant_id;
  RETURN jsonb_build_object(
    'mode', v_mode,
    'assigned', true,
    'restaurant_id', v_assignment.restaurant_id,
    'session_id', v_session_id,
    'station_type', v_assignment.station_type,
    'floor_label', v_assignment.floor_label,
    'revision', v_revision
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_kds_sync_config()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_kds_sync_config()
  TO authenticated;

CREATE OR REPLACE FUNCTION public.get_kds_bootstrap_v2()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_config jsonb;
  v_snapshot jsonb;
  v_completed jsonb;
  v_timings jsonb;
  v_store_id uuid;
  v_mode text;
BEGIN
  v_config := public.get_kds_sync_config();
  v_snapshot := public.get_emergency_station_snapshot();
  v_completed := public.get_emergency_station_today_completed();
  v_timings := public.get_emergency_station_timings();
  v_store_id := NULLIF(v_config->>'restaurant_id', '')::uuid;
  IF v_store_id IS NOT NULL THEN
    v_mode := public.get_store_fulfillment_mode(v_store_id);
  END IF;
  RETURN jsonb_build_object(
    'sync', v_config,
    'snapshot', v_snapshot,
    'completed_orders', COALESCE(v_completed, '[]'::jsonb),
    'timings', COALESCE(v_timings, '[]'::jsonb),
    'fulfillment_mode', COALESCE(v_mode, 'paperless')
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_kds_bootstrap_v2()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_kds_bootstrap_v2()
  TO authenticated;

CREATE OR REPLACE FUNCTION public.get_kds_high_watermark_v2()
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_config jsonb;
BEGIN
  v_config := public.get_kds_sync_config();
  RETURN COALESCE((v_config->>'revision')::bigint, 0);
END;
$$;

REVOKE ALL ON FUNCTION public.get_kds_high_watermark_v2()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_kds_high_watermark_v2()
  TO authenticated;

CREATE OR REPLACE FUNCTION public.get_kds_changes_v2(
  p_after_revision bigint,
  p_limit integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_config jsonb;
  v_store_id uuid;
  v_station text;
  v_floor text;
  v_after bigint := GREATEST(COALESCE(p_after_revision, 0), 0);
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
  v_current bigint := 0;
  v_earliest bigint;
  v_scanned bigint;
  v_changes jsonb := '[]'::jsonb;
BEGIN
  v_config := public.get_kds_sync_config();
  IF COALESCE((v_config->>'assigned')::boolean, false) = false THEN
    RAISE EXCEPTION 'EMERGENCY_STATION_REQUIRED';
  END IF;
  v_store_id := (v_config->>'restaurant_id')::uuid;
  v_station := v_config->>'station_type';
  v_floor := v_config->>'floor_label';
  v_current := COALESCE((v_config->>'revision')::bigint, 0);
  SELECT min(revision) INTO v_earliest
  FROM public.kds_change_log
  WHERE restaurant_id = v_store_id;
  IF v_earliest IS NOT NULL AND v_after < v_earliest - 1 THEN
    RETURN jsonb_build_object(
      'bootstrap_required', true,
      'scanned_through_revision', v_after,
      'current_revision', v_current,
      'has_more', false,
      'changes', '[]'::jsonb
    );
  END IF;

  WITH revision_window AS (
    SELECT change.*
    FROM public.kds_change_log change
    WHERE change.restaurant_id = v_store_id
      AND change.revision > v_after
    ORDER BY change.revision
    LIMIT v_limit
  )
  SELECT
    COALESCE(max(change_row.revision), v_after),
    COALESCE(jsonb_agg(jsonb_build_object(
      'schema_version', 1,
      'restaurant_id', change_row.restaurant_id,
      'session_id', change_row.session_id,
      'revision', change_row.revision,
      'event_id', change_row.event_id,
      'event_type', change_row.event_type,
      'target_stations', change_row.target_stations,
      'target_floor_label', change_row.target_floor_label,
      'queue_id', change_row.queue_id,
      'order_id', change_row.order_id,
      'order_item_id', change_row.order_item_id,
      'payload', change_row.payload,
      'occurred_at', change_row.created_at
    ) ORDER BY change_row.revision) FILTER (
        WHERE 'control' = ANY(change_row.target_stations)
           OR (
             v_station = ANY(change_row.target_stations)
             AND (
               v_station <> 'floor'
               OR change_row.target_floor_label IS NULL
               OR change_row.target_floor_label = v_floor
             )
           )
      ), '[]'::jsonb)
  INTO v_scanned, v_changes
  FROM revision_window change_row;

  RETURN jsonb_build_object(
    'bootstrap_required', false,
    'scanned_through_revision', v_scanned,
    'current_revision', v_current,
    'has_more', v_scanned < v_current,
    'changes', v_changes
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_kds_changes_v2(bigint, integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_kds_changes_v2(bigint, integer)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.get_kds_ticket_v2(p_queue_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_queue public.emergency_order_queue%ROWTYPE;
  v_ticket jsonb;
  v_orders jsonb;
  v_started_at timestamptz;
  v_completed_at timestamptz;
  v_revision bigint := 0;
  v_sales_channel text := 'dine_in';
BEGIN
  IF p_queue_id IS NULL THEN RAISE EXCEPTION 'KDS_TICKET_INPUT_INVALID'; END IF;
  SELECT * INTO v_user FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;
  SELECT * INTO v_assignment
  FROM public.emergency_station_assignments
  WHERE user_id = v_user.id
    AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_STATION_REQUIRED'; END IF;
  SELECT queue.* INTO v_queue
  FROM public.emergency_order_queue queue
  JOIN public.emergency_fulfillment_sessions session
    ON session.id = queue.session_id AND session.status = 'active'
  WHERE queue.id = p_queue_id
    AND queue.restaurant_id = v_assignment.restaurant_id;
  SELECT COALESCE(revision.current_revision, 0) INTO v_revision
  FROM (SELECT 1) seed
  LEFT JOIN public.kds_store_revisions revision
    ON revision.restaurant_id = v_assignment.restaurant_id;
  IF v_queue.id IS NULL
     OR (v_assignment.station_type = 'floor'
       AND v_assignment.floor_label <> v_queue.floor_label) THEN
    RETURN jsonb_build_object('ticket', NULL, 'revision', v_revision);
  END IF;
  SELECT COALESCE(order_row.sales_channel, 'dine_in') INTO v_sales_channel
  FROM public.orders order_row WHERE order_row.id = v_queue.order_id;
  IF v_assignment.station_type = 'floor' AND v_sales_channel = 'delivery' THEN
    RETURN jsonb_build_object('ticket', NULL, 'revision', v_revision);
  END IF;

  SELECT jsonb_build_object(
    'queue_id', v_queue.id,
    'order_id', v_queue.order_id,
    'queue_no', v_queue.queue_no,
    'table_number', v_queue.table_number,
    'floor_label', v_queue.floor_label,
    'created_at', v_queue.created_at,
    'last_action_id', recent.action_id,
    'last_action_at', recent.created_at,
    'items', COALESCE((
      SELECT jsonb_agg(item_payload ORDER BY created_at, order_item_id, line_key)
      FROM (
        SELECT fulfillment.created_at, fulfillment.order_item_id,
          'base'::text AS line_key,
          jsonb_build_object(
            'id', fulfillment.id,
            'order_item_id', fulfillment.order_item_id,
            'line_key', 'base',
            'source_kind', 'order_item',
            'fulfillment_route', 'kitchen_tray_floor',
            'name_ko', COALESCE(NULLIF(item.label, ''),
              NULLIF(item.display_name, ''), menu.name_ko, menu.name, '메뉴'),
            'name_vi', COALESCE(NULLIF(menu.name_vi, ''),
              NULLIF(item.display_name, ''), menu.name, 'Món'),
            'name_en', COALESCE(NULLIF(menu.name_en, ''),
              NULLIF(item.display_name, ''), menu.name, 'Item'),
            'combo_components', COALESCE(item.combo_components, '[]'::jsonb),
            'ordered_quantity', fulfillment.ordered_quantity,
            'kitchen_done_quantity', fulfillment.kitchen_done_quantity,
            'tray_received_quantity', fulfillment.tray_received_quantity,
            'tray_dispatched_quantity', fulfillment.tray_dispatched_quantity,
            'floor_served_quantity', fulfillment.floor_served_quantity,
            'needs_review', fulfillment.needs_review
          ) AS item_payload
        FROM public.emergency_fulfillment_items fulfillment
        JOIN public.order_items item ON item.id = fulfillment.order_item_id
        LEFT JOIN public.menu_items menu ON menu.id = item.menu_item_id
        WHERE fulfillment.queue_id = v_queue.id
          AND fulfillment.is_cancelled = false
        UNION ALL
        SELECT direct.created_at, direct.order_item_id, direct.line_key,
          jsonb_build_object(
            'id', direct.id,
            'order_item_id', direct.order_item_id,
            'line_key', direct.line_key,
            'source_kind', direct.source_kind,
            'fulfillment_route', 'floor_direct',
            'name_ko', direct.name_ko,
            'name_vi', direct.name_vi,
            'name_en', direct.name_en,
            'combo_components', '[]'::jsonb,
            'ordered_quantity', direct.ordered_quantity,
            'kitchen_done_quantity', 0,
            'tray_received_quantity', 0,
            'tray_dispatched_quantity', 0,
            'floor_served_quantity', direct.floor_served_quantity,
            'needs_review', direct.needs_review
          ) AS item_payload
        FROM public.emergency_floor_direct_items direct
        WHERE direct.queue_id = v_queue.id
          AND direct.is_cancelled = false
      ) station_items
    ), '[]'::jsonb)
  ) INTO v_ticket
  FROM (SELECT 1) seed
  LEFT JOIN LATERAL (
    SELECT action.action_id, action.created_at
    FROM public.emergency_fulfillment_actions action
    WHERE action.queue_id = v_queue.id
      AND action.station_type = v_assignment.station_type
      AND action.action_kind = 'complete'
      AND NOT EXISTS (
        SELECT 1 FROM public.emergency_fulfillment_actions reversal
        WHERE reversal.original_action_id = action.action_id
          AND reversal.action_kind = 'revert'
      )
    ORDER BY action.created_at DESC, action.action_id DESC
    LIMIT 1
  ) recent ON true;

  v_orders := jsonb_build_array(v_ticket);
  v_orders := public.emergency_localize_paperless_orders(v_orders);
  v_orders := public.emergency_add_combo_component_progress(v_orders);
  v_orders := public.emergency_add_takeout_flags(v_orders);
  v_orders := public.emergency_add_order_batch_timings(v_orders);
  v_orders := public.emergency_add_order_sales_channels(
    v_orders, v_assignment.station_type
  );
  v_ticket := v_orders->0;
  IF v_ticket IS NULL THEN
    RETURN jsonb_build_object('ticket', NULL, 'revision', v_revision);
  END IF;

  SELECT
    CASE v_assignment.station_type
      WHEN 'kitchen' THEN v_queue.created_at
      WHEN 'tray' THEN event_times.previous_stage_at
      ELSE CASE WHEN EXISTS (
        SELECT 1 FROM public.emergency_floor_direct_items direct
        WHERE direct.queue_id = v_queue.id AND direct.is_cancelled = false
      ) THEN v_queue.created_at ELSE event_times.previous_stage_at END
    END,
    event_times.completed_at
  INTO v_started_at, v_completed_at
  FROM LATERAL (
    SELECT
      min(event.created_at) FILTER (
        WHERE event.stage = CASE v_assignment.station_type
          WHEN 'tray' THEN 'kitchen_done'
          WHEN 'floor' THEN 'tray_dispatched'
          ELSE 'order_received' END
      ) AS previous_stage_at,
      max(event.created_at) FILTER (
        WHERE event.stage = CASE v_assignment.station_type
          WHEN 'kitchen' THEN 'kitchen_done'
          WHEN 'tray' THEN 'tray_dispatched'
          ELSE 'floor_served' END
      ) AS completed_at
    FROM public.emergency_fulfillment_events event
    WHERE event.session_id = v_queue.session_id
      AND event.order_id = v_queue.order_id
      AND event.delta > 0
  ) event_times;
  v_ticket := v_ticket || jsonb_strip_nulls(jsonb_build_object(
    'station_started_at', v_started_at,
    'station_completed_at', v_completed_at
  ));
  RETURN jsonb_build_object('ticket', v_ticket, 'revision', v_revision);
END;
$$;

REVOKE ALL ON FUNCTION public.get_kds_ticket_v2(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_kds_ticket_v2(uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.observe_kds_shadow_v2(p_queue_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_config jsonb;
  v_snapshot jsonb;
  v_ticket_result jsonb;
  v_legacy_ticket jsonb;
  v_v2_ticket jsonb;
  v_timing jsonb;
  v_store_id uuid;
  v_station text;
  v_floor_key text;
  v_revision bigint;
  v_matches boolean;
  v_shadow_started_at timestamptz;
BEGIN
  IF p_queue_id IS NULL THEN RAISE EXCEPTION 'KDS_TICKET_INPUT_INVALID'; END IF;
  v_config := public.get_kds_sync_config();
  IF v_config->>'mode' <> 'shadow'
     OR COALESCE((v_config->>'assigned')::boolean, false) = false THEN
    RAISE EXCEPTION 'KDS_SHADOW_MODE_REQUIRED';
  END IF;
  v_store_id := (v_config->>'restaurant_id')::uuid;
  v_station := v_config->>'station_type';
  v_floor_key := COALESCE(v_config->>'floor_label', '');
  SELECT rollout.updated_at INTO v_shadow_started_at
  FROM public.kds_realtime_rollouts rollout
  WHERE rollout.restaurant_id = v_store_id
    AND rollout.mode = 'shadow';
  IF v_shadow_started_at IS NULL THEN
    RAISE EXCEPTION 'KDS_SHADOW_MODE_REQUIRED';
  END IF;

  v_snapshot := public.get_emergency_station_snapshot();
  SELECT order_row.raw INTO v_legacy_ticket
  FROM jsonb_array_elements(COALESCE(v_snapshot->'orders', '[]'::jsonb))
    order_row(raw)
  WHERE order_row.raw->>'queue_id' = p_queue_id::text;

  SELECT timing.raw INTO v_timing
  FROM jsonb_array_elements(public.get_emergency_station_timings()) timing(raw)
  WHERE timing.raw->>'queue_id' = p_queue_id::text;
  IF v_legacy_ticket IS NOT NULL AND v_timing IS NOT NULL THEN
    v_legacy_ticket := v_legacy_ticket
      || jsonb_strip_nulls(v_timing - 'queue_id');
  END IF;

  v_ticket_result := public.get_kds_ticket_v2(p_queue_id);
  v_v2_ticket := NULLIF(v_ticket_result->'ticket', 'null'::jsonb);
  v_revision := COALESCE((v_ticket_result->>'revision')::bigint, 0);
  v_matches := v_legacy_ticket IS NOT DISTINCT FROM v_v2_ticket;

  INSERT INTO public.kds_shadow_health (
    restaurant_id, station_type, floor_key, observation_count,
    mismatch_count, last_revision, last_match, last_mismatch_at,
    shadow_started_at, last_observed_at
  ) VALUES (
    v_store_id, v_station, v_floor_key, 1,
    CASE WHEN v_matches THEN 0 ELSE 1 END,
    v_revision, v_matches,
    CASE WHEN v_matches THEN NULL ELSE now() END,
    v_shadow_started_at, now()
  )
  ON CONFLICT (restaurant_id, station_type, floor_key) DO UPDATE SET
    observation_count = CASE
      WHEN public.kds_shadow_health.shadow_started_at
        = EXCLUDED.shadow_started_at
      THEN public.kds_shadow_health.observation_count + 1
      ELSE 1 END,
    mismatch_count = CASE
      WHEN public.kds_shadow_health.shadow_started_at
        = EXCLUDED.shadow_started_at
      THEN public.kds_shadow_health.mismatch_count
        + CASE WHEN EXCLUDED.last_match THEN 0 ELSE 1 END
      ELSE CASE WHEN EXCLUDED.last_match THEN 0 ELSE 1 END END,
    last_revision = EXCLUDED.last_revision,
    last_match = EXCLUDED.last_match,
    last_mismatch_at = CASE
      WHEN public.kds_shadow_health.shadow_started_at
        IS DISTINCT FROM EXCLUDED.shadow_started_at
      THEN EXCLUDED.last_mismatch_at
      WHEN EXCLUDED.last_match
      THEN public.kds_shadow_health.last_mismatch_at
      ELSE EXCLUDED.last_mismatch_at END,
    shadow_started_at = EXCLUDED.shadow_started_at,
    last_observed_at = EXCLUDED.last_observed_at;

  RETURN jsonb_build_object(
    'matches', v_matches,
    'revision', v_revision,
    'queue_id', p_queue_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.observe_kds_shadow_v2(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.observe_kds_shadow_v2(uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.get_kds_shadow_health(p_restaurant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_shadow_started_at timestamptz;
  v_stations jsonb;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'KDS_REALTIME_SUPER_ADMIN_REQUIRED';
  END IF;
  SELECT rollout.updated_at INTO v_shadow_started_at
  FROM public.kds_realtime_rollouts rollout
  WHERE rollout.restaurant_id = p_restaurant_id
    AND rollout.mode = 'shadow';

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'station_type', required_station.station_type,
    'floor_label', NULLIF(required_station.floor_key, ''),
    'observation_count', COALESCE(health.observation_count, 0),
    'mismatch_count', COALESCE(health.mismatch_count, 0),
    'last_revision', COALESCE(health.last_revision, 0),
    'last_match', health.last_match,
    'last_observed_at', health.last_observed_at,
    'ready', COALESCE(health.observation_count, 0) >= 10
      AND health.shadow_started_at = v_shadow_started_at
      AND COALESCE(health.mismatch_count, 0) = 0
  ) ORDER BY required_station.station_type, required_station.floor_key),
  '[]'::jsonb)
  INTO v_stations
  FROM (
    SELECT DISTINCT assignment.station_type,
      COALESCE(assignment.floor_label, '') AS floor_key
    FROM public.emergency_station_assignments assignment
    WHERE assignment.restaurant_id = p_restaurant_id
      AND assignment.is_active = true
  ) required_station
  LEFT JOIN public.kds_shadow_health health
    ON health.restaurant_id = p_restaurant_id
   AND health.station_type = required_station.station_type
   AND health.floor_key = required_station.floor_key;

  RETURN jsonb_build_object(
    'restaurant_id', p_restaurant_id,
    'shadow_started_at', v_shadow_started_at,
    'ready', jsonb_array_length(v_stations) > 0 AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_stations) station(raw)
      WHERE COALESCE((station.raw->>'ready')::boolean, false) = false
    ),
    'stations', v_stations
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_kds_shadow_health(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_kds_shadow_health(uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.kds_record_progress_v2(
  p_item_id uuid,
  p_stage text,
  p_delta integer,
  p_event_id uuid,
  p_source_kind text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_result jsonb;
  v_change public.kds_change_log%ROWTYPE;
BEGIN
  IF p_source_kind = 'floor_direct' THEN
    v_result := public.emergency_record_floor_direct_progress(
      p_item_id, p_delta, p_event_id
    );
  ELSIF p_source_kind = 'combo_component' THEN
    v_result := public.emergency_record_combo_component_progress(
      p_item_id, p_stage, p_delta, p_event_id
    );
  ELSE
    v_result := public.emergency_record_progress(
      p_item_id, p_stage, p_delta, p_event_id
    );
  END IF;
  SELECT change.* INTO v_change
  FROM public.kds_change_log change
  WHERE change.event_id = p_event_id;
  RETURN jsonb_build_object(
    'result', v_result,
    'change', CASE WHEN v_change.id IS NULL THEN NULL
      ELSE public.kds_change_envelope(v_change) END
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.kds_complete_order_v2(
  p_queue_id uuid,
  p_action_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_result jsonb;
  v_change public.kds_change_log%ROWTYPE;
BEGIN
  v_result := public.emergency_complete_route_order_stage(
    p_queue_id, p_action_id
  );
  SELECT change.* INTO v_change FROM public.kds_change_log change
  WHERE change.event_id = p_action_id;
  RETURN jsonb_build_object(
    'result', v_result,
    'change', CASE WHEN v_change.id IS NULL THEN NULL
      ELSE public.kds_change_envelope(v_change) END
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.kds_revert_order_v2(
  p_queue_id uuid,
  p_action_id uuid,
  p_revert_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_result jsonb;
  v_change public.kds_change_log%ROWTYPE;
BEGIN
  v_result := public.emergency_revert_route_order_action(
    p_queue_id, p_action_id, p_revert_id
  );
  SELECT change.* INTO v_change FROM public.kds_change_log change
  WHERE change.event_id = p_revert_id;
  RETURN jsonb_build_object(
    'result', v_result,
    'change', CASE WHEN v_change.id IS NULL THEN NULL
      ELSE public.kds_change_envelope(v_change) END
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.kds_advance_leftover_v2(
  p_request_id uuid,
  p_event_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_result jsonb;
  v_change public.kds_change_log%ROWTYPE;
BEGIN
  v_result := public.emergency_advance_leftover_packaging(
    p_request_id, p_event_id
  );
  SELECT change.* INTO v_change FROM public.kds_change_log change
  WHERE change.event_id = p_event_id;
  RETURN jsonb_build_object(
    'result', v_result,
    'change', CASE WHEN v_change.id IS NULL THEN NULL
      ELSE public.kds_change_envelope(v_change) END
  );
END;
$$;

REVOKE ALL ON FUNCTION public.kds_record_progress_v2(
  uuid, text, integer, uuid, text
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.kds_complete_order_v2(uuid, uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.kds_revert_order_v2(uuid, uuid, uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.kds_advance_leftover_v2(uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.kds_record_progress_v2(
  uuid, text, integer, uuid, text
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.kds_complete_order_v2(uuid, uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.kds_revert_order_v2(uuid, uuid, uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.kds_advance_leftover_v2(uuid, uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.set_kds_realtime_rollout(
  p_restaurant_id uuid,
  p_mode text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_previous_mode text := 'legacy';
  v_shadow_started_at timestamptz;
  v_session_id uuid;
  v_rollout_event_id uuid := gen_random_uuid();
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'KDS_REALTIME_SUPER_ADMIN_REQUIRED';
  END IF;
  IF p_restaurant_id IS NULL OR p_mode NOT IN ('legacy', 'shadow', 'active')
     OR NOT EXISTS (
       SELECT 1 FROM public.restaurants restaurant
       WHERE restaurant.id = p_restaurant_id AND restaurant.is_active = true
     ) THEN
    RAISE EXCEPTION 'KDS_REALTIME_ROLLOUT_INPUT_INVALID';
  END IF;
  SELECT * INTO v_actor FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  SELECT rollout.mode, rollout.updated_at
  INTO v_previous_mode, v_shadow_started_at
  FROM public.kds_realtime_rollouts rollout
  WHERE rollout.restaurant_id = p_restaurant_id;
  v_previous_mode := COALESCE(v_previous_mode, 'legacy');
  IF p_mode = 'active'
     AND v_previous_mode NOT IN ('shadow', 'active') THEN
    RAISE EXCEPTION 'KDS_REALTIME_SHADOW_REQUIRED';
  END IF;
  IF p_mode = 'active' AND v_previous_mode = 'shadow' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.emergency_station_assignments assignment
      WHERE assignment.restaurant_id = p_restaurant_id
        AND assignment.is_active = true
    ) OR EXISTS (
      SELECT 1
      FROM (
        SELECT DISTINCT assignment.station_type,
          COALESCE(assignment.floor_label, '') AS floor_key
        FROM public.emergency_station_assignments assignment
        WHERE assignment.restaurant_id = p_restaurant_id
          AND assignment.is_active = true
      ) required_station
      WHERE NOT EXISTS (
        SELECT 1 FROM public.kds_shadow_health health
        WHERE health.restaurant_id = p_restaurant_id
          AND health.station_type = required_station.station_type
          AND health.floor_key = required_station.floor_key
          AND health.observation_count >= 10
          AND health.shadow_started_at = v_shadow_started_at
          AND health.mismatch_count = 0
      )
    ) THEN
      RAISE EXCEPTION 'KDS_REALTIME_SHADOW_PARITY_REQUIRED';
    END IF;
  END IF;
  INSERT INTO public.kds_realtime_rollouts (
    restaurant_id, mode, updated_by, updated_at
  ) VALUES (p_restaurant_id, p_mode, v_actor.id, now())
  ON CONFLICT (restaurant_id) DO UPDATE SET
    mode = EXCLUDED.mode,
    updated_by = EXCLUDED.updated_by,
    updated_at = EXCLUDED.updated_at;
  IF p_mode IN ('shadow', 'active') THEN
    INSERT INTO public.kds_store_revisions (restaurant_id)
    VALUES (p_restaurant_id)
    ON CONFLICT (restaurant_id) DO NOTHING;
  END IF;
  IF v_previous_mode IS DISTINCT FROM p_mode
     AND (v_previous_mode IN ('shadow', 'active')
       OR p_mode IN ('shadow', 'active')) THEN
    SELECT session.id INTO v_session_id
    FROM public.emergency_fulfillment_sessions session
    WHERE session.restaurant_id = p_restaurant_id
      AND session.status = 'active';
    PERFORM public.kds_append_change(
      p_restaurant_id,
      v_session_id,
      v_rollout_event_id,
      'rollout_mode_changed',
      ARRAY['control']::text[],
      NULL,
      NULL,
      NULL,
      NULL,
      jsonb_build_object(
        'kind', 'bootstrap_required',
        'previous_mode', v_previous_mode,
        'mode', p_mode
      ),
      'rollout:' || v_rollout_event_id::text
    );
  END IF;
  RETURN jsonb_build_object(
    'restaurant_id', p_restaurant_id,
    'mode', p_mode,
    'updated_at', now()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.set_kds_realtime_rollout(uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_kds_realtime_rollout(uuid, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.prune_kds_change_log(
  p_before timestamptz DEFAULT now() - interval '7 days'
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_deleted bigint;
BEGIN
  DELETE FROM public.kds_change_log change
  WHERE change.created_at < p_before
    AND change.revision < (
      SELECT GREATEST(COALESCE(max(recent.revision), 0) - 1000, 0)
      FROM public.kds_change_log recent
      WHERE recent.restaurant_id = change.restaurant_id
    );
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.prune_kds_change_log(timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.prune_kds_change_log(timestamptz)
  TO service_role;

COMMENT ON TABLE public.kds_change_log IS
  'Durable, store-revisioned KDS transport log. It does not replace the fulfillment audit ledger.';
COMMENT ON TABLE public.kds_realtime_rollouts IS
  'Per-store KDS transport mode. Missing rows are legacy by design.';

DO $$
DECLARE
  v_rollout_count bigint;
BEGIN
  SELECT count(*) INTO v_rollout_count
  FROM public.kds_realtime_rollouts
  WHERE mode <> 'legacy';
  IF v_rollout_count <> 0 THEN
    RAISE EXCEPTION 'KDS_REALTIME_MIGRATION_MUST_NOT_AUTO_ACTIVATE';
  END IF;
  IF to_regclass('public.kds_change_log') IS NULL
     OR to_regclass('public.kds_store_revisions') IS NULL
     OR to_regclass('public.kds_shadow_health') IS NULL
     OR to_regprocedure('public.get_kds_changes_v2(bigint,integer)') IS NULL
     OR to_regprocedure('public.get_kds_ticket_v2(uuid)') IS NULL
     OR to_regprocedure('public.observe_kds_shadow_v2(uuid)') IS NULL
     OR to_regprocedure(
       'public.kds_record_progress_v2(uuid,text,integer,uuid,text)'
     ) IS NULL THEN
    RAISE EXCEPTION 'KDS_REALTIME_V2_VERIFICATION_FAILED';
  END IF;
  IF pg_catalog.has_function_privilege(
    'anon', 'public.get_kds_changes_v2(bigint,integer)', 'EXECUTE'
  ) OR NOT pg_catalog.has_function_privilege(
    'authenticated', 'public.get_kds_changes_v2(bigint,integer)', 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'KDS_REALTIME_V2_GRANT_VERIFICATION_FAILED';
  END IF;
END;
$$;

COMMIT;
