BEGIN;

-- production-gate: self-verifying

-- A combo is one commercial order line, but every prepared component is an
-- independent operational line in the kitchen/tray/floor KDS.
CREATE TABLE public.emergency_combo_component_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL
    REFERENCES public.emergency_fulfillment_sessions(id) ON DELETE CASCADE,
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  queue_id uuid NOT NULL
    REFERENCES public.emergency_order_queue(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  order_item_id uuid NOT NULL
    REFERENCES public.order_items(id) ON DELETE CASCADE,
  line_key text NOT NULL,
  component_menu_item_id uuid
    REFERENCES public.menu_items(id) ON DELETE SET NULL,
  name_ko text NOT NULL,
  name_vi text NOT NULL,
  name_en text NOT NULL,
  source_quantity integer NOT NULL CHECK (source_quantity > 0),
  ordered_quantity integer NOT NULL CHECK (ordered_quantity > 0),
  kitchen_done_quantity integer NOT NULL DEFAULT 0,
  tray_received_quantity integer NOT NULL DEFAULT 0,
  tray_dispatched_quantity integer NOT NULL DEFAULT 0,
  floor_served_quantity integer NOT NULL DEFAULT 0,
  is_cancelled boolean NOT NULL DEFAULT false,
  needs_review boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (session_id, order_item_id, line_key),
  CONSTRAINT emergency_combo_component_line_key_present
    CHECK (btrim(line_key) <> ''),
  CONSTRAINT emergency_combo_component_quantity_chain CHECK (
    floor_served_quantity >= 0
    AND floor_served_quantity <= tray_dispatched_quantity
    AND tray_dispatched_quantity <= tray_received_quantity
    AND tray_received_quantity <= kitchen_done_quantity
    AND kitchen_done_quantity <= ordered_quantity
  )
);

CREATE INDEX emergency_combo_component_order
  ON public.emergency_combo_component_items (session_id, order_id, queue_id);
CREATE INDEX emergency_combo_component_store_open
  ON public.emergency_combo_component_items (restaurant_id, created_at)
  WHERE is_cancelled = false;

ALTER TABLE public.emergency_combo_component_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY emergency_combo_component_store_read
ON public.emergency_combo_component_items
FOR SELECT TO authenticated
USING (public.is_super_admin() OR EXISTS (
  SELECT 1
  FROM public.user_accessible_stores((SELECT auth.uid())) scope(store_id)
  WHERE scope.store_id = restaurant_id
));

REVOKE ALL ON public.emergency_combo_component_items
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.emergency_combo_component_items TO authenticated;
GRANT ALL ON public.emergency_combo_component_items TO service_role;

ALTER TABLE public.emergency_fulfillment_events
  ADD COLUMN combo_component_item_id uuid
  REFERENCES public.emergency_combo_component_items(id) ON DELETE SET NULL;
CREATE INDEX emergency_events_combo_component_created
  ON public.emergency_fulfillment_events (combo_component_item_id, created_at)
  WHERE combo_component_item_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.emergency_sync_combo_component_items()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_session public.emergency_fulfillment_sessions%ROWTYPE;
  v_queue public.emergency_order_queue%ROWTYPE;
  v_component record;
  v_existing public.emergency_combo_component_items%ROWTYPE;
  v_quantity integer;
