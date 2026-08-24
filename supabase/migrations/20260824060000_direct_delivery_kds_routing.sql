-- Route paperless delivery orders through kitchen and tray only, expose their
-- channel to KDS clients, and keep the customer/till delivery status aligned.
-- production-gate: self-verifying

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.direct_delivery_fulfillment_tickets') IS NULL
     OR to_regclass('public.emergency_fulfillment_events') IS NULL
     OR to_regprocedure('public.get_emergency_station_snapshot()') IS NULL
     OR to_regprocedure('public.get_emergency_station_today_completed()') IS NULL THEN
    RAISE EXCEPTION 'KDS_DIRECT_DELIVERY_ROUTING_PREREQUISITE_MISSING';
  END IF;
END
$$;

-- Delivery beverages follow the same kitchen -> tray route as delivery food.
CREATE OR REPLACE FUNCTION public.capture_order_item_fulfillment_mode()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_direct_enabled boolean := false;
  v_sales_channel text := 'dine_in';
BEGIN
  PERFORM pg_advisory_xact_lock(
    hashtextextended('fulfillment-mode:' || NEW.restaurant_id::text, 0)
  );
  NEW.fulfillment_mode_snapshot :=
    public.get_store_fulfillment_mode(NEW.restaurant_id);

  SELECT COALESCE(order_row.sales_channel, 'dine_in')
  INTO v_sales_channel
  FROM public.orders order_row
  WHERE order_row.id = NEW.order_id;

  SELECT COALESCE(settings.floor_direct_beverages_enabled, false)
  INTO v_direct_enabled
  FROM public.restaurant_settings settings
  WHERE settings.restaurant_id = NEW.restaurant_id;

  IF v_sales_channel = 'delivery' THEN
    NEW.fulfillment_route_snapshot := 'kitchen_tray_floor';
  ELSIF NEW.fulfillment_mode_snapshot = 'paperless'
     AND v_direct_enabled
     AND NEW.menu_item_id IS NOT NULL THEN
    SELECT COALESCE(item.fulfillment_route, 'kitchen_tray_floor')
    INTO NEW.fulfillment_route_snapshot
    FROM public.menu_items item
    WHERE item.id = NEW.menu_item_id
      AND item.restaurant_id = NEW.restaurant_id;
  ELSE
    NEW.fulfillment_route_snapshot := 'kitchen_tray_floor';
  END IF;
  RETURN NEW;
END;
$$;

-- Combo drink components must follow the same delivery override.
DO $migration$
DECLARE
  v_definition text;
  v_old constant text := $old$
  SELECT COALESCE(settings.floor_direct_beverages_enabled, false)
  INTO v_direct_enabled
  FROM public.restaurant_settings settings
  WHERE settings.restaurant_id = NEW.restaurant_id;
$old$;
  v_new constant text := $new$
  SELECT COALESCE(settings.floor_direct_beverages_enabled, false)
  INTO v_direct_enabled
  FROM public.restaurant_settings settings
  WHERE settings.restaurant_id = NEW.restaurant_id;

  IF EXISTS (
    SELECT 1 FROM public.orders order_row
    WHERE order_row.id = NEW.order_id
      AND order_row.sales_channel = 'delivery'
  ) THEN
    v_direct_enabled := false;
  END IF;
$new$;
BEGIN
  SELECT pg_get_functiondef(
    'public.snapshot_order_item_combo_components()'::regprocedure
  ) INTO v_definition;
  IF (length(v_definition) - length(replace(v_definition, v_old, '')))
       / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'KDS_DIRECT_DELIVERY_COMBO_ROUTE_ANCHOR_INVALID';
  END IF;
  EXECUTE replace(v_definition, v_old, v_new);
END;
$migration$;

