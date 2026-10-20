-- production-gate: self-verifying
-- Additive catalog contract. No existing menu/price/history is backfilled.
-- S/L and permitted spice choices are individually registered sellable menu IDs.
BEGIN;
CREATE TEMP TABLE menu_options_existing_before ON COMMIT DROP AS
 SELECT md5(jsonb_agg(to_jsonb(m) ORDER BY m.id)::text) digest FROM public.menu_items m;
ALTER TABLE public.menu_items
 ADD COLUMN portion_code text NOT NULL DEFAULT '' CHECK (portion_code IN ('','S','L')),
 ADD COLUMN spice_level text NOT NULL DEFAULT 'unknown' CHECK (spice_level IN ('unknown','not_spicy','spicy')),
 ADD COLUMN spice_choice text NOT NULL DEFAULT '' CHECK (length(spice_choice)<=60),
 ADD COLUMN option_base_names jsonb NOT NULL DEFAULT '{}'::jsonb;
CREATE FUNCTION public.menu_registered_option_key(p_portion text,p_spice text,p_choice text,p_price numeric)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT CASE WHEN p_portion<>'' OR p_spice<>'unknown' OR p_choice<>'' THEN
  jsonb_build_array(p_portion,p_spice,p_choice,p_price)::text END;
$$;
ALTER TABLE public.menu_items ADD COLUMN menu_option_key text GENERATED ALWAYS AS
 (public.menu_registered_option_key(portion_code,spice_level,spice_choice,price)) STORED;
