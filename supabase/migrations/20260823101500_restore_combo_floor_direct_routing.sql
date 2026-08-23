BEGIN;

-- production-gate: self-verifying

-- Restore the established combo snapshot contract. The takeout rollout must
-- select the matching QR line without dropping localized component names or
-- the floor-direct route used to keep beverages out of kitchen and tray.
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
      AND COALESCE((line.raw->>'is_takeout')::boolean, false) = NEW.is_takeout
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

-- Repair only combo snapshots created during the faulty production window.
-- Completed orders stay completed; this update only restores display metadata.
WITH affected AS (
  SELECT DISTINCT order_item.id
  FROM public.order_items order_item
  JOIN public.restaurant_settings settings
    ON settings.restaurant_id = order_item.restaurant_id
   AND settings.floor_direct_beverages_enabled = true
  CROSS JOIN LATERAL jsonb_array_elements(
    COALESCE(order_item.combo_components, '[]'::jsonb)
  ) component(raw)
  JOIN public.menu_items component_item
    ON component.raw->>'menu_item_id' ~*
      '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   AND component_item.id = (component.raw->>'menu_item_id')::uuid
   AND component_item.restaurant_id = order_item.restaurant_id
  WHERE order_item.created_at >= timestamptz '2026-08-23 09:40:00+00'
    AND order_item.fulfillment_mode_snapshot = 'paperless'
    AND NOT (component.raw ? 'fulfillment_route')
    AND component_item.fulfillment_route = 'floor_direct'
), rebuilt AS (
  SELECT order_item.id,
    jsonb_agg(
      component.raw || jsonb_build_object(
        'name_ko', COALESCE(
          NULLIF(component_item.name_ko, ''), component_item.name
        ),
        'name_vi', COALESCE(
          NULLIF(component_item.name_vi, ''), component_item.name
        ),
        'name_en', COALESCE(
          NULLIF(component_item.name_en, ''), component_item.name
        ),
        'fulfillment_route', COALESCE(
          component_item.fulfillment_route, 'kitchen_tray_floor'
        )
      ) ORDER BY component.ord
    ) AS combo_components
  FROM affected
  JOIN public.order_items order_item ON order_item.id = affected.id
  CROSS JOIN LATERAL jsonb_array_elements(order_item.combo_components)
    WITH ORDINALITY component(raw, ord)
  LEFT JOIN public.menu_items component_item
    ON component.raw->>'menu_item_id' ~*
      '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   AND component_item.id = (component.raw->>'menu_item_id')::uuid
   AND component_item.restaurant_id = order_item.restaurant_id
  GROUP BY order_item.id
)
UPDATE public.order_items order_item
SET combo_components = rebuilt.combo_components
FROM rebuilt
WHERE order_item.id = rebuilt.id;

DO $$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.snapshot_order_item_combo_components()'::regprocedure
  ) INTO v_definition;

  IF v_definition NOT LIKE '%floor_direct_beverages_enabled%'
     OR v_definition NOT LIKE '%' || quote_literal('fulfillment_route') || '%'
     OR v_definition NOT LIKE '%NEW.is_takeout%' THEN
    RAISE EXCEPTION 'COMBO_FLOOR_DIRECT_FUNCTION_VERIFY_FAILED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_items order_item
    JOIN public.restaurant_settings settings
      ON settings.restaurant_id = order_item.restaurant_id
     AND settings.floor_direct_beverages_enabled = true
    CROSS JOIN LATERAL jsonb_array_elements(
      COALESCE(order_item.combo_components, '[]'::jsonb)
    ) component(raw)
    JOIN public.menu_items component_item
      ON component.raw->>'menu_item_id' ~*
        '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     AND component_item.id = (component.raw->>'menu_item_id')::uuid
     AND component_item.restaurant_id = order_item.restaurant_id
    WHERE order_item.created_at >= timestamptz '2026-08-23 09:40:00+00'
      AND order_item.fulfillment_mode_snapshot = 'paperless'
      AND NOT (component.raw ? 'fulfillment_route')
      AND component_item.fulfillment_route = 'floor_direct'
  ) THEN
    RAISE EXCEPTION 'COMBO_FLOOR_DIRECT_BACKFILL_VERIFY_FAILED';
  END IF;
END;
$$;

COMMIT;
