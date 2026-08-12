BEGIN;

-- Additive route metadata. Existing orders and active ledger rows remain on
-- the legacy kitchen -> tray -> floor path.
ALTER TABLE public.menu_items
  ADD COLUMN IF NOT EXISTS fulfillment_route text NOT NULL
  DEFAULT 'kitchen_tray_floor';
ALTER TABLE public.menu_items
  DROP CONSTRAINT IF EXISTS menu_items_fulfillment_route_check;
ALTER TABLE public.menu_items
  ADD CONSTRAINT menu_items_fulfillment_route_check
  CHECK (fulfillment_route IN ('kitchen_tray_floor', 'floor_direct'));

ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS fulfillment_route_snapshot text NOT NULL
  DEFAULT 'kitchen_tray_floor';
ALTER TABLE public.order_items
  DROP CONSTRAINT IF EXISTS order_items_fulfillment_route_snapshot_check;
ALTER TABLE public.order_items
  ADD CONSTRAINT order_items_fulfillment_route_snapshot_check
  CHECK (fulfillment_route_snapshot IN ('kitchen_tray_floor', 'floor_direct'));

ALTER TABLE public.restaurant_settings
  ADD COLUMN IF NOT EXISTS floor_direct_beverages_enabled boolean NOT NULL
  DEFAULT false;

UPDATE public.menu_items item
SET fulfillment_route = 'floor_direct', updated_at = now()
FROM public.menu_categories category
WHERE category.id = item.category_id
  AND category.restaurant_id = item.restaurant_id
  AND category.system_key = 'drink'
  AND item.fulfillment_route = 'kitchen_tray_floor';

-- A combo parent always represents its food preparation line. Direct drink
-- components are split from its immutable component snapshot instead.
UPDATE public.menu_items
SET fulfillment_route = 'kitchen_tray_floor', updated_at = now()
WHERE is_combo = true AND fulfillment_route = 'floor_direct';

CREATE OR REPLACE FUNCTION public.default_menu_item_fulfillment_route()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF NEW.is_combo THEN
    NEW.fulfillment_route := 'kitchen_tray_floor';
  ELSIF EXISTS (
    SELECT 1 FROM public.menu_categories category
    WHERE category.id = NEW.category_id
      AND category.restaurant_id = NEW.restaurant_id
      AND category.system_key = 'drink'
  ) THEN
    NEW.fulfillment_route := 'floor_direct';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS default_menu_item_fulfillment_route_trigger
  ON public.menu_items;
CREATE TRIGGER default_menu_item_fulfillment_route_trigger
BEFORE INSERT OR UPDATE OF is_combo ON public.menu_items
FOR EACH ROW EXECUTE FUNCTION public.default_menu_item_fulfillment_route();

COMMENT ON COLUMN public.menu_items.fulfillment_route IS
  'Paperless route candidate. floor_direct is intended for beverages served by the assigned floor.';
COMMENT ON COLUMN public.order_items.fulfillment_route_snapshot IS
  'Immutable paperless route captured when the order item is created.';
COMMENT ON COLUMN public.restaurant_settings.floor_direct_beverages_enabled IS
  'Safety gate for capturing new floor-direct order items. Existing items never re-route.';

CREATE OR REPLACE FUNCTION public.capture_order_item_fulfillment_mode()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_direct_enabled boolean := false;
BEGIN
  PERFORM pg_advisory_xact_lock(
    hashtextextended('fulfillment-mode:' || NEW.restaurant_id::text, 0)
  );
  NEW.fulfillment_mode_snapshot :=
    public.get_store_fulfillment_mode(NEW.restaurant_id);

  SELECT COALESCE(settings.floor_direct_beverages_enabled, false)
  INTO v_direct_enabled
  FROM public.restaurant_settings settings
  WHERE settings.restaurant_id = NEW.restaurant_id;

  IF NEW.fulfillment_mode_snapshot = 'paperless'
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

CREATE OR REPLACE FUNCTION public.snapshot_order_item_combo_components()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO public
AS $$
DECLARE
  v_payload_text text;
  v_selected jsonb := '[]'::jsonb;
  v_fixed jsonb := '[]'::jsonb;
  v_drinks jsonb := '[]'::jsonb;
  v_direct_enabled boolean := false;