-- Re-route delivery lines that are already on an active paperless board.
UPDATE public.order_items item
SET fulfillment_route_snapshot = 'kitchen_tray_floor',
    combo_components = COALESCE((
      SELECT jsonb_agg(
        component.raw || jsonb_build_object(
          'fulfillment_route', 'kitchen_tray_floor'
        ) ORDER BY component.ord
      )
      FROM jsonb_array_elements(COALESCE(item.combo_components, '[]'::jsonb))
        WITH ORDINALITY component(raw, ord)
    ), '[]'::jsonb)
FROM public.orders order_row
WHERE order_row.id = item.order_id
  AND order_row.sales_channel = 'delivery'
  AND EXISTS (
    SELECT 1
    FROM public.emergency_order_queue queue
    JOIN public.emergency_fulfillment_sessions session_row
      ON session_row.id = queue.session_id AND session_row.status = 'active'
    WHERE queue.order_id = item.order_id
  )
  AND (
    item.fulfillment_route_snapshot <> 'kitchen_tray_floor'
    OR EXISTS (
      SELECT 1
      FROM jsonb_array_elements(COALESCE(item.combo_components, '[]'::jsonb))
        component(raw)
      WHERE component.raw->>'fulfillment_route' = 'floor_direct'
    )
  );

UPDATE public.emergency_floor_direct_items direct
SET is_cancelled = true, updated_at = now()
FROM public.orders order_row
WHERE order_row.id = direct.order_id
  AND order_row.sales_channel = 'delivery'
  AND direct.is_cancelled = false
  AND EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_sessions session_row
    WHERE session_row.id = direct.session_id AND session_row.status = 'active'
  );

-- Enrich every KDS order with its channel and keep delivery off floor boards.
CREATE OR REPLACE FUNCTION public.emergency_add_order_sales_channels(
  p_orders jsonb,
  p_station_type text
) RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
  SELECT COALESCE(jsonb_agg(
    order_row.raw || jsonb_build_object(
      'sales_channel', COALESCE(order_data.sales_channel, 'dine_in')
    ) ORDER BY order_row.ord
  ), '[]'::jsonb)
  FROM jsonb_array_elements(COALESCE(p_orders, '[]'::jsonb))
    WITH ORDINALITY order_row(raw, ord)
  LEFT JOIN public.orders order_data
    ON order_data.id = CASE
      WHEN order_row.raw->>'order_id' ~*
        '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      THEN (order_row.raw->>'order_id')::uuid
      ELSE NULL
    END
  WHERE p_station_type <> 'floor'
     OR COALESCE(order_data.sales_channel, 'dine_in') <> 'delivery';
$$;

REVOKE ALL ON FUNCTION public.emergency_add_order_sales_channels(jsonb, text)
  FROM PUBLIC, anon, authenticated;

ALTER FUNCTION public.get_emergency_station_snapshot()
  RENAME TO get_emergency_station_snapshot_pre_delivery_routing;
ALTER FUNCTION public.get_emergency_station_today_completed()
  RENAME TO get_emergency_station_today_completed_pre_delivery_routing;

