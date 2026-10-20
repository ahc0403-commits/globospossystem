-- production-gate: self-verifying
-- A registered dish owns S/L prices. Historical sellable IDs are internal
-- compatibility projections, not independent catalog registrations.
BEGIN;
ALTER TABLE public.menu_items
 ADD COLUMN size_prices jsonb NOT NULL DEFAULT '{}'::jsonb,
 ADD COLUMN size_parent_id uuid,
 ADD CONSTRAINT menu_size_parent_store_fk FOREIGN KEY(size_parent_id,restaurant_id) REFERENCES public.menu_items(id,restaurant_id);
CREATE INDEX menu_items_size_parent_idx ON public.menu_items(size_parent_id) WHERE size_parent_id IS NOT NULL;
CREATE UNIQUE INDEX menu_items_size_projection_idx ON public.menu_items(size_parent_id,portion_code) WHERE size_parent_id IS NOT NULL;

CREATE FUNCTION public.menu_size_prices_valid(p_prices jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT CASE WHEN p_prices='{}'::jsonb THEN true
  WHEN jsonb_typeof(p_prices)<>'object' THEN false
  WHEN NOT(p_prices ? 'S' AND p_prices ? 'L') OR p_prices-ARRAY['S','L']<>'{}'::jsonb THEN false
  WHEN jsonb_typeof(p_prices->'S')<>'number' OR jsonb_typeof(p_prices->'L')<>'number' THEN false
  ELSE (p_prices->>'S')::numeric>0 AND (p_prices->>'L')::numeric>0 END;
$$;
ALTER TABLE public.menu_items ADD CONSTRAINT menu_size_prices_valid CHECK(public.menu_size_prices_valid(size_prices));
ALTER TABLE public.menu_items ADD CONSTRAINT menu_size_parent_valid CHECK(size_parent_id IS NULL OR (size_parent_id<>id AND size_prices='{}'::jsonb AND portion_code='L'));

CREATE FUNCTION public.menu_size_option_key(p_id uuid,p_parent uuid,p_prices jsonb,p_bases jsonb,p_portion text,p_spice text,p_choice text,p_price numeric)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path=public,pg_catalog AS $$
 SELECT CASE WHEN p_parent IS NULL AND p_prices='{}'::jsonb THEN public.menu_registered_option_key(p_portion,p_spice,p_choice,p_price)
 ELSE jsonb_build_array(p_portion,p_spice,p_choice,p_price,jsonb_build_object('menu_id',coalesce(p_parent,p_id),'names',
  jsonb_build_object('name',public.menu_option_name(p_bases->>'name','',p_spice,p_choice,'ko'),
   'name_ko',public.menu_option_name(p_bases->>'name_ko','',p_spice,p_choice,'ko'),
   'name_vi',public.menu_option_name(p_bases->>'name_vi','',p_spice,p_choice,'vi'),
   'name_en',public.menu_option_name(p_bases->>'name_en','',p_spice,p_choice,'en'))))::text END;
$$;
ALTER TABLE public.menu_items ALTER COLUMN menu_option_key SET EXPRESSION AS
 (public.menu_size_option_key(id,size_parent_id,size_prices,option_base_names,portion_code,spice_level,spice_choice,price));

CREATE FUNCTION public.menu_size_price_before() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_catalog AS $$
BEGIN
 IF NEW.size_prices<>'{}'::jsonb THEN
  IF NEW.restaurant_id<>'273b057e-3b69-46e3-93c1-6194c2802849'::uuid OR NEW.is_combo
   OR NOT public.menu_size_prices_valid(NEW.size_prices) THEN RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
  NEW.portion_code:='S';
  NEW.price:=(NEW.size_prices->>'S')::numeric;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER aa_menu_size_price BEFORE INSERT OR UPDATE ON public.menu_items FOR EACH ROW EXECUTE FUNCTION public.menu_size_price_before();

-- One update JOIN for the entire changed parent batch; no per-menu lookups.
CREATE FUNCTION public.menu_size_price_sync_batch() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF pg_trigger_depth()>1 THEN RETURN NULL; END IF;
 IF EXISTS(SELECT 1 FROM changed_sizes n JOIN public.menu_items p ON p.id=n.size_parent_id
  WHERE n.restaurant_id<>p.restaurant_id OR (NOT n.is_archived AND (p.size_prices='{}'::jsonb OR n.price<>(p.size_prices->>'L')::numeric)))
 THEN RAISE EXCEPTION 'MENU_SIZE_PRICE_MANAGED_BY_PARENT'; END IF;
 UPDATE public.menu_items c SET
  price=CASE WHEN p.size_prices='{}'::jsonb THEN c.price ELSE (p.size_prices->>'L')::numeric END,
  name=p.option_base_names->>'name',name_ko=p.option_base_names->>'name_ko',
  name_vi=p.option_base_names->>'name_vi',name_en=p.option_base_names->>'name_en',
  paperless_name_vi=p.option_base_names->>'paperless_name_vi',
  option_base_names=p.option_base_names,spice_level=p.spice_level,spice_choice=p.spice_choice,
  category_id=p.category_id,description=p.description,image_url=p.image_url,image_storage_path=p.image_storage_path,
  is_available=p.is_available AND p.size_prices<>'{}'::jsonb,
  is_archived=p.is_archived OR p.size_prices='{}'::jsonb,is_visible_public=p.is_visible_public,
  fulfillment_route=p.fulfillment_route,vat_category=p.vat_category,
  beverage_sugar_tax_class=p.beverage_sugar_tax_class,sugar_g_per_100ml=p.sugar_g_per_100ml,
  tax_basis_note=p.tax_basis_note,invoice_sale_unit=p.invoice_sale_unit,updated_at=now()
 FROM changed_sizes p WHERE c.size_parent_id=p.id AND p.size_parent_id IS NULL;
 RETURN NULL;
END $$;
CREATE TRIGGER menu_size_sync_batch AFTER UPDATE ON public.menu_items
 REFERENCING NEW TABLE AS changed_sizes FOR EACH STATEMENT EXECUTE FUNCTION public.menu_size_price_sync_batch();
CREATE TRIGGER menu_size_insert_batch AFTER INSERT ON public.menu_items
 REFERENCING NEW TABLE AS changed_sizes FOR EACH STATEMENT EXECUTE FUNCTION public.menu_size_price_sync_batch();
REVOKE ALL ON FUNCTION public.menu_size_price_before(),public.menu_size_price_sync_batch() FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.menu_save_size_prices(p_item_id uuid,p_prices jsonb,p_tax jsonb DEFAULT NULL)
RETURNS public.menu_items LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE m public.menu_items; c public.menu_items; options jsonb;
BEGIN
 SELECT * INTO m FROM public.menu_items WHERE id=p_item_id FOR UPDATE;
 PERFORM public.require_admin_actor_for_restaurant(m.restaurant_id);
 IF m.id IS NULL OR m.size_parent_id IS NOT NULL OR NOT public.menu_size_prices_valid(p_prices) THEN RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
 IF p_prices<>'{}'::jsonb AND (m.restaurant_id<>'273b057e-3b69-46e3-93c1-6194c2802849'::uuid OR m.is_combo) THEN RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
 UPDATE public.menu_items SET size_prices=p_prices,portion_code=CASE WHEN p_prices='{}'::jsonb THEN '' ELSE 'S' END,updated_at=now()
 WHERE id=p_item_id RETURNING * INTO m;
 IF p_prices<>'{}'::jsonb THEN
  SELECT * INTO c FROM public.menu_items WHERE size_parent_id=p_item_id AND portion_code='L' FOR UPDATE;
  IF c.id IS NULL THEN
   -- This bounded second row projects the L price into existing fulfillment,
   -- recipe and invoice contracts. Operators register only the parent once.
   c:=public.admin_create_menu_item_with_invoice(m.restaurant_id,m.category_id,
    m.option_base_names->>'name_ko',m.option_base_names->>'name_vi',m.option_base_names->>'name_en',m.option_base_names->>'paperless_name_vi',
    (p_prices->>'L')::numeric,m.sort_order,m.is_available,p_tax,m.invoice_sale_unit);
   options:=jsonb_build_object('portion_code','L','spice_level',m.spice_level,'spice_choice',m.spice_choice);
   c:=public.menu_apply_registered_options(c.id,options);
   UPDATE public.menu_items SET size_parent_id=p_item_id,is_visible_public=m.is_visible_public,
    fulfillment_route=m.fulfillment_route WHERE id=c.id;
   UPDATE public.menu_items SET updated_at=now() WHERE id=p_item_id;
  END IF;
 END IF;
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
 VALUES(auth.uid(),'admin_menu_size_prices','menu_items',m.id,jsonb_build_object('store_id',m.restaurant_id,'size_prices',p_prices));
 RETURN m;
END $$;
REVOKE ALL ON FUNCTION public.menu_save_size_prices(uuid,jsonb,jsonb) FROM PUBLIC,anon,authenticated;

ALTER FUNCTION public.admin_create_menu_item_with_options(uuid,uuid,text,text,text,text,numeric,jsonb,integer,boolean,jsonb,text) RENAME TO admin_create_menu_item_pre_size_prices;
REVOKE ALL ON FUNCTION public.admin_create_menu_item_pre_size_prices(uuid,uuid,text,text,text,text,numeric,jsonb,integer,boolean,jsonb,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.admin_create_menu_item_with_options(
 p_store_id uuid,p_category_id uuid,p_name_ko text,p_name_vi text,p_name_en text,p_paperless_name_vi text,
 p_price numeric,p_options jsonb,p_sort_order integer DEFAULT 0,p_is_available boolean DEFAULT true,
 p_tax jsonb DEFAULT NULL,p_invoice_sale_unit text DEFAULT NULL)
RETURNS public.menu_items LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE m public.menu_items; options jsonb:=p_options-'size_prices';
BEGIN
 IF coalesce(p_options->'size_prices','{}')<>'{}'::jsonb THEN options:=options||'{"portion_code":"S"}'::jsonb; END IF;
 m:=public.admin_create_menu_item_pre_size_prices(p_store_id,p_category_id,p_name_ko,p_name_vi,p_name_en,p_paperless_name_vi,p_price,options,p_sort_order,p_is_available,p_tax,p_invoice_sale_unit);
 IF coalesce(p_options->'size_prices','{}')<>'{}'::jsonb THEN m:=public.menu_save_size_prices(m.id,p_options->'size_prices',p_tax); END IF;
 RETURN m;
END $$;
ALTER FUNCTION public.admin_update_menu_item_with_options(uuid,text,text,text,text,numeric,jsonb,jsonb) RENAME TO admin_update_menu_item_pre_size_prices;
REVOKE ALL ON FUNCTION public.admin_update_menu_item_pre_size_prices(uuid,text,text,text,text,numeric,jsonb,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.admin_update_menu_item_with_options(
 p_item_id uuid,p_name_ko text,p_name_vi text,p_name_en text,p_paperless_name_vi text,
 p_price numeric,p_options jsonb,p_tax jsonb DEFAULT NULL)
RETURNS public.menu_items LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE m public.menu_items; options jsonb:=p_options-'size_prices';
BEGIN
 IF EXISTS(SELECT 1 FROM public.menu_items WHERE id=p_item_id AND size_parent_id IS NOT NULL) THEN RAISE EXCEPTION 'MENU_SIZE_PRICE_MANAGED_BY_PARENT'; END IF;
 IF p_options ? 'size_prices' AND (p_options->'size_prices'<>'{}'::jsonb OR EXISTS(SELECT 1 FROM public.menu_items WHERE id=p_item_id AND size_prices<>'{}'::jsonb)) THEN
  m:=public.menu_save_size_prices(p_item_id,p_options->'size_prices',p_tax);
  options:=options||jsonb_build_object('portion_code',CASE WHEN m.size_prices='{}'::jsonb THEN '' ELSE 'S' END);
 END IF;
 m:=public.admin_update_menu_item_pre_size_prices(p_item_id,p_name_ko,p_name_vi,p_name_en,p_paperless_name_vi,p_price,options,p_tax);
 RETURN m;
END $$;
REVOKE ALL ON FUNCTION public.admin_create_menu_item_with_options(uuid,uuid,text,text,text,text,numeric,jsonb,integer,boolean,jsonb,text),public.admin_update_menu_item_with_options(uuid,text,text,text,text,numeric,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_create_menu_item_with_options(uuid,uuid,text,text,text,text,numeric,jsonb,integer,boolean,jsonb,text),public.admin_update_menu_item_with_options(uuid,text,text,text,text,numeric,jsonb,jsonb) TO authenticated;
-- New workbooks contain one row per dish with both prices. Expansion is an
-- internal, bounded set operation into the existing financial compatibility IDs.
ALTER FUNCTION public.admin_import_menu_items(uuid,jsonb) RENAME TO admin_import_menu_items_pre_size_prices;
REVOKE ALL ON FUNCTION public.admin_import_menu_items_pre_size_prices(uuid,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.admin_import_menu_items(p_store_id uuid,p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE expanded jsonb; result jsonb;
BEGIN
 PERFORM public.require_admin_actor_for_restaurant(p_store_id);
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_rows)x WHERE x ? 'size_prices' AND NOT public.menu_size_prices_valid(x->'size_prices'))
 OR (p_store_id<>'273b057e-3b69-46e3-93c1-6194c2802849'::uuid AND EXISTS(SELECT 1 FROM jsonb_array_elements(p_rows)x WHERE coalesce(x->'size_prices','{}')<>'{}'::jsonb)) THEN RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
 SELECT jsonb_agg(x||jsonb_build_object('source_row',(x->>'source_row')::int*10+CASE WHEN o.size='L' THEN 1 ELSE 0 END,
  'portion_code',coalesce(o.size,x->>'portion_code',''),'price',coalesce(o.price,(x->>'price')::numeric)) ORDER BY ord,o.size)
 INTO expanded FROM jsonb_array_elements(p_rows) WITH ORDINALITY raw(x,ord)
 CROSS JOIN LATERAL(SELECT key size,value::text::numeric price FROM jsonb_each(coalesce(x->'size_prices','{}'))
  UNION ALL SELECT NULL::text,NULL::numeric WHERE coalesce(x->'size_prices','{}')='{}'::jsonb)o;
 result:=public.admin_import_menu_items_pre_size_prices(p_store_id,expanded);
 WITH source AS(SELECT x,c.id category_id FROM jsonb_array_elements(p_rows)x JOIN public.menu_categories c
  ON c.restaurant_id=p_store_id AND lower(btrim(c.name))=lower(btrim(x->>'category_name'))
  WHERE coalesce(x->'size_prices','{}')<>'{}'::jsonb)
 UPDATE public.menu_items m SET size_prices=s.x->'size_prices'
 FROM source s WHERE m.restaurant_id=p_store_id AND m.category_id=s.category_id AND m.portion_code='S'
  AND m.option_base_names->>'name'=s.x->>'name' AND m.spice_level=coalesce(s.x->>'spice_level','unknown') AND m.spice_choice=coalesce(s.x->>'spice_choice','');
 UPDATE public.menu_items c SET size_parent_id=p.id FROM public.menu_items p
 WHERE p.restaurant_id=p_store_id AND p.size_prices<>'{}'::jsonb AND c.restaurant_id=p.restaurant_id
  AND c.category_id=p.category_id AND c.portion_code='L' AND c.size_parent_id IS NULL
  AND c.option_base_names->>'name'=p.option_base_names->>'name' AND c.spice_level=p.spice_level AND c.spice_choice=p.spice_choice
  AND EXISTS(SELECT 1 FROM jsonb_array_elements(p_rows)x WHERE coalesce(x->'size_prices','{}')<>'{}'::jsonb AND x->>'name'=p.option_base_names->>'name');
 RETURN result||jsonb_build_object('item_count',jsonb_array_length(p_rows));
END $$;
REVOKE ALL ON FUNCTION public.admin_import_menu_items(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_import_menu_items(uuid,jsonb) TO authenticated;

ALTER FUNCTION public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb) RENAME TO admin_update_menu_workbook_pre_size_prices;
REVOKE ALL ON FUNCTION public.admin_update_menu_workbook_pre_size_prices(uuid,jsonb,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.admin_update_menu_workbook_i18n(p_store_id uuid,p_categories jsonb,p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE result jsonb; normalized jsonb;
BEGIN
 PERFORM public.require_admin_actor_for_restaurant(p_store_id);
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_items)x JOIN public.menu_items m ON m.id=(x->>'item_id')::uuid AND m.restaurant_id=p_store_id
  WHERE m.size_parent_id IS NOT NULL OR (x ? 'size_prices' AND (NOT public.menu_size_prices_valid(x->'size_prices')
   OR (x->'size_prices'<>'{}'::jsonb AND m.size_prices='{}'::jsonb)))) THEN RAISE EXCEPTION 'MENU_WORKBOOK_SIZE_USE_EDITOR'; END IF;
 UPDATE public.menu_items m SET size_prices=x->'size_prices',portion_code=CASE WHEN x->'size_prices'='{}'::jsonb THEN '' ELSE 'S' END
 FROM jsonb_array_elements(p_items)x WHERE m.id=(x->>'item_id')::uuid AND m.restaurant_id=p_store_id AND x ? 'size_prices';
 SELECT jsonb_agg(x||CASE WHEN coalesce(x->'size_prices','{}')<>'{}'::jsonb THEN jsonb_build_object('portion_code','S','price',x->'size_prices'->'S') ELSE '{}'::jsonb END)
 INTO normalized FROM jsonb_array_elements(p_items)x;
 result:=public.admin_update_menu_workbook_pre_size_prices(p_store_id,p_categories,normalized);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb) TO authenticated;

DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='menu_size_sync_batch' AND NOT tgisinternal)
 OR has_function_privilege('authenticated','public.menu_save_size_prices(uuid,jsonb,jsonb)','EXECUTE') THEN RAISE EXCEPTION 'MENU_SIZE_PRICE_VERIFY_FAILED'; END IF;
END $$;
COMMIT;