BEGIN
  IF NEW.menu_item_id IS NULL THEN
    NEW.combo_components := '[]'::jsonb;
    RETURN NEW;
  END IF;

  SELECT COALESCE(settings.floor_direct_beverages_enabled, false)
  INTO v_direct_enabled
  FROM public.restaurant_settings settings
  WHERE settings.restaurant_id = NEW.restaurant_id;

  v_payload_text := current_setting('pos.qr_combo_payload', true);
  IF NULLIF(v_payload_text, '') IS NOT NULL THEN
    SELECT COALESCE(line.raw->'combo_drink_choices', '[]'::jsonb)
    INTO v_selected
    FROM jsonb_array_elements(v_payload_text::jsonb) line(raw)
    WHERE line.raw->>'menu_item_id' = NEW.menu_item_id::text
    LIMIT 1;
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'menu_item_id', component_item.id::text,
      'label', component_item.name,
      'name_ko', COALESCE(NULLIF(component_item.name_ko, ''), component_item.name),
      'name_vi', COALESCE(NULLIF(component_item.name_vi, ''), component_item.name),
      'name_en', COALESCE(NULLIF(component_item.name_en, ''), component_item.name),
      'quantity', component.quantity,
      'fulfillment_route', CASE
        WHEN NEW.fulfillment_mode_snapshot = 'paperless'
          AND v_direct_enabled
          THEN component_item.fulfillment_route
        ELSE 'kitchen_tray_floor'
      END
    ) ORDER BY component.sort_order, component.created_at, component.id
  ), '[]'::jsonb)
  INTO v_fixed
  FROM public.menu_combo_components component
  JOIN public.menu_items component_item
    ON component_item.id = component.component_menu_item_id
   AND component_item.restaurant_id = component.restaurant_id
  WHERE component.combo_menu_item_id = NEW.menu_item_id
    AND component.restaurant_id = NEW.restaurant_id
    AND (
      jsonb_array_length(v_selected) = 0
      OR lower(btrim(COALESCE(NULLIF(component_item.name_ko, ''), component_item.name)))
        NOT IN ('음료', 'drink', 'beverage', 'đồ uống', 'nước uống')
    );

  IF jsonb_array_length(v_selected) > 0 THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'menu_item_id', selected_item.id::text,
      'label', selected_item.name,
      'name_ko', COALESCE(NULLIF(selected_item.name_ko, ''), selected_item.name),
      'name_vi', COALESCE(NULLIF(selected_item.name_vi, ''), selected_item.name),
      'name_en', COALESCE(NULLIF(selected_item.name_en, ''), selected_item.name),
      'quantity', selected.quantity,
      'is_total_quantity', true,
      'fulfillment_route', CASE
        WHEN NEW.fulfillment_mode_snapshot = 'paperless'
          AND v_direct_enabled
          THEN selected_item.fulfillment_route
        ELSE 'kitchen_tray_floor'
      END
    ) ORDER BY selected.first_ordinal), '[]'::jsonb)
    INTO v_drinks
    FROM (
      SELECT choice.value::uuid AS item_id,
             count(*)::integer AS quantity,
             min(choice.ordinality) AS first_ordinal
      FROM jsonb_array_elements_text(v_selected)
        WITH ORDINALITY choice(value, ordinality)
      GROUP BY choice.value
    ) selected
    JOIN public.menu_items selected_item
      ON selected_item.id = selected.item_id
     AND selected_item.restaurant_id = NEW.restaurant_id;
  END IF;

  NEW.combo_components := v_fixed || v_drinks;
  RETURN NEW;
END;
$$;

CREATE TABLE public.emergency_floor_direct_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES public.emergency_fulfillment_sessions(id)
    ON DELETE CASCADE,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  queue_id uuid NOT NULL REFERENCES public.emergency_order_queue(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  order_item_id uuid NOT NULL REFERENCES public.order_items(id) ON DELETE CASCADE,
  line_key text NOT NULL,
  source_kind text NOT NULL CHECK (source_kind IN ('order_item', 'combo_component')),
  component_menu_item_id uuid REFERENCES public.menu_items(id) ON DELETE SET NULL,
  name_ko text NOT NULL,
  name_vi text NOT NULL,
  name_en text NOT NULL,
  source_quantity integer NOT NULL CHECK (source_quantity > 0),
  ordered_quantity integer NOT NULL CHECK (ordered_quantity > 0),
  floor_served_quantity integer NOT NULL DEFAULT 0,
  is_cancelled boolean NOT NULL DEFAULT false,
  needs_review boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (session_id, order_item_id, line_key),
  CONSTRAINT emergency_floor_direct_quantity_check CHECK (
    floor_served_quantity >= 0
    AND floor_served_quantity <= ordered_quantity
  ),
  CONSTRAINT emergency_floor_direct_line_key_present CHECK (btrim(line_key) <> '')
);

CREATE INDEX emergency_floor_direct_order
  ON public.emergency_floor_direct_items (session_id, order_id, queue_id);
CREATE INDEX emergency_floor_direct_store_open
  ON public.emergency_floor_direct_items (restaurant_id, created_at)
  WHERE is_cancelled = false;

