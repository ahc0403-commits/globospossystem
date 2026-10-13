-- Effective production snapshot triggers; isolated harness only.
CREATE OR REPLACE FUNCTION public.snapshot_order_item_combo_components()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_payload_text text;
  v_selected jsonb := '[]'::jsonb;
  v_fixed jsonb := '[]'::jsonb;
  v_drinks jsonb := '[]'::jsonb;
  v_direct_enabled boolean := false;
BEGIN IF current_setting('globos.cashier_item_mutation',true)='on' THEN RETURN NEW; END IF;
  IF NEW.menu_item_id IS NULL THEN
    NEW.combo_components := '[]'::jsonb;
    RETURN NEW;
  END IF;

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
$function$;

CREATE OR REPLACE FUNCTION public.snapshot_order_item_vat()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE direct_profile jsonb;
BEGIN IF current_setting('globos.cashier_item_mutation',true)='on' THEN RETURN NEW; END IF;
  IF NEW.item_type<>'menu_item' OR NEW.menu_item_id IS NULL THEN RETURN NEW; END IF;
  IF (TG_OP='INSERT' OR NEW.combo_components IS DISTINCT FROM OLD.combo_components)
     AND EXISTS(SELECT 1 FROM jsonb_array_elements(COALESCE(NEW.combo_components,'[]')) c
       LEFT JOIN public.menu_items m ON m.id=(c->>'menu_item_id')::uuid AND m.restaurant_id=NEW.restaurant_id
       WHERE m.id IS NULL OR m.price<=0 OR m.is_combo OR COALESCE((c->>'quantity')::numeric,0)<=0) THEN
    RAISE EXCEPTION 'MENU_TAX_COMBO_COMPONENT_INVALID';
  END IF;
  IF TG_OP='INSERT' THEN
    NEW.combo_components:=public.snapshot_combo_tax_components(NEW.combo_components,'[]',NEW.restaurant_id);
    NEW.vat_profile_snapshot:=public.menu_vat_profile(NEW.menu_item_id,NEW.restaurant_id,NEW.combo_components,NEW.quantity);
    IF NULLIF(current_setting('pos.direct_vat_request',true),'') IS NOT NULL THEN
      SELECT i.vat_profile_snapshot INTO STRICT direct_profile FROM public.direct_order_request_items i
      WHERE i.request_id=current_setting('pos.direct_vat_request',true)::uuid
        AND i.restaurant_id=NEW.restaurant_id AND i.menu_item_id=NEW.menu_item_id;
      NEW.vat_profile_snapshot:=direct_profile;
    END IF;
  ELSIF OLD.vat_profile_snapshot IS NOT NULL THEN
    -- Keep the original rates even if menu metadata or price changes later.
    NEW.vat_profile_snapshot:=OLD.vat_profile_snapshot;
    IF NEW.combo_components IS DISTINCT FROM OLD.combo_components
       OR (NEW.quantity IS DISTINCT FROM OLD.quantity AND jsonb_array_length(COALESCE(NEW.combo_components,'[]'))>0) THEN
      NEW.combo_components:=public.snapshot_combo_tax_components(NEW.combo_components,OLD.combo_components,NEW.restaurant_id);
      NEW.vat_profile_snapshot:=public.menu_vat_profile(NEW.menu_item_id,NEW.restaurant_id,NEW.combo_components,NEW.quantity);
      IF EXISTS(SELECT 1 FROM public.payments WHERE order_id=OLD.order_id) THEN
        RAISE EXCEPTION 'MENU_TAX_PAID_COMBO_IMMUTABLE';
      END IF;
    END IF;
    IF NEW.menu_item_id IS DISTINCT FROM OLD.menu_item_id
       OR NEW.restaurant_id IS DISTINCT FROM OLD.restaurant_id THEN
      RAISE EXCEPTION 'MENU_TAX_ORDER_IDENTITY_IMMUTABLE';
    END IF;
  ELSE
    NEW.vat_profile_snapshot:=OLD.vat_profile_snapshot;
  END IF;
  IF TG_OP='INSERT' THEN
    NEW.vat_rate:=CASE WHEN jsonb_array_length(NEW.vat_profile_snapshot)=1
      THEN (NEW.vat_profile_snapshot->0->>'rate')::numeric ELSE -1 END;
    NEW.vat_breakdown:=NULL;
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.snapshot_direct_order_item_vat()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
BEGIN
  IF TG_OP='INSERT' THEN
    NEW.vat_profile_snapshot:=public.menu_vat_profile(NEW.menu_item_id,NEW.restaurant_id);
  ELSE NEW.vat_profile_snapshot:=OLD.vat_profile_snapshot;
  END IF;
  RETURN NEW;
END $function$;