BEGIN
  IF NEW.fulfillment_mode_snapshot <> 'paperless' THEN RETURN NEW; END IF;

  SELECT * INTO v_session
  FROM public.emergency_fulfillment_sessions
  WHERE restaurant_id = NEW.restaurant_id AND status = 'active';
  IF NOT FOUND THEN RETURN NEW; END IF;

  SELECT * INTO v_queue
  FROM public.emergency_order_queue
  WHERE session_id = v_session.id AND order_id = NEW.order_id;
  IF NOT FOUND THEN RETURN NEW; END IF;

  UPDATE public.emergency_combo_component_items
  SET is_cancelled = true, updated_at = now()
  WHERE session_id = v_session.id AND order_item_id = NEW.id;

  IF NEW.status = 'cancelled' THEN RETURN NEW; END IF;

  FOR v_component IN
    SELECT component.raw
    FROM jsonb_array_elements(COALESCE(NEW.combo_components, '[]'::jsonb))
      component(raw)
    WHERE COALESCE(component.raw->>'fulfillment_route',
      'kitchen_tray_floor') <> 'floor_direct'
      AND COALESCE((component.raw->>'quantity')::integer, 0) > 0
      AND COALESCE(component.raw->>'menu_item_id', '') <> ''
  LOOP
    v_quantity := CASE
      WHEN COALESCE((v_component.raw->>'is_total_quantity')::boolean, false)
        THEN (v_component.raw->>'quantity')::integer
      ELSE (v_component.raw->>'quantity')::integer * NEW.quantity
    END;

    SELECT * INTO v_existing
    FROM public.emergency_combo_component_items component
    WHERE component.session_id = v_session.id
      AND component.order_item_id = NEW.id
      AND component.line_key =
        'combo:' || (v_component.raw->>'menu_item_id')
    FOR UPDATE;

    IF FOUND THEN
      UPDATE public.emergency_combo_component_items
      SET component_menu_item_id =
            (v_component.raw->>'menu_item_id')::uuid,
          name_ko = COALESCE(NULLIF(v_component.raw->>'name_ko', ''),
            NULLIF(v_component.raw->>'label', ''), '메뉴'),
          name_vi = COALESCE(NULLIF(v_component.raw->>'name_vi', ''),
            NULLIF(v_component.raw->>'label', ''), 'Món'),
          name_en = COALESCE(NULLIF(v_component.raw->>'name_en', ''),
            NULLIF(v_component.raw->>'label', ''), 'Item'),
          source_quantity = v_quantity,
          ordered_quantity = GREATEST(
            v_quantity, kitchen_done_quantity, tray_received_quantity,
            tray_dispatched_quantity, floor_served_quantity
          ),
          is_cancelled = false,
          needs_review = v_quantity < GREATEST(
            kitchen_done_quantity, tray_received_quantity,
            tray_dispatched_quantity, floor_served_quantity
          ),
          updated_at = now()
      WHERE id = v_existing.id;
    ELSE
      INSERT INTO public.emergency_combo_component_items (
        session_id, restaurant_id, queue_id, order_id, order_item_id,
        line_key, component_menu_item_id, name_ko, name_vi, name_en,
        source_quantity, ordered_quantity
      ) VALUES (
        v_session.id, NEW.restaurant_id, v_queue.id, NEW.order_id, NEW.id,
        'combo:' || (v_component.raw->>'menu_item_id'),
        (v_component.raw->>'menu_item_id')::uuid,
        COALESCE(NULLIF(v_component.raw->>'name_ko', ''),
          NULLIF(v_component.raw->>'label', ''), '메뉴'),
        COALESCE(NULLIF(v_component.raw->>'name_vi', ''),
          NULLIF(v_component.raw->>'label', ''), 'Món'),
        COALESCE(NULLIF(v_component.raw->>'name_en', ''),
          NULLIF(v_component.raw->>'label', ''), 'Item'),
        v_quantity, v_quantity
      );
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.emergency_sync_combo_component_items()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.emergency_sync_combo_component_items()
  TO service_role;

DROP TRIGGER IF EXISTS zz_emergency_sync_combo_component_items_trigger
  ON public.order_items;
CREATE TRIGGER zz_emergency_sync_combo_component_items_trigger
AFTER INSERT OR UPDATE OF quantity, status, combo_components,
  fulfillment_route_snapshot
ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.emergency_sync_combo_component_items();