ALTER TABLE public.order_items ADD COLUMN menu_option_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE public.direct_order_request_items ADD COLUMN menu_option_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE FUNCTION public.menu_option_name(p_name text,p_portion text,p_spice text,p_choice text,p_language text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT CASE WHEN p_name IS NULL OR btrim(p_name)='' THEN p_name ELSE concat_ws(' · ',
   nullif(p_portion,''),
   CASE p_spice WHEN 'spicy' THEN CASE p_language WHEN 'vi' THEN '🌶 Món cay' WHEN 'en' THEN '🌶 Spicy dish' ELSE '🌶 매운 메뉴' END
    WHEN 'not_spicy' THEN CASE p_language WHEN 'vi' THEN 'Không cay' WHEN 'en' THEN 'Not spicy' ELSE '안 매움' END END,
   nullif(p_choice,''),p_name) END;
$$;

-- Compatibility names carry the same registered choice through older clients,
-- public JSON allowlists, printer payloads, combo snapshots and offline queues.
-- Structured fields remain the authority, rather than parsing the display name.
CREATE FUNCTION public.menu_apply_option_names() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_catalog AS $$
DECLARE bases jsonb; k text; n text; old_n text; lang text;
BEGIN
 IF NEW.portion_code='' AND NEW.spice_level='unknown' AND NEW.spice_choice='' AND NEW.option_base_names='{}'::jsonb THEN RETURN NEW; END IF;
 bases:=NEW.option_base_names;
 FOREACH k IN ARRAY ARRAY['name','name_ko','name_vi','name_en','paperless_name_vi'] LOOP
  n:=to_jsonb(NEW)->>k;
  IF TG_OP='UPDATE' THEN
   old_n:=to_jsonb(OLD)->>k;
   IF n IS NOT DISTINCT FROM old_n AND OLD.option_base_names ? k THEN n:=OLD.option_base_names->>k; END IF;
  END IF;
  bases:=bases||jsonb_build_object(k,n);
  lang:=CASE WHEN k IN ('name_vi','paperless_name_vi') THEN 'vi' WHEN k='name_en' THEN 'en' ELSE 'ko' END;
  NEW:=jsonb_populate_record(NEW,jsonb_build_object(k,public.menu_option_name(n,NEW.portion_code,NEW.spice_level,NEW.spice_choice,lang)));
 END LOOP;
 NEW.option_base_names:=bases;
 RETURN NEW;
END $$;
CREATE TRIGGER zz_menu_option_names BEFORE INSERT OR UPDATE ON public.menu_items
 FOR EACH ROW EXECUTE FUNCTION public.menu_apply_option_names();
REVOKE ALL ON FUNCTION public.menu_apply_option_names() FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.menu_apply_registered_options(p_item_id uuid,p_options jsonb)
RETURNS public.menu_items LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE m public.menu_items; store_id uuid;
BEGIN
 SELECT restaurant_id INTO store_id FROM public.menu_items WHERE id=p_item_id;
 PERFORM public.require_admin_actor_for_restaurant(store_id);
 IF p_options IS NULL OR jsonb_typeof(p_options)<>'object' OR
    EXISTS(SELECT 1 FROM jsonb_object_keys(p_options)k WHERE k NOT IN ('portion_code','spice_level','spice_choice')) OR
    coalesce(p_options->>'portion_code','') NOT IN ('','S','L') OR
    coalesce(p_options->>'spice_level','unknown') NOT IN ('unknown','not_spicy','spicy') OR
    length(coalesce(p_options->>'spice_choice',''))>60 THEN RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
 UPDATE public.menu_items SET portion_code=coalesce(p_options->>'portion_code',''),
  spice_level=coalesce(p_options->>'spice_level','unknown'),spice_choice=btrim(coalesce(p_options->>'spice_choice','')),updated_at=now()
 WHERE id=p_item_id RETURNING * INTO m;
 RETURN m;
END $$;
REVOKE ALL ON FUNCTION public.menu_apply_registered_options(uuid,jsonb) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.admin_create_menu_item_with_options(
 p_store_id uuid,p_category_id uuid,p_name_ko text,p_name_vi text,p_name_en text,p_paperless_name_vi text,
 p_price numeric,p_options jsonb,p_sort_order integer DEFAULT 0,p_is_available boolean DEFAULT true,
 p_tax jsonb DEFAULT NULL,p_invoice_sale_unit text DEFAULT NULL)
RETURNS public.menu_items LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE m public.menu_items;
BEGIN
 m:=public.admin_create_menu_item_with_invoice(p_store_id,p_category_id,p_name_ko,p_name_vi,p_name_en,p_paperless_name_vi,p_price,p_sort_order,p_is_available,p_tax,p_invoice_sale_unit);
 m:=public.menu_apply_registered_options(m.id,p_options);
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
 VALUES(auth.uid(),'admin_menu_options','menu_items',m.id,jsonb_build_object('store_id',p_store_id,'options',p_options));
 RETURN m;
END $$;
CREATE FUNCTION public.admin_update_menu_item_with_options(
 p_item_id uuid,p_name_ko text,p_name_vi text,p_name_en text,p_paperless_name_vi text,
 p_price numeric,p_options jsonb,p_tax jsonb DEFAULT NULL)
RETURNS public.menu_items LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE m public.menu_items;
BEGIN
 m:=public.admin_update_menu_item_i18n_paperless(p_item_id,p_name_ko,p_name_vi,p_name_en,p_paperless_name_vi,p_price);
 IF p_tax IS NOT NULL THEN m:=public.admin_set_menu_beverage_tax(p_item_id,p_tax); END IF;
 m:=public.menu_apply_registered_options(p_item_id,p_options);
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
 VALUES(auth.uid(),'admin_menu_options','menu_items',m.id,jsonb_build_object('store_id',m.restaurant_id,'options',p_options));
 RETURN m;
END $$;
REVOKE ALL ON FUNCTION public.admin_create_menu_item_with_options(uuid,uuid,text,text,text,text,numeric,jsonb,integer,boolean,jsonb,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.admin_update_menu_item_with_options(uuid,text,text,text,text,numeric,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_create_menu_item_with_options(uuid,uuid,text,text,text,text,numeric,jsonb,integer,boolean,jsonb,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_menu_item_with_options(uuid,text,text,text,text,numeric,jsonb,jsonb) TO authenticated;

-- One statement-level JOIN per insert batch; never a menu lookup per item.
-- Existing unconfigured menus retain all pricing and service-item semantics.
CREATE FUNCTION public.capture_menu_option_batch() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF TG_TABLE_NAME='order_items' THEN
  -- Cashier splits copy the original immutable row; never reprice or replace it.
  IF current_setting('globos.cashier_item_mutation',true)='on' THEN RETURN NULL; END IF;
  IF EXISTS(SELECT 1 FROM new_menu_lines n JOIN public.menu_items m ON m.id=n.menu_item_id
    WHERE (m.portion_code<>'' OR m.spice_level<>'unknown' OR m.spice_choice<>'')
     AND (n.restaurant_id<>m.restaurant_id OR NOT m.is_available OR m.is_archived
      OR (NOT n.is_service_item AND n.unit_price<>m.price))) THEN RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
  UPDATE public.order_items o SET menu_option_snapshot=jsonb_build_object(
    'menu_item_id',m.id,'portion_code',m.portion_code,'spice_level',m.spice_level,'spice_choice',m.spice_choice,
    'unit_price',n.unit_price,'name_ko',m.name_ko,'name_vi',m.name_vi,'name_en',m.name_en),
    label=m.name,display_name=m.name
  FROM new_menu_lines n JOIN public.menu_items m ON m.id=n.menu_item_id
  WHERE o.id=n.id AND (m.portion_code<>'' OR m.spice_level<>'unknown' OR m.spice_choice<>'');
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
    'menu_item_id',m.id,'portion_code',m.portion_code,'spice_level',m.spice_level,'spice_choice',m.spice_choice,
    'unit_price',n.unit_price,'name_ko',n.name_ko,'name_vi',n.name_vi,'name_en',n.name_en)
  FROM new_menu_lines n JOIN public.menu_items m ON m.id=n.menu_item_id AND m.restaurant_id=n.restaurant_id
  WHERE o.id=n.id AND (m.portion_code<>'' OR m.spice_level<>'unknown' OR m.spice_choice<>'');
 END IF;

 -- Component choices are keyed by their stable sellable ID in the order-time
 -- snapshot. One aggregate JOIN covers the complete inserted batch.
 IF TG_TABLE_NAME='order_items' AND nullif(current_setting('app.direct_order_request_id',true),'') IS NULL THEN
  WITH parts AS (
   SELECT n.id,jsonb_object_agg(m.id::text,jsonb_build_object('menu_item_id',m.id,
    'portion_code',m.portion_code,'spice_level',m.spice_level,'spice_choice',m.spice_choice,
    'name_ko',coalesce(c->>'name_ko',m.name_ko),'name_vi',coalesce(c->>'name_vi',m.name_vi),
    'name_en',coalesce(c->>'name_en',m.name_en),'unit_price',coalesce(c->'tax_unit_price',to_jsonb(m.price)))) data
   FROM new_menu_lines n CROSS JOIN LATERAL jsonb_array_elements(coalesce(n.combo_components,'[]'))c
   JOIN public.menu_items m ON m.id=(c->>'menu_item_id')::uuid AND m.restaurant_id=n.restaurant_id
   WHERE m.menu_option_key IS NOT NULL GROUP BY n.id
  ) UPDATE public.order_items o SET menu_option_snapshot=
   CASE WHEN o.menu_option_snapshot='{}'::jsonb THEN jsonb_build_object('menu_item_id',m.id,
    'portion_code',m.portion_code,'spice_level',m.spice_level,'spice_choice',m.spice_choice,
    'name_ko',m.name_ko,'name_vi',m.name_vi,'name_en',m.name_en,'unit_price',o.unit_price)
    ELSE o.menu_option_snapshot END || jsonb_build_object('components',p.data)
   FROM parts p,new_menu_lines n,public.menu_items m WHERE o.id=p.id AND n.id=o.id AND m.id=n.menu_item_id;
 ELSIF TG_TABLE_NAME='direct_order_request_items' THEN
  WITH parts AS (
   SELECT n.id,jsonb_object_agg(m.id::text,jsonb_build_object('menu_item_id',m.id,
    'portion_code',m.portion_code,'spice_level',m.spice_level,'spice_choice',m.spice_choice,
    'name_ko',coalesce(c->>'name_ko',m.name_ko),'name_vi',coalesce(c->>'name_vi',m.name_vi),
    'name_en',coalesce(c->>'name_en',m.name_en),'unit_price',coalesce(c->'tax_unit_price',to_jsonb(m.price)))) data
   FROM new_menu_lines n CROSS JOIN LATERAL jsonb_array_elements(coalesce(n.combo_components,'[]'))c
   JOIN public.menu_items m ON m.id=(c->>'menu_item_id')::uuid AND m.restaurant_id=n.restaurant_id
   WHERE m.menu_option_key IS NOT NULL GROUP BY n.id
  ) UPDATE public.direct_order_request_items o SET menu_option_snapshot=
   CASE WHEN o.menu_option_snapshot='{}'::jsonb THEN jsonb_build_object('menu_item_id',m.id,
    'portion_code',m.portion_code,'spice_level',m.spice_level,'spice_choice',m.spice_choice,
    'name_ko',m.name_ko,'name_vi',m.name_vi,'name_en',m.name_en,'unit_price',o.unit_price)
    ELSE o.menu_option_snapshot END || jsonb_build_object('components',p.data)
   FROM parts p,new_menu_lines n,public.menu_items m WHERE o.id=p.id AND n.id=o.id AND m.id=n.menu_item_id;
 END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER menu_option_capture_batch AFTER INSERT ON public.order_items
 REFERENCING NEW TABLE AS new_menu_lines FOR EACH STATEMENT EXECUTE FUNCTION public.capture_menu_option_batch();
CREATE TRIGGER menu_option_capture_batch AFTER INSERT ON public.direct_order_request_items
 REFERENCING NEW TABLE AS new_menu_lines FOR EACH STATEMENT EXECUTE FUNCTION public.capture_menu_option_batch();
REVOKE ALL ON FUNCTION public.capture_menu_option_batch() FROM PUBLIC,anon,authenticated;

-- Workbook omissions preserve existing options. Explicit blank resets portion/
-- choice; unknown resets spiciness. Bulk update remains a single source JOIN.
CREATE FUNCTION public.menu_apply_option_workbook(p_store_id uuid,p_items jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 PERFORM public.require_admin_actor_for_restaurant(p_store_id);
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_items)x WHERE
  (x ? 'portion_code' AND coalesce(x->>'portion_code','') NOT IN ('','S','L')) OR
  (x ? 'spice_level' AND coalesce(x->>'spice_level','unknown') NOT IN ('unknown','not_spicy','spicy')) OR
  length(coalesce(x->>'spice_choice',''))>60) THEN RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
 UPDATE public.menu_items m SET
  portion_code=CASE WHEN x ? 'portion_code' THEN coalesce(x->>'portion_code','') ELSE m.portion_code END,
  spice_level=CASE WHEN x ? 'spice_level' THEN coalesce(x->>'spice_level','unknown') ELSE m.spice_level END,
  spice_choice=CASE WHEN x ? 'spice_choice' THEN btrim(coalesce(x->>'spice_choice','')) ELSE m.spice_choice END
 FROM jsonb_array_elements(p_items)x
 WHERE m.id=(x->>'item_id')::uuid AND m.restaurant_id=p_store_id
  AND (x ? 'portion_code' OR x ? 'spice_level' OR x ? 'spice_choice');
END $$;
REVOKE ALL ON FUNCTION public.menu_apply_option_workbook(uuid,jsonb) FROM PUBLIC,anon,authenticated;
ALTER FUNCTION public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb) RENAME TO admin_update_menu_workbook_pre_options;
REVOKE ALL ON FUNCTION public.admin_update_menu_workbook_pre_options(uuid,jsonb,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.admin_update_menu_workbook_i18n(p_store_id uuid,p_categories jsonb,p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE result jsonb;
BEGIN
 result:=public.admin_update_menu_workbook_pre_options(p_store_id,p_categories,p_items);
 PERFORM public.menu_apply_option_workbook(p_store_id,p_items);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb) TO authenticated;

ALTER FUNCTION public.admin_import_menu_items(uuid,jsonb) RENAME TO admin_import_menu_items_pre_options;
REVOKE ALL ON FUNCTION public.admin_import_menu_items_pre_options(uuid,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.admin_import_menu_items(p_store_id uuid,p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE normalized jsonb; mapped jsonb; result jsonb;
BEGIN
 PERFORM public.require_admin_actor_for_restaurant(p_store_id);
 -- Stable import identity is the complete sellable choice, avoiding S/L name
 -- collisions in the pre-existing import contract.
 SELECT jsonb_agg(x||jsonb_build_object('name',public.menu_option_name(x->>'name',coalesce(x->>'portion_code',''),coalesce(x->>'spice_level','unknown'),coalesce(x->>'spice_choice',''),'ko'))) INTO normalized
 FROM jsonb_array_elements(p_rows)x;
 result:=public.admin_import_menu_items_pre_options(p_store_id,normalized);
 SELECT coalesce(jsonb_agg(x||jsonb_build_object('item_id',m.id) ORDER BY (x->>'source_row')::int),'[]') INTO mapped
 FROM jsonb_array_elements(normalized)x
 JOIN public.menu_categories c ON c.restaurant_id=p_store_id AND lower(btrim(c.name))=lower(btrim(x->>'category_name'))
 JOIN public.menu_items m ON m.restaurant_id=p_store_id AND m.category_id=c.id AND NOT m.is_archived AND lower(btrim(m.name))=lower(btrim(x->>'name'));
 -- Strip only the display compatibility suffix using the original input row;
 -- persist base names before applying the structured choice exactly once.
 UPDATE public.menu_items m SET name=x->>'name',name_ko=x->>'name',
   name_vi=coalesce(nullif(x->>'name_vi',''),m.name_vi),
   name_en=coalesce(nullif(x->>'name_en',''),x->>'name')
 FROM jsonb_array_elements(p_rows) raw(x)
 JOIN jsonb_array_elements(mapped) target(y) ON y->>'source_row'=x->>'source_row'
 WHERE m.id=(y->>'item_id')::uuid AND m.restaurant_id=p_store_id;
 PERFORM public.menu_apply_option_workbook(p_store_id,mapped);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.admin_import_menu_items(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_import_menu_items(uuid,jsonb) TO authenticated;

-- Snapshot names on KDS use order-time data even after a menu edit. One set JOIN
-- over visible lines; components already have their own immutable name snapshots.
ALTER FUNCTION public.emergency_enrich_start_ready_orders(jsonb) RENAME TO emergency_enrich_start_ready_orders_pre_options;
REVOKE ALL ON FUNCTION public.emergency_enrich_start_ready_orders_pre_options(jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.emergency_enrich_start_ready_orders(p_orders jsonb)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH orders AS MATERIALIZED (
  SELECT value,ordinality ord FROM jsonb_array_elements(public.emergency_enrich_start_ready_orders_pre_options(p_orders)) WITH ORDINALITY
 ), lines AS (
  SELECT o.ord,i.ordinality,jsonb_strip_nulls(i.value || CASE WHEN coalesce(frozen.snapshot,'{}'::jsonb)<>'{}'::jsonb THEN
    jsonb_build_object('menu_option_snapshot',frozen.snapshot,'name_ko',frozen.snapshot->>'name_ko','name_vi',frozen.snapshot->>'name_vi','name_en',frozen.snapshot->>'name_en') ELSE '{}'::jsonb END) value
  FROM orders o CROSS JOIN LATERAL jsonb_array_elements(o.value->'items') WITH ORDINALITY i(value,ordinality)
  LEFT JOIN public.order_items s ON s.id=nullif(coalesce(i.value->>'order_item_id',i.value->>'id'),'')::uuid
  CROSS JOIN LATERAL(SELECT CASE WHEN i.value->>'source_kind'='combo_component' THEN
   s.menu_option_snapshot->'components'->split_part(i.value->>'line_key',':',2) ELSE s.menu_option_snapshot END snapshot) frozen
 ), grouped AS (SELECT ord,jsonb_agg(value ORDER BY ordinality) items FROM lines GROUP BY ord)
 SELECT coalesce(jsonb_agg(o.value||jsonb_build_object('items',coalesce(g.items,'[]')) ORDER BY o.ord),'[]') FROM orders o LEFT JOIN grouped g USING(ord);
$$;
REVOKE ALL ON FUNCTION public.emergency_enrich_start_ready_orders(jsonb) FROM PUBLIC,anon,authenticated;

-- Eliminate catalog N+1 in the active QR combo validator and the per-line
-- INSERT loop in the QR kernel. All unrelated guards, idempotency and locks stay.
CREATE FUNCTION pg_temp.menu_patch(sig text,old_text text,new_text text) RETURNS void
LANGUAGE plpgsql AS $patch$
DECLARE body text;
BEGIN
 body:=pg_get_functiondef(to_regprocedure(sig));
 IF body IS NULL OR (length(body)-length(replace(body,old_text,'')))/length(old_text)<>1 THEN
  RAISE EXCEPTION 'MENU_RELEASE_FUNCTION_DRIFT: %',sig;
 END IF;
 EXECUTE replace(body,old_text,new_text);
END $patch$;
SELECT pg_temp.menu_patch('public.qr_place_order(text,jsonb,uuid,boolean)',$old$  FOR v_line IN SELECT raw FROM jsonb_array_elements(v_items) line(raw)
  LOOP
    IF COALESCE(v_line.raw->>'menu_item_id', '')
         !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR COALESCE(v_line.raw->>'quantity', '') !~ '^[0-9]+$'
       OR (v_line.raw ? 'is_takeout'
         AND jsonb_typeof(v_line.raw->'is_takeout') <> 'boolean') THEN
      RAISE EXCEPTION 'QR_ITEMS_INVALID';
    END IF;

    IF jsonb_typeof(COALESCE(v_line.raw->'combo_drink_choices', '[]'::jsonb))
         <> 'array' THEN
      RAISE EXCEPTION 'QR_COMBO_DRINK_CHOICES_INVALID';
    END IF;

    v_choice_count := jsonb_array_length(
      COALESCE(v_line.raw->'combo_drink_choices', '[]'::jsonb)
    );
    v_expected_count := public.combo_drink_choice_count(
      (v_line.raw->>'menu_item_id')::uuid
    ) * (v_line.raw->>'quantity')::integer;

    IF v_choice_count <> v_expected_count THEN
      RAISE EXCEPTION 'QR_COMBO_DRINK_CHOICES_INVALID';
    END IF;

    IF v_choice_count > 0 AND EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(v_line.raw->'combo_drink_choices') choice(value)
      LEFT JOIN public.menu_items option_item
        ON option_item.id = CASE
             WHEN choice.value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
             THEN choice.value::uuid ELSE NULL
           END
       AND option_item.restaurant_id = v_table.restaurant_id
       AND option_item.is_archived = false
       AND option_item.is_available = true
       AND option_item.is_visible_public = true
       AND option_item.is_combo = false
      LEFT JOIN public.menu_categories drink_category
        ON drink_category.id = option_item.category_id
       AND drink_category.restaurant_id = v_table.restaurant_id
       AND drink_category.system_key = 'drink'
       AND drink_category.is_active = true
      WHERE option_item.id IS NULL OR drink_category.id IS NULL
    ) THEN
      RAISE EXCEPTION 'QR_COMBO_DRINK_CHOICES_INVALID';
    END IF;
  END LOOP;$old$,$new$  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) line(raw)
    WHERE coalesce(raw->>'menu_item_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      OR coalesce(raw->>'quantity','') !~ '^[0-9]+$'
      OR (raw ? 'is_takeout' AND jsonb_typeof(raw->'is_takeout')<>'boolean')) THEN
    RAISE EXCEPTION 'QR_ITEMS_INVALID';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_items) line(raw)
    WHERE jsonb_typeof(coalesce(raw->'combo_drink_choices','[]'))<>'array') THEN
    RAISE EXCEPTION 'QR_COMBO_DRINK_CHOICES_INVALID';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_items) line(raw)
    LEFT JOIN public.menu_items menu ON menu.id=(raw->>'menu_item_id')::uuid
    WHERE jsonb_array_length(coalesce(raw->'combo_drink_choices','[]'))<>
      CASE WHEN menu.is_combo THEN coalesce(menu.combo_drink_choice_count,0) ELSE 0 END*(raw->>'quantity')::integer) THEN
    RAISE EXCEPTION 'QR_COMBO_DRINK_CHOICES_INVALID';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_items) line(raw)
    CROSS JOIN LATERAL jsonb_array_elements_text(coalesce(raw->'combo_drink_choices','[]')) choice(value)
    LEFT JOIN public.menu_items option_item ON option_item.id=CASE
      WHEN choice.value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN choice.value::uuid ELSE NULL END
      AND option_item.restaurant_id=v_table.restaurant_id AND NOT option_item.is_archived
      AND option_item.is_available AND option_item.is_visible_public AND NOT option_item.is_combo
    LEFT JOIN public.menu_categories drink_category ON drink_category.id=option_item.category_id
      AND drink_category.restaurant_id=v_table.restaurant_id AND drink_category.system_key='drink' AND drink_category.is_active
    WHERE option_item.id IS NULL OR drink_category.id IS NULL) THEN
    RAISE EXCEPTION 'QR_COMBO_DRINK_CHOICES_INVALID';
  END IF;$new$);