ALTER TABLE public.emergency_floor_direct_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY emergency_floor_direct_store_read
ON public.emergency_floor_direct_items
FOR SELECT TO authenticated
USING (public.is_super_admin() OR EXISTS (
  SELECT 1
  FROM public.user_accessible_stores((SELECT auth.uid())) scope(store_id)
  WHERE scope.store_id = restaurant_id
));
REVOKE ALL ON public.emergency_floor_direct_items
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.emergency_floor_direct_items TO authenticated;
GRANT ALL ON public.emergency_floor_direct_items TO service_role;

ALTER TABLE public.emergency_fulfillment_events
  ADD COLUMN IF NOT EXISTS floor_direct_item_id uuid
  REFERENCES public.emergency_floor_direct_items(id) ON DELETE SET NULL;
ALTER TABLE public.emergency_fulfillment_events
  DROP CONSTRAINT IF EXISTS emergency_fulfillment_events_stage_check;
ALTER TABLE public.emergency_fulfillment_events
  ADD CONSTRAINT emergency_fulfillment_events_stage_check CHECK (stage IN (
    'order_received', 'floor_direct_ready', 'kitchen_done', 'tray_received',
    'tray_dispatched', 'floor_served'
  ));
CREATE INDEX emergency_events_direct_item_created
  ON public.emergency_fulfillment_events (floor_direct_item_id, created_at)
  WHERE floor_direct_item_id IS NOT NULL;
CREATE INDEX emergency_events_store_created
  ON public.emergency_fulfillment_events (restaurant_id, created_at);
CREATE INDEX emergency_events_analytics
  ON public.emergency_fulfillment_events (
    restaurant_id, order_id, stage, created_at
  )
  WHERE delta > 0;

CREATE OR REPLACE FUNCTION public.admin_set_menu_fulfillment_route(
  p_item_id uuid,
  p_route text
) RETURNS public.menu_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_item public.menu_items%ROWTYPE;
  v_previous text;
BEGIN
  IF p_route NOT IN ('kitchen_tray_floor', 'floor_direct') THEN
    RAISE EXCEPTION 'MENU_FULFILLMENT_ROUTE_INVALID';
  END IF;
  SELECT * INTO v_item FROM public.menu_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND'; END IF;
  PERFORM public.require_admin_actor_for_restaurant(v_item.restaurant_id);
  IF v_item.is_combo AND p_route = 'floor_direct' THEN
    RAISE EXCEPTION 'MENU_COMBO_FLOOR_DIRECT_NOT_ALLOWED';
  END IF;
  v_previous := v_item.fulfillment_route;
  UPDATE public.menu_items
  SET fulfillment_route = p_route, updated_at = now()
  WHERE id = p_item_id
  RETURNING * INTO v_item;
  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'set_menu_fulfillment_route', 'menu_items', p_item_id,
    jsonb_build_object(
      'store_id', v_item.restaurant_id,
      'previous_route', v_previous,
      'next_route', p_route
    )
  );
  RETURN v_item;
END;
$$;

CREATE OR REPLACE FUNCTION public.super_admin_set_floor_direct_beverages(
  p_store_id uuid,
  p_enabled boolean,
  p_reason text,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_previous boolean := false;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'FLOOR_DIRECT_SUPER_ADMIN_REQUIRED';
  END IF;
  IF p_store_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.restaurants
    WHERE id = p_store_id AND is_active = true
  ) THEN RAISE EXCEPTION 'FLOOR_DIRECT_STORE_UNAVAILABLE'; END IF;
  IF p_request_id IS NULL OR NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'FLOOR_DIRECT_REASON_REQUIRED';
  END IF;
  PERFORM pg_advisory_xact_lock(
    hashtextextended('floor-direct:' || p_store_id::text, 0)
  );
  SELECT COALESCE(settings.floor_direct_beverages_enabled, false)
  INTO v_previous
  FROM public.restaurant_settings settings
  WHERE settings.restaurant_id = p_store_id;
  INSERT INTO public.restaurant_settings(
    restaurant_id, floor_direct_beverages_enabled, updated_at
  ) VALUES (p_store_id, p_enabled, now())
  ON CONFLICT (restaurant_id) DO UPDATE SET
    floor_direct_beverages_enabled = EXCLUDED.floor_direct_beverages_enabled,
    updated_at = now();
  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'set_floor_direct_beverages', 'restaurants', p_store_id,
    jsonb_build_object(
      'previous_enabled', v_previous,
      'next_enabled', p_enabled,
      'reason', btrim(p_reason),
      'request_id', p_request_id
    )
  );
  RETURN jsonb_build_object(
    'enabled', p_enabled,
    'previous_enabled', v_previous,
    'new_orders_only', true
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_menu_fulfillment_route(uuid, text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.super_admin_set_floor_direct_beverages(
  uuid, boolean, text, uuid
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_menu_fulfillment_route(uuid, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.super_admin_set_floor_direct_beverages(
  uuid, boolean, text, uuid
) TO authenticated;

COMMIT;