-- Preserve the current operational position for orders already open when the
-- migration is installed. Parent progress is projected onto every component.
INSERT INTO public.emergency_combo_component_items (
  session_id, restaurant_id, queue_id, order_id, order_item_id,
  line_key, component_menu_item_id, name_ko, name_vi, name_en,
  source_quantity, ordered_quantity,
  kitchen_done_quantity, tray_received_quantity,
  tray_dispatched_quantity, floor_served_quantity,
  is_cancelled, needs_review
)
SELECT
  fulfillment.session_id,
  fulfillment.restaurant_id,
  fulfillment.queue_id,
  fulfillment.order_id,
  fulfillment.order_item_id,
  'combo:' || (component.raw->>'menu_item_id'),
  (component.raw->>'menu_item_id')::uuid,
  COALESCE(NULLIF(component.raw->>'name_ko', ''),
    NULLIF(component.raw->>'label', ''), '메뉴'),
  COALESCE(NULLIF(component.raw->>'name_vi', ''),
    NULLIF(component.raw->>'label', ''), 'Món'),
  COALESCE(NULLIF(component.raw->>'name_en', ''),
    NULLIF(component.raw->>'label', ''), 'Item'),
  quantities.component_quantity,
  GREATEST(
    quantities.component_quantity,
    progress.kitchen_done_quantity,
    progress.tray_received_quantity,
    progress.tray_dispatched_quantity,
    progress.floor_served_quantity
  ),
  progress.kitchen_done_quantity,
  progress.tray_received_quantity,
  progress.tray_dispatched_quantity,
  progress.floor_served_quantity,
  fulfillment.is_cancelled,
  fulfillment.needs_review OR quantities.component_quantity < GREATEST(
    progress.kitchen_done_quantity,
    progress.tray_received_quantity,
    progress.tray_dispatched_quantity,
    progress.floor_served_quantity
  )
FROM public.emergency_fulfillment_items fulfillment
JOIN public.order_items order_item ON order_item.id = fulfillment.order_item_id
CROSS JOIN LATERAL (
  SELECT
    raw,
    (raw->>'quantity')::integer AS quantity,
    COALESCE((raw->>'is_total_quantity')::boolean, false) AS is_total
  FROM jsonb_array_elements(
    COALESCE(order_item.combo_components, '[]'::jsonb)
  ) entry(raw)
  WHERE COALESCE(raw->>'fulfillment_route', 'kitchen_tray_floor')
      <> 'floor_direct'
    AND COALESCE((raw->>'quantity')::integer, 0) > 0
    AND COALESCE(raw->>'menu_item_id', '') <> ''
) component
CROSS JOIN LATERAL (
  SELECT CASE WHEN component.is_total
    THEN component.quantity
    ELSE component.quantity * fulfillment.source_quantity
  END AS component_quantity
) quantities
CROSS JOIN LATERAL (
  SELECT
    CASE WHEN component.is_total THEN
      quantities.component_quantity * fulfillment.kitchen_done_quantity
        / fulfillment.ordered_quantity
    ELSE component.quantity * fulfillment.kitchen_done_quantity END
      AS kitchen_done_quantity,
    CASE WHEN component.is_total THEN
      quantities.component_quantity * fulfillment.tray_received_quantity
        / fulfillment.ordered_quantity
    ELSE component.quantity * fulfillment.tray_received_quantity END
      AS tray_received_quantity,
    CASE WHEN component.is_total THEN
      quantities.component_quantity * fulfillment.tray_dispatched_quantity
        / fulfillment.ordered_quantity
    ELSE component.quantity * fulfillment.tray_dispatched_quantity END
      AS tray_dispatched_quantity,
    CASE WHEN component.is_total THEN
      quantities.component_quantity * fulfillment.floor_served_quantity
        / fulfillment.ordered_quantity
    ELSE component.quantity * fulfillment.floor_served_quantity END
      AS floor_served_quantity
) progress
JOIN public.emergency_fulfillment_sessions session
  ON session.id = fulfillment.session_id AND session.status = 'active'
