-- production-gate: self-verifying
-- A catalog dish owns its registered S/L and noodles/rice choices. Stable
-- sellable IDs keep all existing order, tax, receipt and fulfillment contracts.
BEGIN;
ALTER TABLE public.menu_items
 ADD COLUMN meal_choices boolean NOT NULL DEFAULT false,
 ADD COLUMN meal_choice text NOT NULL DEFAULT '' CHECK(meal_choice IN ('','noodles','rice'));
DROP INDEX public.menu_items_size_projection_idx;
ALTER TABLE public.menu_items DROP CONSTRAINT menu_size_parent_valid;
ALTER TABLE public.menu_items ADD CONSTRAINT menu_size_parent_valid CHECK
 (size_parent_id IS NULL OR (size_parent_id<>id AND size_prices='{}'::jsonb));
CREATE UNIQUE INDEX menu_items_size_projection_idx ON public.menu_items(size_parent_id,portion_code,meal_choice) WHERE size_parent_id IS NOT NULL;

CREATE FUNCTION public.menu_meal_name(p_name text,p_choice text,p_language text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT CASE WHEN p_name IS NULL OR btrim(p_name)='' OR p_choice='' THEN p_name
 ELSE concat_ws(' · ',CASE p_choice WHEN 'noodles' THEN CASE p_language WHEN 'vi' THEN 'Mì' WHEN 'en' THEN 'Noodles' ELSE '면' END
 WHEN 'rice' THEN CASE p_language WHEN 'vi' THEN 'Cơm' WHEN 'en' THEN 'Rice' ELSE '밥' END END,p_name) END;
$$;
CREATE FUNCTION public.menu_meal_option_key(p_id uuid,p_parent uuid,p_prices jsonb,p_bases jsonb,p_portion text,p_spice text,p_choice text,p_price numeric,p_meals boolean,p_meal text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path=public,pg_catalog AS $$
 SELECT CASE WHEN NOT p_meals THEN public.menu_size_option_key(p_id,p_parent,p_prices,p_bases,p_portion,p_spice,p_choice,p_price)
 ELSE jsonb_build_array(p_portion,p_spice,p_choice,p_price,jsonb_build_object('menu_id',coalesce(p_parent,p_id),
 'meal_choice',p_meal,'names',jsonb_build_object(
 'name',public.menu_option_name(p_bases->>'name','',p_spice,p_choice,'ko'),
 'name_ko',public.menu_option_name(p_bases->>'name_ko','',p_spice,p_choice,'ko'),
 'name_vi',public.menu_option_name(p_bases->>'name_vi','',p_spice,p_choice,'vi'),
 'name_en',public.menu_option_name(p_bases->>'name_en','',p_spice,p_choice,'en'))))::text END;
$$;
ALTER TABLE public.menu_items ALTER COLUMN menu_option_key SET EXPRESSION AS
 (public.menu_meal_option_key(id,size_parent_id,size_prices,option_base_names,portion_code,spice_level,spice_choice,price,meal_choices,meal_choice));

CREATE OR REPLACE FUNCTION public.menu_size_price_before() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_catalog AS $$
BEGIN
 IF NEW.size_parent_id IS NULL THEN
  NEW.meal_choice:=CASE WHEN NEW.meal_choices THEN 'noodles' ELSE '' END;
 END IF;
 IF NEW.size_prices<>'{}'::jsonb THEN
  IF NEW.restaurant_id<>'273b057e-3b69-46e3-93c1-6194c2802849'::uuid OR NEW.is_combo
   OR NOT public.menu_size_prices_valid(NEW.size_prices) THEN RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
  NEW.portion_code:='S'; NEW.price:=(NEW.size_prices->>'S')::numeric;
 END IF;
 IF NEW.meal_choices AND NEW.is_combo THEN RAISE EXCEPTION 'MENU_COMBO_MEAL_CHOICES_UNSUPPORTED'; END IF;
 RETURN NEW;
END $$;

-- Both INSERT and UPDATE transition tables are processed in sets. At most four
-- projections per dish; no menu-by-menu RPC or SQL query loop is introduced.
CREATE OR REPLACE FUNCTION public.menu_size_price_sync_batch() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF pg_trigger_depth()>1 THEN RETURN NULL; END IF;
 IF EXISTS(SELECT 1 FROM changed_sizes n JOIN public.menu_items p ON p.id=n.size_parent_id
   WHERE n.restaurant_id<>p.restaurant_id OR (NOT n.is_archived AND
    (n.price<>CASE WHEN p.size_prices='{}'::jsonb THEN p.price ELSE (p.size_prices->>n.portion_code)::numeric END
     OR n.meal_choices<>p.meal_choices))) THEN RAISE EXCEPTION 'MENU_SIZE_PRICE_MANAGED_BY_PARENT'; END IF;
 UPDATE public.menu_items c SET
  price=CASE WHEN p.size_prices='{}'::jsonb THEN p.price ELSE coalesce((p.size_prices->>c.portion_code)::numeric,c.price) END,
  name=p.option_base_names->>'name',name_ko=p.option_base_names->>'name_ko',name_vi=p.option_base_names->>'name_vi',name_en=p.option_base_names->>'name_en',
  paperless_name_vi=p.option_base_names->>'paperless_name_vi',option_base_names=p.option_base_names,
  spice_level=p.spice_level,spice_choice=p.spice_choice,meal_choices=p.meal_choices,
  meal_choice=CASE WHEN p.meal_choices AND c.meal_choice='' THEN 'noodles' WHEN NOT p.meal_choices AND c.meal_choice='noodles' THEN '' ELSE c.meal_choice END,
  category_id=p.category_id,description=p.description,image_url=p.image_url,image_storage_path=p.image_storage_path,
  is_available=p.is_available AND
   (CASE WHEN p.size_prices='{}'::jsonb THEN c.portion_code=p.portion_code ELSE p.size_prices ? c.portion_code END) AND
   (CASE WHEN p.meal_choices THEN c.meal_choice IN ('','noodles','rice') ELSE c.meal_choice IN ('','noodles') END),
  is_archived=p.is_archived OR NOT
   ((CASE WHEN p.size_prices='{}'::jsonb THEN c.portion_code=p.portion_code ELSE p.size_prices ? c.portion_code END) AND
    (CASE WHEN p.meal_choices THEN c.meal_choice IN ('','noodles','rice') ELSE c.meal_choice IN ('','noodles') END)),
  is_visible_public=p.is_visible_public,fulfillment_route=p.fulfillment_route,vat_category=p.vat_category,
  beverage_sugar_tax_class=p.beverage_sugar_tax_class,sugar_g_per_100ml=p.sugar_g_per_100ml,tax_basis_note=p.tax_basis_note,
  invoice_sale_unit=p.invoice_sale_unit,updated_at=now()
 FROM changed_sizes p WHERE c.size_parent_id=p.id AND p.size_parent_id IS NULL;
 INSERT INTO public.menu_items(restaurant_id,category_id,name,name_ko,name_vi,name_en,paperless_name_vi,
  price,portion_code,spice_level,spice_choice,option_base_names,size_parent_id,meal_choices,meal_choice,
  sort_order,is_available,is_archived,is_visible_public,description,image_url,image_storage_path,
  fulfillment_route,vat_category,beverage_sugar_tax_class,sugar_g_per_100ml,tax_basis_note,invoice_sale_unit)
 SELECT p.restaurant_id,p.category_id,p.option_base_names->>'name',p.option_base_names->>'name_ko',p.option_base_names->>'name_vi',p.option_base_names->>'name_en',p.option_base_names->>'paperless_name_vi',
  CASE WHEN p.size_prices='{}'::jsonb THEN p.price ELSE (p.size_prices->>sizes.portion)::numeric END,
  sizes.portion,p.spice_level,p.spice_choice,p.option_base_names,p.id,p.meal_choices,meals.choice,
  p.sort_order,p.is_available,p.is_archived,p.is_visible_public,p.description,p.image_url,p.image_storage_path,
  p.fulfillment_route,p.vat_category,p.beverage_sugar_tax_class,p.sugar_g_per_100ml,p.tax_basis_note,p.invoice_sale_unit
 FROM changed_sizes p
 CROSS JOIN LATERAL(SELECT key portion FROM jsonb_each(p.size_prices)
   UNION ALL SELECT p.portion_code WHERE p.size_prices='{}'::jsonb) sizes
 CROSS JOIN LATERAL(SELECT choice FROM (VALUES('noodles'),('rice')) m(choice) WHERE p.meal_choices
   UNION ALL SELECT '' WHERE NOT p.meal_choices) meals
 WHERE p.size_parent_id IS NULL AND (p.meal_choices OR p.size_prices<>'{}'::jsonb)
  AND (sizes.portion,meals.choice)<>(p.portion_code,p.meal_choice)
  AND NOT EXISTS(SELECT 1 FROM public.menu_items c WHERE c.size_parent_id=p.id AND c.portion_code=sizes.portion AND c.meal_choice=meals.choice)
 ON CONFLICT(size_parent_id,portion_code,meal_choice) WHERE size_parent_id IS NOT NULL DO NOTHING;
 RETURN NULL;
END $$;
CREATE OR REPLACE FUNCTION public.menu_save_size_prices(p_item_id uuid,p_prices jsonb,p_tax jsonb DEFAULT NULL)
RETURNS public.menu_items LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE m public.menu_items;
BEGIN
 SELECT * INTO m FROM public.menu_items WHERE id=p_item_id FOR UPDATE;
 PERFORM public.require_admin_actor_for_restaurant(m.restaurant_id);
 IF m.id IS NULL OR m.size_parent_id IS NOT NULL OR NOT public.menu_size_prices_valid(p_prices)
 OR (p_prices<>'{}'::jsonb AND (m.restaurant_id<>'273b057e-3b69-46e3-93c1-6194c2802849'::uuid OR m.is_combo)) THEN RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
 UPDATE public.menu_items SET size_prices=p_prices,portion_code=CASE WHEN p_prices='{}'::jsonb THEN '' ELSE 'S' END,updated_at=now()
 WHERE id=p_item_id RETURNING * INTO m;
 RETURN m;
END $$;
ALTER FUNCTION public.admin_create_menu_item_with_options(uuid,uuid,text,text,text,text,numeric,jsonb,integer,boolean,jsonb,text) RENAME TO admin_create_menu_item_pre_meal_choices;
ALTER FUNCTION public.admin_update_menu_item_with_options(uuid,text,text,text,text,numeric,jsonb,jsonb) RENAME TO admin_update_menu_item_pre_meal_choices;
REVOKE ALL ON FUNCTION public.admin_create_menu_item_pre_meal_choices(uuid,uuid,text,text,text,text,numeric,jsonb,integer,boolean,jsonb,text),public.admin_update_menu_item_pre_meal_choices(uuid,text,text,text,text,numeric,jsonb,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.admin_create_menu_item_with_options(
 p_store_id uuid,p_category_id uuid,p_name_ko text,p_name_vi text,p_name_en text,p_paperless_name_vi text,
 p_price numeric,p_options jsonb,p_sort_order integer DEFAULT 0,p_is_available boolean DEFAULT true,p_tax jsonb DEFAULT NULL,p_invoice_sale_unit text DEFAULT NULL)
RETURNS public.menu_items LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE m public.menu_items;
BEGIN
 IF p_options ? 'meal_choices' AND jsonb_typeof(p_options->'meal_choices')<>'boolean' THEN RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
 m:=public.admin_create_menu_item_pre_meal_choices(p_store_id,p_category_id,p_name_ko,p_name_vi,p_name_en,p_paperless_name_vi,p_price,p_options-'meal_choices',p_sort_order,p_is_available,p_tax,p_invoice_sale_unit);
 UPDATE public.menu_items SET meal_choices=coalesce((p_options->>'meal_choices')::boolean,false) WHERE id=m.id RETURNING * INTO m;
 RETURN m;
END $$;
CREATE FUNCTION public.admin_update_menu_item_with_options(
 p_item_id uuid,p_name_ko text,p_name_vi text,p_name_en text,p_paperless_name_vi text,p_price numeric,p_options jsonb,p_tax jsonb DEFAULT NULL)
RETURNS public.menu_items LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE m public.menu_items;
BEGIN
 IF p_options ? 'meal_choices' AND jsonb_typeof(p_options->'meal_choices')<>'boolean' THEN RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
 m:=public.admin_update_menu_item_pre_meal_choices(p_item_id,p_name_ko,p_name_vi,p_name_en,p_paperless_name_vi,p_price,p_options-'meal_choices',p_tax);
 IF p_options ? 'meal_choices' THEN
  UPDATE public.menu_items SET meal_choices=(p_options->>'meal_choices')::boolean WHERE id=m.id RETURNING * INTO m;
 END IF;
 RETURN m;
END $$;
REVOKE ALL ON FUNCTION public.admin_create_menu_item_with_options(uuid,uuid,text,text,text,text,numeric,jsonb,integer,boolean,jsonb,text),public.admin_update_menu_item_with_options(uuid,text,text,text,text,numeric,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_create_menu_item_with_options(uuid,uuid,text,text,text,text,numeric,jsonb,integer,boolean,jsonb,text),public.admin_update_menu_item_with_options(uuid,text,text,text,text,numeric,jsonb,jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.menu_apply_option_names() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_catalog AS $$
DECLARE bases jsonb; k text; n text; old_n text; lang text;
BEGIN
 IF NEW.meal_choice='' AND NEW.portion_code='' AND NEW.spice_level='unknown' AND NEW.spice_choice='' AND NEW.option_base_names='{}'::jsonb THEN RETURN NEW; END IF;
 bases:=NEW.option_base_names;
 FOREACH k IN ARRAY ARRAY['name','name_ko','name_vi','name_en','paperless_name_vi'] LOOP
  n:=to_jsonb(NEW)->>k;
  IF TG_OP='UPDATE' THEN
   old_n:=to_jsonb(OLD)->>k;
   IF n IS NOT DISTINCT FROM old_n AND OLD.option_base_names ? k THEN n:=OLD.option_base_names->>k; END IF;
  END IF;
  bases:=bases||jsonb_build_object(k,n);
  lang:=CASE WHEN k IN ('name_vi','paperless_name_vi') THEN 'vi' WHEN k='name_en' THEN 'en' ELSE 'ko' END;
  NEW:=jsonb_populate_record(NEW,jsonb_build_object(k,public.menu_meal_name(public.menu_option_name(n,NEW.portion_code,NEW.spice_level,NEW.spice_choice,lang),NEW.meal_choice,lang)));
 END LOOP;
 NEW.option_base_names:=bases;
 RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.capture_menu_option_batch() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF TG_TABLE_NAME='order_items' THEN
  -- Cashier splits copy the original immutable row; never reprice or replace it.
  IF current_setting('globos.cashier_item_mutation',true)='on' THEN RETURN NULL; END IF;
  IF EXISTS(SELECT 1 FROM new_menu_lines n JOIN public.menu_items m ON m.id=n.menu_item_id
    WHERE (m.meal_choice<>'' OR m.portion_code<>'' OR m.spice_level<>'unknown' OR m.spice_choice<>'')
     AND (n.restaurant_id<>m.restaurant_id OR NOT m.is_available OR m.is_archived
      OR (NOT n.is_service_item AND n.unit_price<>m.price))) THEN RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
  UPDATE public.order_items o SET menu_option_snapshot=jsonb_build_object(
    'menu_item_id',m.id,'meal_choice',m.meal_choice,'portion_code',m.portion_code,'spice_level',m.spice_level,'spice_choice',m.spice_choice,
    'unit_price',n.unit_price,'name_ko',m.name_ko,'name_vi',m.name_vi,'name_en',m.name_en),
    label=m.name,display_name=m.name
  FROM new_menu_lines n JOIN public.menu_items m ON m.id=n.menu_item_id
  WHERE o.id=n.id AND (m.meal_choice<>'' OR m.portion_code<>'' OR m.spice_level<>'unknown' OR m.spice_choice<>'');
  IF nullif(current_setting('app.direct_order_request_id',true),'') IS NOT NULL THEN
   UPDATE public.order_items o SET menu_option_snapshot=r.menu_option_snapshot,
    label=r.display_name,display_name=r.display_name
   FROM new_menu_lines n JOIN public.direct_order_request_items r
    ON r.request_id=nullif(current_setting('app.direct_order_request_id',true),'')::uuid
    AND r.menu_item_id=n.menu_item_id AND r.restaurant_id=n.restaurant_id
   WHERE o.id=n.id AND r.menu_option_snapshot<>'{}'::jsonb;
  END IF;
 ELSE
  UPDATE public.direct_order_request_items o SET menu_option_snapshot=jsonb_build_object(
    'menu_item_id',m.id,'meal_choice',m.meal_choice,'portion_code',m.portion_code,'spice_level',m.spice_level,'spice_choice',m.spice_choice,
    'unit_price',n.unit_price,'name_ko',n.name_ko,'name_vi',n.name_vi,'name_en',n.name_en)
  FROM new_menu_lines n JOIN public.menu_items m ON m.id=n.menu_item_id AND m.restaurant_id=n.restaurant_id
  WHERE o.id=n.id AND (m.meal_choice<>'' OR m.portion_code<>'' OR m.spice_level<>'unknown' OR m.spice_choice<>'');
 END IF;

 -- Component choices are keyed by their stable sellable ID in the order-time
 -- snapshot. One aggregate JOIN covers the complete inserted batch.
 IF TG_TABLE_NAME='order_items' AND nullif(current_setting('app.direct_order_request_id',true),'') IS NULL THEN
  WITH parts AS (
   SELECT n.id,jsonb_object_agg(m.id::text,jsonb_build_object('menu_item_id',m.id,
    'meal_choice',m.meal_choice,'portion_code',m.portion_code,'spice_level',m.spice_level,'spice_choice',m.spice_choice,
    'name_ko',coalesce(c->>'name_ko',m.name_ko),'name_vi',coalesce(c->>'name_vi',m.name_vi),
    'name_en',coalesce(c->>'name_en',m.name_en),'unit_price',coalesce(c->'tax_unit_price',to_jsonb(m.price)))) data
   FROM new_menu_lines n CROSS JOIN LATERAL jsonb_array_elements(coalesce(n.combo_components,'[]'))c
   JOIN public.menu_items m ON m.id=(c->>'menu_item_id')::uuid AND m.restaurant_id=n.restaurant_id
   WHERE m.menu_option_key IS NOT NULL GROUP BY n.id
  ) UPDATE public.order_items o SET menu_option_snapshot=
   CASE WHEN o.menu_option_snapshot='{}'::jsonb THEN jsonb_build_object('menu_item_id',m.id,
    'meal_choice',m.meal_choice,'portion_code',m.portion_code,'spice_level',m.spice_level,'spice_choice',m.spice_choice,
    'name_ko',m.name_ko,'name_vi',m.name_vi,'name_en',m.name_en,'unit_price',o.unit_price)
    ELSE o.menu_option_snapshot END || jsonb_build_object('components',p.data)
   FROM parts p,new_menu_lines n,public.menu_items m WHERE o.id=p.id AND n.id=o.id AND m.id=n.menu_item_id;
 ELSIF TG_TABLE_NAME='direct_order_request_items' THEN
  WITH parts AS (
   SELECT n.id,jsonb_object_agg(m.id::text,jsonb_build_object('menu_item_id',m.id,
    'meal_choice',m.meal_choice,'portion_code',m.portion_code,'spice_level',m.spice_level,'spice_choice',m.spice_choice,
    'name_ko',coalesce(c->>'name_ko',m.name_ko),'name_vi',coalesce(c->>'name_vi',m.name_vi),
    'name_en',coalesce(c->>'name_en',m.name_en),'unit_price',coalesce(c->'tax_unit_price',to_jsonb(m.price)))) data
   FROM new_menu_lines n CROSS JOIN LATERAL jsonb_array_elements(coalesce(n.combo_components,'[]'))c
   JOIN public.menu_items m ON m.id=(c->>'menu_item_id')::uuid AND m.restaurant_id=n.restaurant_id
   WHERE m.menu_option_key IS NOT NULL GROUP BY n.id
  ) UPDATE public.direct_order_request_items o SET menu_option_snapshot=
   CASE WHEN o.menu_option_snapshot='{}'::jsonb THEN jsonb_build_object('menu_item_id',m.id,
    'meal_choice',m.meal_choice,'portion_code',m.portion_code,'spice_level',m.spice_level,'spice_choice',m.spice_choice,
    'name_ko',m.name_ko,'name_vi',m.name_vi,'name_en',m.name_en,'unit_price',o.unit_price)
    ELSE o.menu_option_snapshot END || jsonb_build_object('components',p.data)
   FROM parts p,new_menu_lines n,public.menu_items m WHERE o.id=p.id AND n.id=o.id AND m.id=n.menu_item_id;
 END IF;
 RETURN NULL;
END $$;
-- Older workbooks omit meal_choices and preserve the registered selection.
ALTER FUNCTION public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb) RENAME TO admin_update_menu_workbook_pre_meal_choices;
REVOKE ALL ON FUNCTION public.admin_update_menu_workbook_pre_meal_choices(uuid,jsonb,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.admin_update_menu_workbook_i18n(p_store_id uuid,p_categories jsonb,p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE result jsonb; normalized jsonb;
BEGIN
 PERFORM public.require_admin_actor_for_restaurant(p_store_id);
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_items)x WHERE x ? 'meal_choices' AND jsonb_typeof(x->'meal_choices')<>'boolean') THEN RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
 SELECT jsonb_agg(x-'meal_choices') INTO normalized FROM jsonb_array_elements(p_items)x;
 result:=public.admin_update_menu_workbook_pre_meal_choices(p_store_id,p_categories,normalized);
 UPDATE public.menu_items m SET meal_choices=(x->>'meal_choices')::boolean
 FROM jsonb_array_elements(p_items)x WHERE m.id=(x->>'item_id')::uuid AND m.restaurant_id=p_store_id AND m.size_parent_id IS NULL AND x ? 'meal_choices';
 RETURN result;
END $$;
ALTER FUNCTION public.admin_import_menu_items(uuid,jsonb) RENAME TO admin_import_menu_items_pre_meal_choices;
REVOKE ALL ON FUNCTION public.admin_import_menu_items_pre_meal_choices(uuid,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.admin_import_menu_items(p_store_id uuid,p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE result jsonb; normalized jsonb;
BEGIN
 PERFORM public.require_admin_actor_for_restaurant(p_store_id);
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_rows)x WHERE x ? 'meal_choices' AND jsonb_typeof(x->'meal_choices')<>'boolean') THEN RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
 SELECT jsonb_agg(x-'meal_choices') INTO normalized FROM jsonb_array_elements(p_rows)x;
 result:=public.admin_import_menu_items_pre_meal_choices(p_store_id,normalized);
 UPDATE public.menu_items m SET meal_choices=(x->>'meal_choices')::boolean
 FROM jsonb_array_elements(p_rows)x JOIN public.menu_categories c ON c.restaurant_id=p_store_id AND lower(btrim(c.name))=lower(btrim(x->>'category_name'))
 WHERE m.restaurant_id=p_store_id AND m.category_id=c.id AND m.size_parent_id IS NULL AND NOT m.is_archived AND x ? 'meal_choices'
  AND coalesce(m.option_base_names->>'name',m.name)=x->>'name'
  AND m.spice_level=coalesce(x->>'spice_level','unknown') AND m.spice_choice=coalesce(x->>'spice_choice','');
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb),public.admin_import_menu_items(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb),public.admin_import_menu_items(uuid,jsonb) TO authenticated;

-- Existing menus are enrolled through the normal authenticated admin writer.
-- Invoice policy execution must retain the real registering actor; this schema
-- migration never invents an auth context or an invoice approval identity.
DO $$ BEGIN
 IF has_function_privilege('authenticated','public.menu_save_size_prices(uuid,jsonb,jsonb)','EXECUTE')
 OR EXISTS(SELECT 1 FROM public.menu_items p WHERE p.size_parent_id IS NULL AND p.meal_choices AND NOT p.is_archived AND NOT EXISTS
  (SELECT 1 FROM public.menu_items c WHERE c.size_parent_id=p.id AND c.meal_choice='rice' AND c.portion_code=p.portion_code AND NOT c.is_archived))
 THEN RAISE EXCEPTION 'MENU_MEAL_CHOICES_VERIFY_FAILED'; END IF;
END $$;
COMMIT;