SELECT pg_temp.menu_patch('public.qr_place_order_pre_takeout_core(text,jsonb,uuid)',$old$  FOR v_line IN
    SELECT item.raw, item.ord
    FROM jsonb_array_elements(v_items_snapshot)
      WITH ORDINALITY AS item(raw, ord)
    ORDER BY item.ord
  LOOP
    INSERT INTO public.order_items (
      order_id,
      menu_item_id,
      quantity,
      unit_price,
      label,
      display_name,
      restaurant_id,
      item_type
    )
    VALUES (
      v_order_id,
      (v_line.raw->>'menu_item_id')::uuid,
      (v_line.raw->>'quantity')::int,
      (v_line.raw->>'unit_price')::numeric,
      v_line.raw->>'name',
      v_line.raw->>'name',
      v_table.restaurant_id,
      'menu_item'
    )
    RETURNING * INTO v_inserted_item;

    v_print_items := v_print_items || jsonb_build_array(
      jsonb_build_object(
        'item_id', v_inserted_item.id::text,
        'menu_item_id', v_inserted_item.menu_item_id::text,
        'label', COALESCE(
          NULLIF(v_inserted_item.label, ''),
          NULLIF(v_inserted_item.display_name, ''),
          'Item'
        ),
        'quantity', v_inserted_item.quantity,
        'notes', v_inserted_item.notes,
        'supplemental', NOT v_is_new_order
      )
    );
  END LOOP;$old$,$new$  WITH input AS MATERIALIZED (
    SELECT gen_random_uuid() id,raw,ord FROM jsonb_array_elements(v_items_snapshot) WITH ORDINALITY item(raw,ord)
  ), inserted AS (
    INSERT INTO public.order_items(id,order_id,menu_item_id,quantity,unit_price,label,display_name,restaurant_id,item_type)
    SELECT id,v_order_id,(raw->>'menu_item_id')::uuid,(raw->>'quantity')::int,
      (raw->>'unit_price')::numeric,raw->>'name',raw->>'name',v_table.restaurant_id,'menu_item'
    FROM input ORDER BY ord RETURNING *
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('item_id',i.id::text,'menu_item_id',i.menu_item_id::text,
    'label',coalesce(nullif(i.label,''),nullif(i.display_name,''),'Item'),'quantity',i.quantity,
    'notes',i.notes,'supplemental',NOT v_is_new_order) ORDER BY src.ord),'[]')
  INTO v_print_items FROM inserted i JOIN input src ON src.id=i.id;$new$);