ON CONFLICT (session_id, order_item_id, line_key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.emergency_record_combo_component_progress(
  p_component_item_id uuid,
  p_stage text,
  p_delta integer,
  p_event_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_item public.emergency_combo_component_items%ROWTYPE;
  v_parent public.emergency_fulfillment_items%ROWTYPE;
  v_queue public.emergency_order_queue%ROWTYPE;
  v_kitchen integer;
  v_received integer;
  v_dispatched integer;
  v_served integer;
  v_parent_stage integer;
  v_target text;
BEGIN
  IF p_event_id IS NULL OR p_delta NOT IN (-1, 1) THEN
    RAISE EXCEPTION 'EMERGENCY_PROGRESS_INPUT_INVALID';
  END IF;
  SELECT * INTO v_user FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;
  SELECT * INTO v_assignment
  FROM public.emergency_station_assignments
  WHERE user_id = v_user.id
    AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_STATION_REQUIRED'; END IF;

  SELECT * INTO v_item
  FROM public.emergency_combo_component_items
  WHERE id = p_component_item_id
  FOR UPDATE;
  IF NOT FOUND OR v_item.restaurant_id <> v_assignment.restaurant_id
     OR v_item.is_cancelled THEN
    RAISE EXCEPTION 'EMERGENCY_ITEM_UNAVAILABLE';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_sessions
    WHERE id = v_item.session_id AND status = 'active'
  ) THEN RAISE EXCEPTION 'EMERGENCY_SESSION_NOT_ACTIVE'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_events
    WHERE event_id = p_event_id
  ) THEN
    RETURN jsonb_build_object('event_id', p_event_id, 'deduplicated', true);
  END IF;

  SELECT * INTO v_queue
  FROM public.emergency_order_queue WHERE id = v_item.queue_id;
  IF (p_stage = 'kitchen_done' AND v_assignment.station_type <> 'kitchen')
     OR (p_stage IN ('tray_received', 'tray_dispatched')
       AND v_assignment.station_type <> 'tray')
     OR (p_stage = 'floor_served' AND (
       v_assignment.station_type <> 'floor'
       OR v_assignment.floor_label <> v_queue.floor_label))
     OR p_stage NOT IN (
       'kitchen_done', 'tray_received', 'tray_dispatched', 'floor_served'
     ) THEN RAISE EXCEPTION 'EMERGENCY_STAGE_FORBIDDEN'; END IF;

  v_kitchen := v_item.kitchen_done_quantity
    + CASE WHEN p_stage = 'kitchen_done' THEN p_delta ELSE 0 END;
  v_received := v_item.tray_received_quantity
    + CASE WHEN p_stage = 'tray_received' THEN p_delta ELSE 0 END;
  v_dispatched := v_item.tray_dispatched_quantity
    + CASE WHEN p_stage = 'tray_dispatched' THEN p_delta ELSE 0 END;
  v_served := v_item.floor_served_quantity
    + CASE WHEN p_stage = 'floor_served' THEN p_delta ELSE 0 END;
  IF v_served < 0 OR v_served > v_dispatched
     OR v_dispatched < v_served OR v_dispatched > v_received
     OR v_received < v_dispatched OR v_received > v_kitchen
     OR v_kitchen < v_received OR v_kitchen > v_item.ordered_quantity THEN
    RAISE EXCEPTION 'EMERGENCY_QUANTITY_CHAIN_VIOLATION';
  END IF;

  UPDATE public.emergency_combo_component_items
  SET kitchen_done_quantity = v_kitchen,
      tray_received_quantity = v_received,
      tray_dispatched_quantity = v_dispatched,
      floor_served_quantity = v_served,
      updated_at = now()
  WHERE id = v_item.id;

  SELECT * INTO v_parent
  FROM public.emergency_fulfillment_items
  WHERE session_id = v_item.session_id
    AND order_item_id = v_item.order_item_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_PARENT_ITEM_UNAVAILABLE'; END IF;

  SELECT COALESCE(min(
    CASE p_stage
      WHEN 'kitchen_done' THEN component.kitchen_done_quantity
      WHEN 'tray_received' THEN component.tray_received_quantity
      WHEN 'tray_dispatched' THEN component.tray_dispatched_quantity
      ELSE component.floor_served_quantity
    END * v_parent.ordered_quantity / component.ordered_quantity
  ), 0)::integer
  INTO v_parent_stage
  FROM public.emergency_combo_component_items component
  WHERE component.session_id = v_item.session_id
    AND component.order_item_id = v_item.order_item_id
    AND component.is_cancelled = false;

  UPDATE public.emergency_fulfillment_items
  SET kitchen_done_quantity = CASE WHEN p_stage = 'kitchen_done'
        THEN v_parent_stage ELSE kitchen_done_quantity END,
      tray_received_quantity = CASE WHEN p_stage = 'tray_received'
        THEN v_parent_stage ELSE tray_received_quantity END,
      tray_dispatched_quantity = CASE WHEN p_stage = 'tray_dispatched'
        THEN v_parent_stage ELSE tray_dispatched_quantity END,
      floor_served_quantity = CASE WHEN p_stage = 'floor_served'
        THEN v_parent_stage ELSE floor_served_quantity END,
      updated_at = now()
  WHERE id = v_parent.id;

  INSERT INTO public.emergency_fulfillment_events (
    event_id, session_id, restaurant_id, order_id, order_item_id,
    combo_component_item_id, stage, delta, actor_user_id, details
  ) VALUES (
    p_event_id, v_item.session_id, v_item.restaurant_id, v_item.order_id,
    v_item.order_item_id, v_item.id, p_stage, p_delta, v_user.id,
    jsonb_build_object(
      'event_scope', 'combo_component', 'line_key', v_item.line_key
    )
  );

  IF p_delta > 0 AND p_stage = 'kitchen_done' THEN v_target := 'tray'; END IF;
  IF p_delta > 0 AND p_stage = 'tray_dispatched' THEN v_target := 'floor'; END IF;
  IF v_target IS NOT NULL THEN
    PERFORM public.emergency_enqueue_push(
      p_event_id, v_item.restaurant_id, v_item.order_id,
      v_target, v_queue.floor_label, p_stage
    );
  END IF;

  RETURN jsonb_build_object(
    'event_id', p_event_id, 'deduplicated', false,
    'kitchen_done_quantity', v_kitchen,
    'tray_received_quantity', v_received,
    'tray_dispatched_quantity', v_dispatched,
    'floor_served_quantity', v_served
  );