REVOKE ALL ON FUNCTION public.get_emergency_station_snapshot_pre_delivery_routing()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_emergency_station_today_completed_pre_delivery_routing()
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
  v_payload := public.get_emergency_station_snapshot_pre_delivery_routing();
  IF jsonb_typeof(v_payload) = 'object' AND v_payload ? 'orders' THEN
    v_payload := jsonb_set(
      v_payload,
      '{orders}',
      public.emergency_add_order_sales_channels(
        v_payload->'orders',
        COALESCE(v_payload->>'station_type', '')
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
DECLARE
  v_station_type text := '';
BEGIN
  SELECT assignment.station_type
  INTO v_station_type
  FROM public.users user_row
  JOIN public.emergency_station_assignments assignment
    ON assignment.user_id = user_row.id
   AND assignment.restaurant_id = user_row.restaurant_id
   AND assignment.is_active = true
  WHERE user_row.auth_id = auth.uid()
    AND user_row.is_active = true
  LIMIT 1;

  RETURN public.emergency_add_order_sales_channels(
    public.get_emergency_station_today_completed_pre_delivery_routing(),
    COALESCE(v_station_type, '')
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

-- Suppress only the delivery-to-floor push. Kitchen and tray pushes remain.
CREATE OR REPLACE FUNCTION public.emergency_enqueue_push(
  p_event_id uuid,
  p_store_id uuid,
  p_order_id uuid,
  p_target_station text,
  p_floor_label text,
  p_stage text
) RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
  INSERT INTO public.emergency_push_deliveries (
    event_id, restaurant_id, device_id, push_token, station_type,
    floor_label, order_id, stage
  )
  SELECT
    p_event_id, p_store_id, device.id, device.token,
    assignment.station_type, assignment.floor_label, p_order_id, p_stage
  FROM public.emergency_web_push_devices device
  JOIN public.emergency_station_assignments assignment
    ON assignment.id = device.station_assignment_id
   AND assignment.restaurant_id = p_store_id
   AND assignment.is_active = true
  WHERE device.restaurant_id = p_store_id
    AND device.is_enabled = true
    AND assignment.station_type = p_target_station
    AND (p_target_station <> 'floor' OR assignment.floor_label = p_floor_label)
    AND NOT (
      p_target_station = 'floor'
      AND EXISTS (
        SELECT 1 FROM public.orders order_row
        WHERE order_row.id = p_order_id
          AND order_row.sales_channel = 'delivery'
      )
    )
  ON CONFLICT (event_id, device_id) DO NOTHING;
$$;

-- First kitchen progress means "preparing". Full tray dispatch means the
-- order has been handed to the Grab driver; no cashier status click is needed.
CREATE OR REPLACE FUNCTION public.sync_direct_delivery_ticket_from_kds()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_ticket public.direct_delivery_fulfillment_tickets%ROWTYPE;
BEGIN
  IF NEW.delta <= 0 OR NEW.stage NOT IN ('kitchen_done', 'tray_dispatched') THEN
    RETURN NEW;
  END IF;

  SELECT ticket.* INTO v_ticket
  FROM public.direct_delivery_fulfillment_tickets ticket
  JOIN public.direct_order_financials financial
    ON financial.request_id = ticket.request_id
   AND financial.order_id = NEW.order_id
  FOR UPDATE OF ticket;
  IF NOT FOUND OR v_ticket.status IN ('completed', 'cancelled') THEN
    RETURN NEW;
  END IF;

  IF NEW.stage = 'kitchen_done' AND v_ticket.status = 'pending' THEN
    UPDATE public.direct_delivery_fulfillment_tickets
    SET status = 'preparing',
        version = version + 1,
        accepted_at = COALESCE(accepted_at, now()),
        updated_by = (
          SELECT user_row.auth_id
          FROM public.users user_row
          WHERE user_row.id = NEW.actor_user_id
        ),
        updated_at = now()
    WHERE id = v_ticket.id;
  ELSIF NEW.stage = 'tray_dispatched'
     AND v_ticket.status IN ('pending', 'preparing', 'ready')
     AND NOT EXISTS (
       SELECT 1
       FROM public.emergency_fulfillment_items item
       WHERE item.order_id = NEW.order_id
         AND item.is_cancelled = false
         AND item.tray_dispatched_quantity < item.ordered_quantity
     ) THEN
    UPDATE public.direct_delivery_fulfillment_tickets
    SET status = 'dispatched',
        version = version + 1,
        accepted_at = COALESCE(accepted_at, now()),
        ready_at = COALESCE(ready_at, now()),
        dispatched_at = COALESCE(dispatched_at, now()),
        updated_by = (
          SELECT user_row.auth_id
          FROM public.users user_row
          WHERE user_row.id = NEW.actor_user_id
        ),
        updated_at = now()
    WHERE id = v_ticket.id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_direct_delivery_ticket_from_kds_trigger
  ON public.emergency_fulfillment_events;
CREATE TRIGGER sync_direct_delivery_ticket_from_kds_trigger
AFTER INSERT ON public.emergency_fulfillment_events
FOR EACH ROW EXECUTE FUNCTION public.sync_direct_delivery_ticket_from_kds();

-- Sending the link is messaging only. Physical tray handoff owns dispatched.
CREATE OR REPLACE FUNCTION public.direct_order_set_dispatch(
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
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  IF lower(COALESCE(p_grab_tracking_url, '')) !~
       '^(https://([[:alnum:]-]+[.])*grab[.]com([/:?#]|$)|https://grab[.]onelink[.]me([/:?#]|$))'
     OR char_length(p_grab_tracking_url) > 2000
     OR (p_actual_grab_fee IS NOT NULL AND p_actual_grab_fee < 0) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_DISPATCH_INPUT_INVALID';
  END IF;
  SELECT * INTO v_financial
  FROM public.direct_order_financials financial
  WHERE financial.request_id = p_request_id
    AND financial.restaurant_id = p_store_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_NOT_APPROVED'; END IF;

  INSERT INTO public.direct_order_dispatches(
    request_id, restaurant_id, grab_tracking_url,
    customer_delivery_fee, actual_grab_fee, fee_variance, sent_by
  ) VALUES (
    p_request_id, p_store_id, p_grab_tracking_url,
    v_financial.delivery_fee_total, p_actual_grab_fee,
    CASE WHEN p_actual_grab_fee IS NULL THEN NULL
      ELSE v_financial.delivery_fee_total - p_actual_grab_fee END,
    (SELECT auth.uid())
  )
  ON CONFLICT (request_id) DO UPDATE SET
    grab_tracking_url = EXCLUDED.grab_tracking_url,
    actual_grab_fee = EXCLUDED.actual_grab_fee,
    fee_variance = EXCLUDED.fee_variance,
    sent_by = EXCLUDED.sent_by,
    sent_at = now(),
    updated_at = now()
  RETURNING * INTO v_dispatch;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, sender_auth_id,
    message_type, body
  ) VALUES (
    p_request_id, p_store_id, 'cashier', (SELECT auth.uid()),
    'grab_link', p_grab_tracking_url
  );

  RETURN to_jsonb(v_dispatch) - ARRAY['restaurant_id', 'sent_by'];
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_set_dispatch(uuid, uuid, text, numeric)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_set_dispatch(uuid, uuid, text, numeric)
  TO authenticated, service_role;

-- Make cashier delivery panels refresh immediately on ticket changes.
DROP TRIGGER IF EXISTS direct_delivery_status_live_event
  ON public.direct_delivery_fulfillment_tickets;
CREATE TRIGGER direct_delivery_status_live_event
AFTER INSERT OR UPDATE ON public.direct_delivery_fulfillment_tickets
FOR EACH ROW
EXECUTE FUNCTION public.emit_pos_live_event('direct_delivery_status');

DO $verification$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.snapshot_order_item_combo_components()'::regprocedure
  ) INTO v_definition;
  IF position('v_direct_enabled := false' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'KDS_DIRECT_DELIVERY_COMBO_ROUTE_OVERRIDE_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.direct_order_set_dispatch(uuid,uuid,text,numeric)'::regprocedure
  ) INTO v_definition;
  IF position('direct_delivery_fulfillment_tickets' IN v_definition) > 0 THEN
    RAISE EXCEPTION 'GRAB_LINK_STILL_CHANGES_TICKET_STATUS';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid =
        'public.emergency_fulfillment_events'::regclass
      AND trigger_row.tgname =
        'sync_direct_delivery_ticket_from_kds_trigger'
      AND NOT trigger_row.tgisinternal
  ) THEN
    RAISE EXCEPTION 'KDS_DIRECT_DELIVERY_STATUS_TRIGGER_MISSING';
  END IF;
END;
$verification$;

COMMIT;
