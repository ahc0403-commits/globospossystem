BEGIN;

CREATE OR REPLACE FUNCTION public.emergency_upsert_floor_direct_line(
  p_session_id uuid,
  p_restaurant_id uuid,
  p_queue_id uuid,
  p_order_id uuid,
  p_order_item_id uuid,
  p_line_key text,
  p_source_kind text,
  p_component_menu_item_id uuid,
  p_name_ko text,
  p_name_vi text,
  p_name_en text,
  p_source_quantity integer,
  p_is_cancelled boolean
) RETURNS TABLE(item_id uuid, added_quantity integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_existing public.emergency_floor_direct_items%ROWTYPE;
  v_next_ordered integer;
BEGIN
  IF p_source_quantity <= 0 OR p_line_key IS NULL OR btrim(p_line_key) = '' THEN
    RAISE EXCEPTION 'FLOOR_DIRECT_LINE_INVALID';
  END IF;
  SELECT * INTO v_existing
  FROM public.emergency_floor_direct_items item
  WHERE item.session_id = p_session_id
    AND item.order_item_id = p_order_item_id
    AND item.line_key = p_line_key
  FOR UPDATE;

  IF FOUND THEN
    v_next_ordered := GREATEST(
      p_source_quantity,
      v_existing.floor_served_quantity
    );
    item_id := v_existing.id;
    added_quantity := GREATEST(p_source_quantity - v_existing.source_quantity, 0);
    UPDATE public.emergency_floor_direct_items
    SET source_quantity = p_source_quantity,
        ordered_quantity = v_next_ordered,
        source_kind = p_source_kind,
        component_menu_item_id = p_component_menu_item_id,
        name_ko = p_name_ko,
        name_vi = p_name_vi,
        name_en = p_name_en,
        is_cancelled = p_is_cancelled,
        needs_review = p_source_quantity < floor_served_quantity,
        updated_at = now()
    WHERE id = v_existing.id;
  ELSE
    INSERT INTO public.emergency_floor_direct_items (
      session_id, restaurant_id, queue_id, order_id, order_item_id,
      line_key, source_kind, component_menu_item_id,
      name_ko, name_vi, name_en,
      source_quantity, ordered_quantity, is_cancelled
    ) VALUES (
      p_session_id, p_restaurant_id, p_queue_id, p_order_id, p_order_item_id,
      p_line_key, p_source_kind, p_component_menu_item_id,
      p_name_ko, p_name_vi, p_name_en,
      p_source_quantity, p_source_quantity, p_is_cancelled
    ) RETURNING id INTO item_id;
    added_quantity := p_source_quantity;
  END IF;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.emergency_upsert_floor_direct_line(
  uuid, uuid, uuid, uuid, uuid, text, text, uuid,
  text, text, text, integer, boolean
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.emergency_upsert_floor_direct_line(
  uuid, uuid, uuid, uuid, uuid, text, text, uuid,
  text, text, text, integer, boolean
) TO service_role;

CREATE OR REPLACE FUNCTION public.emergency_sync_order_item()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_session public.emergency_fulfillment_sessions%ROWTYPE;
  v_queue public.emergency_order_queue%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_table record;
  v_menu public.menu_items%ROWTYPE;
  v_existing public.emergency_fulfillment_items%ROWTYPE;
  v_component record;
  v_direct record;
  v_queue_created boolean := false;
  v_event_id uuid;
  v_added integer := 0;
  v_name_ko text;
  v_name_vi text;
  v_name_en text;
  v_component_quantity integer;
BEGIN
  IF NEW.fulfillment_mode_snapshot <> 'paperless' THEN RETURN NEW; END IF;

  SELECT * INTO v_session
  FROM public.emergency_fulfillment_sessions
  WHERE restaurant_id = NEW.restaurant_id AND status = 'active'
  FOR UPDATE;
  IF NOT FOUND THEN RETURN NEW; END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = NEW.order_id;
  IF NOT FOUND OR v_order.status IN ('completed', 'cancelled') THEN RETURN NEW; END IF;
  IF COALESCE(NEW.is_service_item, false)
     OR NEW.item_type IN ('wet_tissue_charge', 'buffet_cover_charge') THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_menu
  FROM public.menu_items
  WHERE id = NEW.menu_item_id AND restaurant_id = NEW.restaurant_id;
  v_name_ko := COALESCE(NULLIF(NEW.label, ''), NULLIF(NEW.display_name, ''),
    NULLIF(v_menu.name_ko, ''), NULLIF(v_menu.name, ''), '메뉴');
  v_name_vi := COALESCE(NULLIF(v_menu.name_vi, ''), NULLIF(NEW.display_name, ''),
    NULLIF(NEW.label, ''), NULLIF(v_menu.name, ''), 'Món');
  v_name_en := COALESCE(NULLIF(v_menu.name_en, ''), NULLIF(NEW.display_name, ''),
    NULLIF(NEW.label, ''), NULLIF(v_menu.name, ''), 'Item');

  SELECT table_number, floor_label INTO v_table
  FROM public.tables WHERE id = v_order.table_id;
  SELECT * INTO v_queue
  FROM public.emergency_order_queue
  WHERE session_id = v_session.id AND order_id = NEW.order_id;
  IF NOT FOUND THEN
    INSERT INTO public.emergency_order_queue (
      session_id, restaurant_id, order_id, queue_no, table_number, floor_label
    ) VALUES (
      v_session.id, NEW.restaurant_id, NEW.order_id,
      COALESCE((SELECT max(queue_no) + 1
        FROM public.emergency_order_queue WHERE session_id = v_session.id), 1),
      COALESCE(v_table.table_number, 'STAFF'),
      public.emergency_floor_label(
        NEW.restaurant_id, v_table.floor_label, v_table.table_number
      )
    ) RETURNING * INTO v_queue;
    v_queue_created := true;
    INSERT INTO public.emergency_fulfillment_events (
      event_id, session_id, restaurant_id, order_id, stage, delta, details
    ) VALUES (
      gen_random_uuid(), v_session.id, NEW.restaurant_id, NEW.order_id,
      'order_received', 1, jsonb_build_object(
        'queue_no', v_queue.queue_no,
        'fulfillment_mode', 'paperless',
        'event_scope', 'queue'
      )
    );
  END IF;

  -- A combo parent remains the existing food preparation line. A normal
  -- floor-direct beverage is stored only in the additive direct ledger.
  IF COALESCE(v_menu.is_combo, false)
     OR NEW.fulfillment_route_snapshot <> 'floor_direct' THEN
    SELECT * INTO v_existing
    FROM public.emergency_fulfillment_items
    WHERE session_id = v_session.id AND order_item_id = NEW.id
    FOR UPDATE;
    IF FOUND THEN
      v_added := GREATEST(NEW.quantity - v_existing.source_quantity, 0);
      UPDATE public.emergency_fulfillment_items
      SET source_quantity = NEW.quantity,
          ordered_quantity = GREATEST(
            NEW.quantity, kitchen_done_quantity, tray_received_quantity,
            tray_dispatched_quantity, floor_served_quantity
          ),
          is_cancelled = NEW.status = 'cancelled',
          needs_review = NEW.quantity < GREATEST(
            kitchen_done_quantity, tray_received_quantity,
            tray_dispatched_quantity, floor_served_quantity
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
      ) RETURNING * INTO v_existing;
      v_added := NEW.quantity;
    END IF;
    IF v_added > 0 AND NEW.status <> 'cancelled' THEN
      v_event_id := gen_random_uuid();
      INSERT INTO public.emergency_fulfillment_events (
        event_id, session_id, restaurant_id, order_id, order_item_id,
        stage, delta, details
      ) VALUES (
        v_event_id, v_session.id, NEW.restaurant_id, NEW.order_id, NEW.id,
        'order_received', v_added, jsonb_build_object(
          'event_scope', 'line',
          'fulfillment_route', 'kitchen_tray_floor',
          'line_key', 'base'
        )
      );
      PERFORM public.emergency_enqueue_push(
        v_event_id, NEW.restaurant_id, NEW.order_id,
        'kitchen', v_queue.floor_label, 'order_received'
      );
    END IF;
  ELSE
    SELECT * INTO v_direct
    FROM public.emergency_upsert_floor_direct_line(
      v_session.id, NEW.restaurant_id, v_queue.id, NEW.order_id, NEW.id,
      'base', 'order_item', NEW.menu_item_id,
      v_name_ko, v_name_vi, v_name_en,
      NEW.quantity, NEW.status = 'cancelled'
    );
    IF v_direct.added_quantity > 0 AND NEW.status <> 'cancelled' THEN
      v_event_id := gen_random_uuid();
      INSERT INTO public.emergency_fulfillment_events (
        event_id, session_id, restaurant_id, order_id, order_item_id,
        floor_direct_item_id, stage, delta, details
      ) VALUES (
        v_event_id, v_session.id, NEW.restaurant_id, NEW.order_id, NEW.id,
        v_direct.item_id, 'floor_direct_ready', v_direct.added_quantity,
        jsonb_build_object(
          'event_scope', 'line', 'fulfillment_route', 'floor_direct',
          'line_key', 'base'
        )
      );
      PERFORM public.emergency_enqueue_push(
        v_event_id, NEW.restaurant_id, NEW.order_id,
        'floor', v_queue.floor_label, 'floor_direct_ready'
      );
    END IF;
  END IF;

  -- Rebuild only this parent item's direct component membership. Existing
  -- progress is retained and quantity reductions become needs_review.
  UPDATE public.emergency_floor_direct_items
  SET is_cancelled = true, updated_at = now()
  WHERE session_id = v_session.id
    AND order_item_id = NEW.id
    AND source_kind = 'combo_component';

  FOR v_component IN
    SELECT component.raw
    FROM jsonb_array_elements(COALESCE(NEW.combo_components, '[]'::jsonb))
      component(raw)
    WHERE component.raw->>'fulfillment_route' = 'floor_direct'
      AND COALESCE((component.raw->>'quantity')::integer, 0) > 0
      AND COALESCE(component.raw->>'menu_item_id', '') <> ''
  LOOP
    v_component_quantity := CASE
      WHEN COALESCE((v_component.raw->>'is_total_quantity')::boolean, false)
        THEN (v_component.raw->>'quantity')::integer
      ELSE (v_component.raw->>'quantity')::integer * NEW.quantity
    END;
    SELECT * INTO v_direct
    FROM public.emergency_upsert_floor_direct_line(
      v_session.id, NEW.restaurant_id, v_queue.id, NEW.order_id, NEW.id,
      'combo:' || (v_component.raw->>'menu_item_id'),
      'combo_component', (v_component.raw->>'menu_item_id')::uuid,
      COALESCE(NULLIF(v_component.raw->>'name_ko', ''),
        NULLIF(v_component.raw->>'label', ''), '음료'),
      COALESCE(NULLIF(v_component.raw->>'name_vi', ''),
        NULLIF(v_component.raw->>'label', ''), 'Đồ uống'),
      COALESCE(NULLIF(v_component.raw->>'name_en', ''),
        NULLIF(v_component.raw->>'label', ''), 'Drink'),
      v_component_quantity, NEW.status = 'cancelled'
    );
    IF v_direct.added_quantity > 0 AND NEW.status <> 'cancelled' THEN
      v_event_id := gen_random_uuid();
      INSERT INTO public.emergency_fulfillment_events (
        event_id, session_id, restaurant_id, order_id, order_item_id,
        floor_direct_item_id, stage, delta, details
      ) VALUES (
        v_event_id, v_session.id, NEW.restaurant_id, NEW.order_id, NEW.id,
        v_direct.item_id, 'floor_direct_ready', v_direct.added_quantity,
        jsonb_build_object(
          'event_scope', 'line', 'fulfillment_route', 'floor_direct',
          'line_key', 'combo:' || (v_component.raw->>'menu_item_id')
        )
      );
      PERFORM public.emergency_enqueue_push(
        v_event_id, NEW.restaurant_id, NEW.order_id,
        'floor', v_queue.floor_label, 'floor_direct_ready'
      );
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS emergency_sync_order_item_trigger ON public.order_items;
CREATE TRIGGER emergency_sync_order_item_trigger
AFTER INSERT OR UPDATE OF quantity, status, combo_components,
  fulfillment_route_snapshot
ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.emergency_sync_order_item();

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime'
  ) AND NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'emergency_floor_direct_items'
  ) THEN
    ALTER PUBLICATION supabase_realtime
      ADD TABLE public.emergency_floor_direct_items;
  END IF;
END;
$$;

COMMIT;