END;
$$;

REVOKE ALL ON FUNCTION public.emergency_record_combo_component_progress(
  uuid, text, integer, uuid
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.emergency_record_combo_component_progress(
  uuid, text, integer, uuid
) TO authenticated;

-- Append the independent component ledgers to the existing snapshot payload.
-- The combo parent remains in the payload only as immutable display metadata.
CREATE OR REPLACE FUNCTION public.emergency_add_combo_component_progress(
  p_orders jsonb
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_result jsonb := '[]'::jsonb;
  v_order jsonb;
  v_items jsonb;
  v_component record;
BEGIN
  IF COALESCE(jsonb_typeof(p_orders), 'null') <> 'array' THEN
    RETURN '[]'::jsonb;
  END IF;

  FOR v_order IN SELECT value FROM jsonb_array_elements(p_orders)
  LOOP
    v_items := COALESCE(v_order -> 'items', '[]'::jsonb);
    FOR v_component IN
      SELECT component.*, menu.paperless_name_vi
      FROM public.emergency_combo_component_items component
      LEFT JOIN public.menu_items menu
        ON menu.id = component.component_menu_item_id
      WHERE component.queue_id = (v_order->>'queue_id')::uuid
        AND component.is_cancelled = false
      ORDER BY component.created_at, component.order_item_id,
        component.line_key
    LOOP
      v_items := v_items || jsonb_build_array(jsonb_build_object(
        'id', v_component.id,
        'order_item_id', v_component.order_item_id,
        'line_key', v_component.line_key,
        'source_kind', 'combo_component',
        'fulfillment_route', 'kitchen_tray_floor',
        'name_ko', v_component.name_ko,
        'name_vi', COALESCE(NULLIF(btrim(v_component.paperless_name_vi), ''),
          v_component.name_vi, 'Món'),
        'name_en', v_component.name_en,
        'combo_components', '[]'::jsonb,
        'ordered_quantity', v_component.ordered_quantity,
        'kitchen_done_quantity', v_component.kitchen_done_quantity,
        'tray_received_quantity', v_component.tray_received_quantity,
        'tray_dispatched_quantity', v_component.tray_dispatched_quantity,
        'floor_served_quantity', v_component.floor_served_quantity,
        'needs_review', v_component.needs_review
      ));
    END LOOP;
    v_order := jsonb_set(v_order, '{items}', v_items, true);
    v_result := v_result || jsonb_build_array(v_order);
  END LOOP;
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.emergency_add_combo_component_progress(jsonb)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_emergency_station_snapshot()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_payload jsonb;
BEGIN
  v_payload := public.get_emergency_station_snapshot_base();
  IF jsonb_typeof(v_payload) = 'object' AND v_payload ? 'orders' THEN
    v_payload := jsonb_set(
      v_payload,
      '{orders}',
      public.emergency_add_combo_component_progress(
        public.emergency_localize_paperless_orders(v_payload -> 'orders')
      ),
      true
    );
  END IF;
  RETURN v_payload;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_emergency_station_today_completed()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
  RETURN public.emergency_add_combo_component_progress(
    public.emergency_localize_paperless_orders(
      public.get_emergency_station_today_completed_base()
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_emergency_station_snapshot()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_snapshot()
  TO authenticated;
REVOKE ALL ON FUNCTION public.get_emergency_station_today_completed()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_today_completed()
  TO authenticated;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime'
  ) AND NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'emergency_combo_component_items'
  ) THEN
    ALTER PUBLICATION supabase_realtime
      ADD TABLE public.emergency_combo_component_items;
  END IF;
END;
$$;

DO $$
DECLARE
  v_snapshot_definition text;
  v_progress_definition text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'emergency_combo_component_items'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'emergency_fulfillment_events'
      AND column_name = 'combo_component_item_id'
  ) THEN
    RAISE EXCEPTION 'KDS_COMBO_COMPONENT_SCHEMA_VERIFICATION_FAILED';
  END IF;

  SELECT pg_catalog.pg_get_functiondef(
    'public.get_emergency_station_snapshot()'::regprocedure
  ) INTO v_snapshot_definition;
  IF v_snapshot_definition NOT LIKE
      '%emergency_add_combo_component_progress%' THEN
    RAISE EXCEPTION 'KDS_COMBO_COMPONENT_SNAPSHOT_VERIFICATION_FAILED';
  END IF;

  SELECT pg_catalog.pg_get_functiondef(
    'public.emergency_record_combo_component_progress(uuid,text,integer,uuid)'
      ::regprocedure
  ) INTO v_progress_definition;
  IF v_progress_definition NOT LIKE '%combo_component_item_id%'
     OR v_progress_definition NOT LIKE '%v_parent_stage%' THEN
    RAISE EXCEPTION 'KDS_COMBO_COMPONENT_PROGRESS_VERIFICATION_FAILED';
  END IF;

  IF NOT pg_catalog.has_function_privilege(
    'authenticated',
    'public.emergency_record_combo_component_progress(uuid,text,integer,uuid)',
    'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'anon',
    'public.emergency_record_combo_component_progress(uuid,text,integer,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'KDS_COMBO_COMPONENT_GRANT_VERIFICATION_FAILED';
  END IF;
END;
$$;

COMMIT;
