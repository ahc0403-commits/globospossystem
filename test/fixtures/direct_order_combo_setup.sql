ALTER TABLE menu_items ADD COLUMN IF NOT EXISTS is_combo boolean NOT NULL DEFAULT false,
 ADD COLUMN IF NOT EXISTS is_archived boolean NOT NULL DEFAULT false,
 ADD COLUMN IF NOT EXISTS effective_vat_rate numeric NOT NULL DEFAULT 8,
 ADD COLUMN IF NOT EXISTS fulfillment_route text NOT NULL DEFAULT 'kitchen_tray_floor';
ALTER TABLE menu_categories ADD COLUMN IF NOT EXISTS system_key text;
CREATE TABLE IF NOT EXISTS menu_combo_components(id uuid DEFAULT gen_random_uuid(),restaurant_id uuid,combo_menu_item_id uuid,component_menu_item_id uuid,quantity integer,sort_order integer DEFAULT 0,created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE restaurant_settings ADD COLUMN IF NOT EXISTS floor_direct_beverages_enabled boolean DEFAULT false;
ALTER TABLE order_items ADD COLUMN IF NOT EXISTS combo_components jsonb NOT NULL DEFAULT '[]',
 ADD COLUMN IF NOT EXISTS is_takeout boolean NOT NULL DEFAULT false,
 ADD COLUMN IF NOT EXISTS vat_profile_snapshot jsonb,
 ADD COLUMN IF NOT EXISTS vat_breakdown jsonb,
 ADD COLUMN IF NOT EXISTS cancelled_consumed_quantity integer DEFAULT 0;
ALTER TABLE direct_order_request_items ADD COLUMN IF NOT EXISTS vat_profile_snapshot jsonb;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS non_revenue_type text, ADD COLUMN IF NOT EXISTS operational_closed_at timestamptz;
CREATE OR REPLACE FUNCTION public.order_promotion_fingerprint(uuid,uuid) RETURNS jsonb LANGUAGE sql AS $$ SELECT '{}'::jsonb $$;
CREATE OR REPLACE FUNCTION public.sync_active_order_promotion(uuid,uuid,timestamptz) RETURNS jsonb LANGUAGE sql AS $$ SELECT '{}'::jsonb $$;
CREATE FUNCTION public.menu_vat_profile(p_item_id uuid,p_store_id uuid,p_components jsonb DEFAULT '[]',p_quantity integer DEFAULT 1)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE item public.menu_items; profile jsonb;
BEGIN
  SELECT * INTO item FROM public.menu_items WHERE id=p_item_id AND restaurant_id=p_store_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND'; END IF;
  -- Direct ordering permits fixed combos without a drink-choice payload.
  IF item.is_combo AND jsonb_array_length(COALESCE(p_components,'[]'))=0 THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('menu_item_id',component_menu_item_id,
      'quantity',quantity)),'[]') INTO p_components
    FROM public.menu_combo_components
    WHERE combo_menu_item_id=p_item_id AND restaurant_id=p_store_id;
  END IF;
  IF item.is_combo AND jsonb_array_length(COALESCE(p_components,'[]'))>0 THEN
    IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_components) c
      LEFT JOIN public.menu_items m ON m.id=(c->>'menu_item_id')::uuid AND m.restaurant_id=p_store_id
      WHERE m.id IS NULL OR m.price<=0 OR m.is_combo OR (c->>'quantity')::numeric<=0) THEN
      RAISE EXCEPTION 'MENU_TAX_COMBO_COMPONENT_INVALID';
    END IF;
    SELECT jsonb_agg(jsonb_build_object('rate',rate,'weight',weight) ORDER BY rate) INTO profile
    FROM (SELECT COALESCE((c->>'tax_vat_rate')::numeric,m.effective_vat_rate) rate,
      sum(COALESCE((c->>'tax_unit_price')::numeric,m.price)*(c->>'quantity')::numeric *
        CASE WHEN COALESCE((c->>'is_total_quantity')::boolean,false) THEN 1 ELSE GREATEST(p_quantity,1) END) weight
      FROM jsonb_array_elements(p_components) c
      JOIN public.menu_items m ON m.id=(c->>'menu_item_id')::uuid AND m.restaurant_id=p_store_id
      GROUP BY COALESCE((c->>'tax_vat_rate')::numeric,m.effective_vat_rate)) weights;
  END IF;
  RETURN COALESCE(profile,jsonb_build_array(jsonb_build_object('rate',item.effective_vat_rate,'weight',1)));
END $$;
CREATE FUNCTION public.snapshot_combo_tax_components(p_components jsonb,p_previous jsonb,p_store_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT COALESCE(jsonb_agg(c.value||jsonb_build_object(
   'tax_vat_rate',COALESCE((prior.value->>'tax_vat_rate')::numeric,m.effective_vat_rate),
   'tax_unit_price',COALESCE((prior.value->>'tax_unit_price')::numeric,m.price)) ORDER BY c.ordinality),'[]')
 FROM jsonb_array_elements(COALESCE(p_components,'[]')) WITH ORDINALITY c(value,ordinality)
 JOIN public.menu_items m ON m.id=(c.value->>'menu_item_id')::uuid AND m.restaurant_id=p_store_id
 LEFT JOIN LATERAL (SELECT value FROM jsonb_array_elements(COALESCE(p_previous,'[]'))
   WHERE value->>'menu_item_id'=c.value->>'menu_item_id' LIMIT 1) prior ON true
$$;
CREATE TRIGGER direct_order_item_vat_snapshot BEFORE INSERT OR UPDATE ON public.direct_order_request_items FOR EACH ROW EXECUTE FUNCTION public.snapshot_direct_order_item_vat();
CREATE TRIGGER combo_snapshot BEFORE INSERT ON public.order_items FOR EACH ROW EXECUTE FUNCTION public.snapshot_order_item_combo_components();
CREATE TRIGGER zzz_order_item_vat_snapshot BEFORE INSERT OR UPDATE ON public.order_items FOR EACH ROW EXECUTE FUNCTION public.snapshot_order_item_vat();