-- Catalog choices carry an opaque option/price key. Old unconfigured menus do
-- not gain response keys. A stale/offline cart cannot silently change spice or
-- price after an administrator edits the same menu ID.
CREATE FUNCTION public.menu_enrich_catalog_options(p_catalog jsonb) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT CASE WHEN p_catalog IS NULL THEN NULL ELSE p_catalog||jsonb_build_object('items',
  (SELECT coalesce(jsonb_agg(i.value||CASE WHEN m.menu_option_key IS NOT NULL THEN
    jsonb_build_object('menu_option_key',m.menu_option_key) ELSE '{}'::jsonb END ORDER BY i.ordinality),'[]')
   FROM jsonb_array_elements(p_catalog->'items') WITH ORDINALITY i(value,ordinality)
   LEFT JOIN public.menu_items m ON m.id=(i.value->>'id')::uuid AND m.restaurant_id=(p_catalog->>'store_id')::uuid)) END;
$$;
REVOKE ALL ON FUNCTION public.menu_enrich_catalog_options(jsonb) FROM PUBLIC,anon,authenticated;
ALTER FUNCTION public.qr_get_menu(text) RENAME TO qr_get_menu_pre_options;
REVOKE ALL ON FUNCTION public.qr_get_menu_pre_options(text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.qr_get_menu(p_token text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT public.menu_enrich_catalog_options(public.qr_get_menu_pre_options(p_token));
$$;
REVOKE ALL ON FUNCTION public.qr_get_menu(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qr_get_menu(text) TO anon,authenticated;
ALTER FUNCTION public.direct_order_public_storefront(text) RENAME TO direct_order_public_storefront_pre_options;
REVOKE ALL ON FUNCTION public.direct_order_public_storefront_pre_options(text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_public_storefront(p_slug text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT public.menu_enrich_catalog_options(public.direct_order_public_storefront_pre_options(p_slug));
$$;
REVOKE ALL ON FUNCTION public.direct_order_public_storefront(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_storefront(text) TO service_role;
ALTER FUNCTION public.direct_order_public_storefront_v3(text,integer,uuid,integer) RENAME TO direct_order_public_storefront_v3_pre_options;
REVOKE ALL ON FUNCTION public.direct_order_public_storefront_v3_pre_options(text,integer,uuid,integer) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_public_storefront_v3(p_slug text,p_after_sort integer DEFAULT NULL,p_after_id uuid DEFAULT NULL,p_limit integer DEFAULT 200) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT public.menu_enrich_catalog_options(public.direct_order_public_storefront_v3_pre_options(p_slug,p_after_sort,p_after_id,p_limit));
$$;
REVOKE ALL ON FUNCTION public.direct_order_public_storefront_v3(text,integer,uuid,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_storefront_v3(text,integer,uuid,integer) TO service_role;

CREATE FUNCTION public.validate_menu_option_batch(p_store_id uuid,p_items jsonb,p_channel text) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF jsonb_typeof(p_items)='array' THEN
  PERFORM m.id FROM public.menu_items m JOIN (
   SELECT DISTINCT CASE WHEN x->>'menu_item_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN (x->>'menu_item_id')::uuid END id
   FROM jsonb_array_elements(p_items)x) ids ON ids.id=m.id
   WHERE m.restaurant_id=p_store_id ORDER BY m.id FOR SHARE OF m;
 END IF;
 IF jsonb_typeof(p_items)='array' AND EXISTS(
  SELECT 1 FROM jsonb_array_elements(p_items)x JOIN public.menu_items m
   ON m.id=CASE WHEN x->>'menu_item_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN (x->>'menu_item_id')::uuid END
   AND m.restaurant_id=p_store_id
  WHERE x->>'menu_option_key' IS DISTINCT FROM m.menu_option_key
 ) THEN
  IF p_channel='direct' THEN RAISE EXCEPTION 'DIRECT_ORDER_MENU_CHANGED';
  ELSIF p_channel='qr' THEN RAISE EXCEPTION 'QR_MENU_ITEM_UNAVAILABLE';
  ELSE RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
 END IF;
END $$;
REVOKE ALL ON FUNCTION public.validate_menu_option_batch(uuid,jsonb,text) FROM PUBLIC,anon,authenticated;
SELECT pg_temp.menu_patch('public.create_order(uuid,uuid,jsonb)',
 $old$  PERFORM public.ensure_store_operational_day(p_store_id);$old$,
 $new$  PERFORM public.validate_menu_option_batch(p_store_id,p_items,'pos');
  PERFORM public.ensure_store_operational_day(p_store_id);$new$);
SELECT pg_temp.menu_patch('public.add_items_to_order(uuid,uuid,jsonb)',
 $old$  RETURN QUERY
  SELECT *$old$,
 $new$  PERFORM public.validate_menu_option_batch(p_store_id,p_items,'pos');
  RETURN QUERY
  SELECT *$new$);
SELECT pg_temp.menu_patch('public.qr_place_order(text,jsonb,uuid,boolean)',
 $old$  PERFORM set_config('pos.qr_combo_payload', v_items::text, true);$old$,
 $new$  PERFORM public.validate_menu_option_batch(v_table.restaurant_id,v_items,'qr');
  PERFORM set_config('pos.qr_combo_payload', v_items::text, true);$new$);
SELECT pg_temp.menu_patch('public.direct_order_prepare_combo_items(uuid,jsonb)',
 $old$ -- Stable lock order covers parent menus, fixed components and chosen drinks.$old$,
 $new$ PERFORM public.validate_menu_option_batch(p_store_id,p_items,'direct');
 -- Stable lock order covers parent menus, fixed components and chosen drinks.$new$);


-- Additional POS items share the same one-insert batch contract. Read back only
-- inserted IDs after statement snapshots finish, preserving the SETOF response.
SELECT pg_temp.menu_patch('public.add_items_to_order_pre_takeout_core(uuid,uuid,jsonb)',
 $old$  v_inserted_count int := 0;$old$,$new$  v_inserted_count int := 0;
  v_result_ids jsonb;$new$);
SELECT pg_temp.menu_patch('public.add_items_to_order_pre_takeout_core(uuid,uuid,jsonb)',$old$  FOR v_line IN
    SELECT item.raw, item.ord
    FROM jsonb_array_elements(p_items)
      WITH ORDINALITY AS item(raw, ord)
    ORDER BY item.ord
  LOOP
    INSERT INTO public.order_items (
      order_id,
      menu_item_id,
      quantity,
      unit_price,
      label,
      display_name,
      restaurant_id,
      item_type
    )
    SELECT
      p_order_id,
      m.id,
      (v_line.raw->>'quantity')::int,
      m.price,
      m.name,
      m.name,
      p_store_id,
      'menu_item'
    FROM public.menu_items m
    WHERE m.id = (v_line.raw->>'menu_item_id')::uuid
      AND m.restaurant_id = p_store_id
      AND m.is_available = TRUE
    RETURNING * INTO v_item;

    v_inserted_count := v_inserted_count + 1;
    v_print_items := v_print_items || jsonb_build_array(
      jsonb_build_object(
        'item_id', v_item.id::text,
        'menu_item_id', v_item.menu_item_id::text,
        'label', COALESCE(
          NULLIF(v_item.label, ''),
          NULLIF(v_item.display_name, ''),
          'Item'
        ),
        'quantity', v_item.quantity,
        'notes', v_item.notes,
        'supplemental', true,
        'components', COALESCE(v_item.combo_components, '[]'::jsonb)
      )
    );
    RETURN NEXT v_item;
  END LOOP;$old$,$new$  WITH input AS MATERIALIZED (
    SELECT gen_random_uuid() id,raw,ord FROM jsonb_array_elements(p_items) WITH ORDINALITY item(raw,ord)
  ), inserted AS (
    INSERT INTO public.order_items(id,order_id,menu_item_id,quantity,unit_price,label,display_name,restaurant_id,item_type)
    SELECT src.id,p_order_id,m.id,(raw->>'quantity')::int,m.price,m.name,m.name,p_store_id,'menu_item'
    FROM input src JOIN public.menu_items m ON m.id=(raw->>'menu_item_id')::uuid
      AND m.restaurant_id=p_store_id AND m.is_available ORDER BY ord RETURNING *
  ) SELECT count(*)::integer,coalesce(jsonb_agg(i.id ORDER BY src.ord),'[]'),
    coalesce(jsonb_agg(jsonb_build_object('item_id',i.id::text,'menu_item_id',i.menu_item_id::text,
      'label',coalesce(nullif(i.label,''),nullif(i.display_name,''),'Item'),'quantity',i.quantity,
      'notes',i.notes,'supplemental',true,'components',coalesce(i.combo_components,'[]')) ORDER BY src.ord),'[]')
    INTO v_inserted_count,v_result_ids,v_print_items FROM inserted i JOIN input src ON src.id=i.id;$new$);
SELECT pg_temp.menu_patch('public.add_items_to_order_pre_takeout_core(uuid,uuid,jsonb)',
 $old$  RETURN;
END;$old$,$new$  RETURN QUERY SELECT item.* FROM jsonb_array_elements_text(v_result_ids) WITH ORDINALITY ids(id,ord)
    JOIN public.order_items item ON item.id=ids.id::uuid ORDER BY ids.ord;
  RETURN;
END;$new$);


-- Snapshot-only updates do not repeat the old operational/VAT lookups or emit
-- a second live refresh for each inserted option line. Other writes retain the
-- original trigger body. This guard depends on an actual snapshot change.
CREATE FUNCTION pg_temp.menu_skip_snapshot_only(sig text) RETURNS void LANGUAGE plpgsql AS $patch$
DECLARE body text; pos integer;
BEGIN
 body:=pg_get_functiondef(to_regprocedure(sig)); pos:=strpos(body,'BEGIN');
 IF pos=0 THEN RAISE EXCEPTION 'MENU_RELEASE_TRIGGER_DRIFT: %',sig; END IF;
 body:=overlay(body placing $guard$BEGIN
  IF TG_OP='UPDATE' AND TG_TABLE_NAME='order_items'
    AND (to_jsonb(NEW)->'menu_option_snapshot') IS DISTINCT FROM (to_jsonb(OLD)->'menu_option_snapshot')
    AND (to_jsonb(NEW)-'menu_option_snapshot')=(to_jsonb(OLD)-'menu_option_snapshot') THEN RETURN NEW; END IF;
 $guard$ from pos for 5);
 EXECUTE body;
END $patch$;
SELECT pg_temp.menu_skip_snapshot_only('public.guard_order_item_operational_day()');
SELECT pg_temp.menu_skip_snapshot_only('public.reject_pos_delivery_fee_item()');
SELECT pg_temp.menu_skip_snapshot_only('public.enforce_restaurant_daily_cutoff()');
SELECT pg_temp.menu_skip_snapshot_only('public.snapshot_order_item_vat()');
SELECT pg_temp.menu_skip_snapshot_only('public.cashier_partial_progress_sync()');
SELECT pg_temp.menu_skip_snapshot_only('public.emit_pos_live_event()');


CREATE FUNCTION public.guard_menu_option_snapshot() RETURNS trigger LANGUAGE plpgsql
SET search_path=public,pg_catalog AS $$
BEGIN
 IF NEW.menu_option_snapshot IS DISTINCT FROM OLD.menu_option_snapshot AND pg_trigger_depth()<2 THEN
  RAISE EXCEPTION 'ITEM_NOT_EDITABLE';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER aa_menu_option_snapshot_immutable BEFORE UPDATE OF menu_option_snapshot ON public.order_items
 FOR EACH ROW EXECUTE FUNCTION public.guard_menu_option_snapshot();
CREATE TRIGGER aa_menu_option_snapshot_immutable BEFORE UPDATE OF menu_option_snapshot ON public.direct_order_request_items
 FOR EACH ROW EXECUTE FUNCTION public.guard_menu_option_snapshot();
REVOKE ALL ON FUNCTION public.guard_menu_option_snapshot() FROM PUBLIC,anon,authenticated;


-- Preserve the order-time option in digital, combined and physical receipts.
SELECT pg_temp.menu_patch('public.digital_receipt_force_vietnamese_items()',
 $old$SELECT item.id, item.menu_item_id,$old$,
 $new$SELECT item.id, item.menu_item_id,item.menu_option_snapshot,$new$);
SELECT pg_temp.menu_patch('public.digital_receipt_force_vietnamese_items()',
 $old$'label', COALESCE(NULLIF(menu.name_vi, ''), 'Món')$old$,
 $new$'label', COALESCE(NULLIF(ordered_item.menu_option_snapshot->>'name_vi',''),NULLIF(menu.name_vi, ''), 'Món')$new$);
SELECT pg_temp.menu_patch('public.build_combined_customer_receipt_snapshot(uuid,numeric,numeric)',
 $old$CASE
        WHEN NULLIF(btrim(menu.name_vi), '') IS NOT NULL$old$,
 $new$CASE
        WHEN nullif(item.menu_option_snapshot->>'name_vi','') IS NOT NULL THEN item.menu_option_snapshot->>'name_vi'
        WHEN NULLIF(btrim(menu.name_vi), '') IS NOT NULL$new$);
SELECT pg_temp.menu_patch('public.force_print_job_combo_labels_vi()',
 $old$  FROM jsonb_array_elements(NEW.payload -> 'items')
    WITH ORDINALITY AS item(raw, ord);$old$,
 $new$  FROM jsonb_array_elements(NEW.payload -> 'items')
    WITH ORDINALITY AS item(raw, ord)
  LEFT JOIN public.order_items source ON source.id::text=item.raw->>'item_id' AND source.order_id=NEW.order_id;$new$);
SELECT pg_temp.menu_patch('public.force_print_job_combo_labels_vi()',
 $old$CASE
                      WHEN NULLIF(btrim(menu.name_vi), '') IS NOT NULL$old$,
 $new$CASE
                      WHEN nullif(source.menu_option_snapshot->'components'->(component.raw->>'menu_item_id')->>'name_vi','') IS NOT NULL THEN source.menu_option_snapshot->'components'->(component.raw->>'menu_item_id')->>'name_vi'
                      WHEN NULLIF(btrim(menu.name_vi), '') IS NOT NULL$new$);
SELECT pg_temp.menu_patch('public.force_print_job_menu_labels_vi()',$old$DECLARE
  v_items jsonb;
BEGIN
  IF NEW.order_id IS NULL
     OR jsonb_typeof(COALESCE(NEW.payload -> 'items', 'null'::jsonb)) <> 'array' THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      item.raw || jsonb_build_object(
        'label',
        CASE
          WHEN NULLIF(btrim(menu.name_vi), '') IS NOT NULL
               AND btrim(menu.name_vi) !~ '[가-힣]'
            THEN btrim(menu.name_vi)
          ELSE 'Món'
        END
      )
      ORDER BY item.ord
    ),
    '[]'::jsonb
  )
  INTO v_items
  FROM jsonb_array_elements(NEW.payload -> 'items')
    WITH ORDINALITY AS item(raw, ord)
  LEFT JOIN LATERAL (
    SELECT oi.menu_item_id
    FROM public.order_items oi
    WHERE oi.order_id = NEW.order_id
      AND oi.status <> 'cancelled'
      AND (
        (
          NULLIF(item.raw ->> 'item_id', '') IS NOT NULL
          AND oi.id::text = NULLIF(item.raw ->> 'item_id', '')
        )
        OR NULLIF(item.raw ->> 'item_id', '') IS NULL
      )
    ORDER BY oi.created_at, oi.id
    OFFSET CASE
      WHEN NULLIF(item.raw ->> 'item_id', '') IS NULL THEN item.ord - 1
      ELSE 0
    END
    LIMIT 1
  ) order_line ON true
  LEFT JOIN public.menu_items menu
    ON menu.id = COALESCE(
      CASE
        WHEN COALESCE(item.raw ->> 'menu_item_id', '') ~
             '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
          THEN (item.raw ->> 'menu_item_id')::uuid
        ELSE NULL
      END,
      order_line.menu_item_id
    )
   AND menu.restaurant_id = NEW.restaurant_id;

  NEW.payload := jsonb_set(NEW.payload, '{items}', v_items, false);
  RETURN NEW;
END;$old$,$new$DECLARE v_items jsonb;
BEGIN
 IF NEW.order_id IS NULL OR jsonb_typeof(coalesce(NEW.payload->'items','null'))<>'array' THEN RETURN NEW; END IF;
 WITH lines AS MATERIALIZED (
  SELECT oi.*,row_number() OVER(ORDER BY oi.created_at,oi.id) ord FROM public.order_items oi
  WHERE oi.order_id=NEW.order_id AND oi.status<>'cancelled'
 ), items AS (
  SELECT raw,ord FROM jsonb_array_elements(NEW.payload->'items') WITH ORDINALITY i(raw,ord)
 ) SELECT coalesce(jsonb_agg(i.raw||jsonb_build_object('label',coalesce(
    nullif(coalesce(by_id.menu_option_snapshot,by_ord.menu_option_snapshot)->>'name_vi',''),
    CASE WHEN nullif(btrim(m.name_vi),'') IS NOT NULL AND btrim(m.name_vi)!~'[가-힣]' THEN btrim(m.name_vi) ELSE 'Món' END)) ORDER BY i.ord),'[]')
 INTO v_items FROM items i
 LEFT JOIN lines by_id ON by_id.id::text=nullif(i.raw->>'item_id','')
 LEFT JOIN lines by_ord ON nullif(i.raw->>'item_id','') IS NULL AND by_ord.ord=i.ord
 LEFT JOIN public.menu_items m ON m.id=coalesce(CASE WHEN coalesce(i.raw->>'menu_item_id','') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN (i.raw->>'menu_item_id')::uuid END,by_id.menu_item_id,by_ord.menu_item_id)
  AND m.restaurant_id=NEW.restaurant_id;
 NEW.payload:=jsonb_set(NEW.payload,'{items}',v_items,false);
 RETURN NEW;
END;$new$);

DO $$ BEGIN
 IF (SELECT digest FROM menu_options_existing_before) IS DISTINCT FROM
   (SELECT md5(jsonb_agg(to_jsonb(m)-ARRAY['portion_code','spice_level','spice_choice','option_base_names','menu_option_key'] ORDER BY m.id)::text) FROM public.menu_items m) THEN RAISE EXCEPTION 'MENU_EXISTING_DATA_CHANGED'; END IF;
 IF has_function_privilege('anon','public.admin_create_menu_item_with_options(uuid,uuid,text,text,text,text,numeric,jsonb,integer,boolean,jsonb,text)','EXECUTE') OR
    has_function_privilege('authenticated','public.menu_apply_option_workbook(uuid,jsonb)','EXECUTE') OR
    EXISTS(SELECT 1 FROM public.menu_items WHERE portion_code<>'' OR spice_level<>'unknown' OR spice_choice<>'') THEN
   RAISE EXCEPTION 'MENU_OPTION_RELEASE_POSTCONDITION_FAILED';
 END IF;
END $$;
COMMIT;
