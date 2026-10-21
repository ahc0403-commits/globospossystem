-- Registered selections are data, not one column or sellable menu per taste.
-- Empty definitions preserve the exact legacy key and all existing sellable IDs.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

ALTER TABLE public.menu_items ADD COLUMN choice_definition jsonb NOT NULL DEFAULT '{}';

CREATE FUNCTION public.menu_choice_definition_valid(p_definition jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,public AS $$
BEGIN
 IF p_definition='{}'::jsonb THEN RETURN true; END IF;
 IF p_definition IS NULL OR jsonb_typeof(p_definition)<>'object' OR octet_length(p_definition::text)>16384
  OR p_definition->>'schema_version' IS DISTINCT FROM '1' OR jsonb_typeof(p_definition->'groups') IS DISTINCT FROM 'array'
  OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_definition)k WHERE k NOT IN('schema_version','groups','rules')) THEN RETURN false; END IF;
 IF jsonb_array_length(p_definition->'groups') NOT BETWEEN 1 AND 8
  OR jsonb_typeof(coalesce(p_definition->'rules','[]'))<>'array' THEN RETURN false; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_definition->'groups')g WHERE jsonb_typeof(g)<>'object'
  OR coalesce(g->>'id','') !~ '^[A-Za-z0-9_-]{1,64}$'
  OR coalesce(g->>'min','') !~ '^[0-8]$' OR coalesce(g->>'max','') !~ '^[1-8]$'
  OR coalesce(g->>'min','0')::int>coalesce(g->>'max','0')::int
  OR jsonb_typeof(g->'values') IS DISTINCT FROM 'array'
  OR jsonb_typeof(g->'channels') IS DISTINCT FROM 'array'
  OR jsonb_typeof(g->'repeat') IS DISTINCT FROM 'boolean'
  OR coalesce(length(g->>'name_ko'),0) NOT BETWEEN 1 AND 80
  OR coalesce(length(g->>'name_vi'),0) NOT BETWEEN 1 AND 80
  OR coalesce(length(g->>'name_en'),0) NOT BETWEEN 1 AND 80
  OR EXISTS(SELECT 1 FROM jsonb_object_keys(g)k WHERE k NOT IN('id','min','max','values','channels','repeat','name_ko','name_vi','name_en'))
 ) THEN RETURN false; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_definition->'groups')g
  WHERE jsonb_array_length(g->'values') NOT BETWEEN 1 AND 32 OR jsonb_array_length(g->'channels') NOT BETWEEN 1 AND 3
   OR EXISTS(SELECT 1 FROM jsonb_array_elements_text(g->'channels')c WHERE c NOT IN('pos','qr','direct'))
   OR (SELECT count(DISTINCT c) FROM jsonb_array_elements_text(g->'channels')c)<>jsonb_array_length(g->'channels'))
 OR (SELECT count(DISTINCT g->>'id') FROM jsonb_array_elements(p_definition->'groups')g)<>jsonb_array_length(p_definition->'groups')
 THEN RETURN false; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_definition->'groups')g CROSS JOIN LATERAL jsonb_array_elements(g->'values')v
  WHERE jsonb_typeof(v)<>'object' OR coalesce(v->>'id','') !~ '^[A-Za-z0-9_-]{1,64}$'
   OR jsonb_typeof(v->'available') IS DISTINCT FROM 'boolean'
   OR coalesce(v->>'price_delta','') !~ '^[0-9]{1,9}(\.[0-9]{1,2})?$'
   OR coalesce(v->>'default_quantity','0') !~ '^[0-8]$'
   OR coalesce(length(v->>'name_ko'),0) NOT BETWEEN 1 AND 80
   OR coalesce(length(v->>'name_vi'),0) NOT BETWEEN 1 AND 80
   OR coalesce(length(v->>'name_en'),0) NOT BETWEEN 1 AND 80
   OR jsonb_typeof(coalesce(v->'recipe_additions','[]'))<>'array'
   OR EXISTS(SELECT 1 FROM jsonb_object_keys(v)k WHERE k NOT IN('id','name_ko','name_vi','name_en','price_delta','available','default_quantity','recipe_additions'))
 ) THEN RETURN false; END IF;
 IF (SELECT count(*)>64 OR count(*)<>count(DISTINCT v->>'id')
  FROM jsonb_array_elements(p_definition->'groups')g CROSS JOIN LATERAL jsonb_array_elements(g->'values')v)
 OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_definition->'groups')g WHERE
   (SELECT sum(coalesce((v->>'default_quantity')::int,0)) FROM jsonb_array_elements(g->'values')v)>(g->>'max')::int
   OR EXISTS(SELECT 1 FROM jsonb_array_elements(g->'values')v WHERE
    (NOT (g->>'repeat')::boolean AND coalesce((v->>'default_quantity')::int,0)>1)
    OR (NOT (v->>'available')::boolean AND coalesce((v->>'default_quantity')::int,0)>0)
    OR jsonb_array_length(coalesce(v->'recipe_additions','[]'))>8)) THEN RETURN false; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_definition->'groups')g
  CROSS JOIN LATERAL jsonb_array_elements(g->'values')v CROSS JOIN LATERAL jsonb_array_elements(coalesce(v->'recipe_additions','[]'))r
  WHERE jsonb_typeof(r)<>'object' OR coalesce(r->>'ingredient_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   OR coalesce(r->>'quantity_g','') !~ '^[0-9]{1,6}(\.[0-9]{1,3})?$' OR (r->>'quantity_g')::numeric<=0
   OR EXISTS(SELECT 1 FROM jsonb_object_keys(r)k WHERE k NOT IN('ingredient_id','quantity_g')))
 THEN RETURN false; END IF;
 IF jsonb_array_length(coalesce(p_definition->'rules','[]'))>32 OR EXISTS(
  WITH ids AS (SELECT v->>'id' id FROM jsonb_array_elements(p_definition->'groups')g CROSS JOIN LATERAL jsonb_array_elements(g->'values')v)
  SELECT 1 FROM jsonb_array_elements(coalesce(p_definition->'rules','[]'))r WHERE jsonb_typeof(r)<>'object'
   OR r->>'kind' NOT IN('requires','excludes') OR coalesce(r->>'kind','')=''
   OR r->>'from'=r->>'to' OR NOT EXISTS(SELECT 1 FROM ids WHERE id=r->>'from')
   OR NOT EXISTS(SELECT 1 FROM ids WHERE id=r->>'to')
   OR EXISTS(SELECT 1 FROM jsonb_object_keys(r)k WHERE k NOT IN('kind','from','to'))
 ) THEN RETURN false; END IF;
 RETURN true;
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value THEN RETURN false;
END $$;
ALTER TABLE public.menu_items ADD CONSTRAINT menu_choice_definition_valid CHECK(public.menu_choice_definition_valid(choice_definition));

CREATE FUNCTION public.menu_choice_catalog_key(p_legacy text,p_definition jsonb,p_price numeric) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT CASE WHEN p_definition='{}'::jsonb THEN p_legacy ELSE jsonb_build_object(
  'schema',2,'legacy_key',p_legacy,'definition_revision',md5(p_definition::text),
  'definition',jsonb_set(p_definition,'{groups}',(SELECT jsonb_agg(jsonb_set(g,'{values}',
    (SELECT jsonb_agg(v-'recipe_additions' ORDER BY vo) FROM jsonb_array_elements(g->'values') WITH ORDINALITY vals(v,vo))) ORDER BY go)
   FROM jsonb_array_elements(p_definition->'groups') WITH ORDINALITY groups(g,go))),
  'base_price',p_price)::text END;
$$;
ALTER TABLE public.menu_items ALTER COLUMN menu_option_key SET EXPRESSION AS
 (public.menu_choice_catalog_key(public.menu_meal_option_key(id,size_parent_id,size_prices,option_base_names,
  portion_code,spice_level,spice_choice,price,meal_choices,meal_choice),choice_definition,price));

-- Pure per-line normalization; database rows are fetched/locked once per batch.
CREATE FUNCTION public.menu_choice_snapshot(p_menu jsonb,p_key text,p_channel text) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,public AS $$
DECLARE definition jsonb:=p_menu->'choice_definition'; chosen jsonb; request jsonb; result jsonb;
BEGIN
 IF coalesce(definition,'{}')='{}'::jsonb THEN RETURN '{}'::jsonb; END IF;
 IF p_channel IS NULL OR p_channel NOT IN('pos','qr','direct') THEN RAISE EXCEPTION 'MENU_SELECTION_CHANNEL_INVALID'; END IF;
 BEGIN request:=p_key::jsonb;
 EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'MENU_SELECTION_REQUIRED'; END;
 IF request->>'schema' IS DISTINCT FROM '2' OR request->>'revision' IS DISTINCT FROM md5(p_menu->>'menu_option_key')
  OR jsonb_typeof(request->'selected') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'MENU_SELECTION_CHANGED'; END IF;
 chosen:=request->'selected';
 IF jsonb_array_length(chosen)>64 OR EXISTS(SELECT 1 FROM jsonb_array_elements(chosen)c
  WHERE jsonb_typeof(c)<>'object' OR coalesce(c->>'quantity','') !~ '^[1-8]$'
   OR coalesce(c->>'value_id','') !~ '^[A-Za-z0-9_-]{1,64}$'
   OR EXISTS(SELECT 1 FROM jsonb_object_keys(c)k WHERE k NOT IN('value_id','quantity')))
 OR (SELECT count(DISTINCT c->>'value_id') FROM jsonb_array_elements(chosen)c)<>jsonb_array_length(chosen)
 THEN RAISE EXCEPTION 'MENU_SELECTION_INVALID'; END IF;
 IF EXISTS(
  WITH available AS (SELECT g,v FROM jsonb_array_elements(definition->'groups')g CROSS JOIN LATERAL jsonb_array_elements(g->'values')v)
  SELECT 1 FROM jsonb_array_elements(chosen)c LEFT JOIN available a ON a.v->>'id'=c->>'value_id'
  WHERE a.v IS NULL OR NOT (a.v->>'available')::boolean OR NOT (a.g->'channels' ? p_channel)
   OR (NOT (a.g->>'repeat')::boolean AND (c->>'quantity')::int>1)
 ) OR EXISTS(
  SELECT 1 FROM jsonb_array_elements(definition->'groups')g
  LEFT JOIN LATERAL (SELECT coalesce(sum((c->>'quantity')::int),0) quantity
   FROM jsonb_array_elements(g->'values')v JOIN jsonb_array_elements(chosen)c ON v->>'id'=c->>'value_id')q ON true
  WHERE g->'channels' ? p_channel AND q.quantity NOT BETWEEN (g->>'min')::int AND (g->>'max')::int
 ) OR EXISTS(SELECT 1 FROM jsonb_array_elements(coalesce(definition->'rules','[]'))r
   WHERE EXISTS(SELECT 1 FROM jsonb_array_elements(chosen)c WHERE c->>'value_id'=r->>'from')
    AND ((r->>'kind'='requires' AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(chosen)c WHERE c->>'value_id'=r->>'to'))
      OR (r->>'kind'='excludes' AND EXISTS(SELECT 1 FROM jsonb_array_elements(chosen)c WHERE c->>'value_id'=r->>'to'))))
 THEN RAISE EXCEPTION 'MENU_SELECTION_INVALID'; END IF;
 WITH selected AS MATERIALIZED (
  SELECT g->>'id' group_id,gord,v,vord,(c->>'quantity')::int quantity FROM jsonb_array_elements(definition->'groups') WITH ORDINALITY groups(g,gord)
  CROSS JOIN LATERAL jsonb_array_elements(g->'values') WITH ORDINALITY vals(v,vord)
  JOIN jsonb_array_elements(chosen)c ON c->>'value_id'=v->>'id'
 ), labels AS (
  SELECT coalesce(sum((v->>'price_delta')::numeric*quantity),0) extra,
   string_agg(v->>'name_ko'||CASE WHEN quantity>1 THEN ' ×'||quantity ELSE '' END,' · ' ORDER BY gord,vord) ko,
   string_agg(v->>'name_vi'||CASE WHEN quantity>1 THEN ' ×'||quantity ELSE '' END,' · ' ORDER BY gord,vord) vi,
   string_agg(v->>'name_en'||CASE WHEN quantity>1 THEN ' ×'||quantity ELSE '' END,' · ' ORDER BY gord,vord) en,
   coalesce(jsonb_agg(jsonb_build_object('group_id',group_id,'value_id',v->>'id','quantity',quantity,
    'name_ko',v->>'name_ko','name_vi',v->>'name_vi','name_en',v->>'name_en','price_delta',(v->>'price_delta')::numeric) ORDER BY gord,vord),'[]') choices
  FROM selected
 ), recipes AS (SELECT (r->>'ingredient_id')::uuid ingredient_id,sum((r->>'quantity_g')::numeric*s.quantity) quantity_g
  FROM selected s CROSS JOIN LATERAL jsonb_array_elements(coalesce(v->'recipe_additions','[]'))r GROUP BY (r->>'ingredient_id')::uuid)
 SELECT jsonb_build_object('choice_schema',1,'menu_item_id',p_menu->'id','catalog_revision',md5(p_menu->>'menu_option_key'),
  'selection_key',p_key,'choice_signature',md5(l.choices::text),'choices',l.choices,'unit_price',(p_menu->>'price')::numeric+l.extra,
  'name_ko',coalesce(nullif(p_menu->>'name_ko',''),p_menu->>'name')||coalesce(' ['||l.ko||']',''),
  'name_vi',coalesce(nullif(p_menu->>'name_vi',''),p_menu->>'name')||coalesce(' ['||l.vi||']',''),
  'name_en',coalesce(nullif(p_menu->>'name_en',''),p_menu->>'name')||coalesce(' ['||l.en||']',''),
  'recipe_additions',coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY ingredient_id) FROM recipes r),'[]'))
 INTO result FROM labels l;
 RETURN result;
END $$;

CREATE FUNCTION public.admin_apply_menu_choices(p_item_id uuid,p_definition jsonb) RETURNS public.menu_items
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE m public.menu_items;
BEGIN
 SELECT * INTO m FROM public.menu_items WHERE id=p_item_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND'; END IF;
 PERFORM public.require_admin_actor_for_restaurant(m.restaurant_id);
 IF m.size_parent_id IS NOT NULL OR NOT public.menu_choice_definition_valid(p_definition) THEN RAISE EXCEPTION 'MENU_SELECTION_DEFINITION_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(coalesce(p_definition->'groups','[]'))g
  CROSS JOIN LATERAL jsonb_array_elements(g->'values')v CROSS JOIN LATERAL jsonb_array_elements(coalesce(v->'recipe_additions','[]'))r
  LEFT JOIN public.inventory_items i ON i.id=(r->>'ingredient_id')::uuid AND i.restaurant_id=m.restaurant_id
  WHERE i.id IS NULL) THEN RAISE EXCEPTION 'MENU_SELECTION_RECIPE_INVALID'; END IF;
 PERFORM id FROM public.menu_items WHERE id=p_item_id OR size_parent_id=p_item_id ORDER BY id FOR UPDATE;
 UPDATE public.menu_items SET choice_definition=p_definition,updated_at=now()
 WHERE (id=p_item_id OR size_parent_id=p_item_id) AND choice_definition IS DISTINCT FROM p_definition;
 SELECT * INTO m FROM public.menu_items WHERE id=p_item_id;
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
 VALUES(auth.uid(),'menu_choices_registered','menu_items',p_item_id,jsonb_build_object('restaurant_id',m.restaurant_id,'revision',md5(m.menu_option_key)));
 RETURN m;
END $$;
REVOKE ALL ON FUNCTION public.menu_choice_snapshot(jsonb,text,text),public.admin_apply_menu_choices(uuid,jsonb)
 FROM PUBLIC,anon,authenticated,service_role;
-- The public registration RPCs below call the private atomic helper.
CREATE OR REPLACE FUNCTION public.admin_create_menu_item_with_options(
 p_store_id uuid,p_category_id uuid,p_name_ko text,p_name_vi text,p_name_en text,p_paperless_name_vi text,p_price numeric,
 p_options jsonb,p_sort_order integer DEFAULT 0,p_is_available boolean DEFAULT true,p_tax jsonb DEFAULT NULL,p_invoice_sale_unit text DEFAULT NULL
) RETURNS public.menu_items LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE m public.menu_items;
BEGIN
 IF p_options ? 'meal_choices' AND jsonb_typeof(p_options->'meal_choices')<>'boolean' THEN RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
 m:=public.admin_create_menu_item_pre_meal_choices(p_store_id,p_category_id,p_name_ko,p_name_vi,p_name_en,p_paperless_name_vi,p_price,
  p_options-'meal_choices'-'choice_definition',p_sort_order,p_is_available,p_tax,p_invoice_sale_unit);
 UPDATE public.menu_items SET meal_choices=coalesce((p_options->>'meal_choices')::boolean,false) WHERE id=m.id RETURNING * INTO m;
 IF p_options ? 'choice_definition' THEN m:=public.admin_apply_menu_choices(m.id,p_options->'choice_definition'); END IF;
 RETURN m;
END $$;
CREATE OR REPLACE FUNCTION public.admin_update_menu_item_with_options(
 p_item_id uuid,p_name_ko text,p_name_vi text,p_name_en text,p_paperless_name_vi text,p_price numeric,p_options jsonb,p_tax jsonb DEFAULT NULL
) RETURNS public.menu_items LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE m public.menu_items;
BEGIN
 IF p_options ? 'meal_choices' AND jsonb_typeof(p_options->'meal_choices')<>'boolean' THEN RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
 m:=public.admin_update_menu_item_pre_meal_choices(p_item_id,p_name_ko,p_name_vi,p_name_en,p_paperless_name_vi,p_price,p_options-'meal_choices'-'choice_definition',p_tax);
 IF p_options ? 'meal_choices' THEN UPDATE public.menu_items SET meal_choices=(p_options->>'meal_choices')::boolean WHERE id=m.id RETURNING * INTO m; END IF;
 IF p_options ? 'choice_definition' OR m.choice_definition<>'{}'::jsonb THEN
  m:=public.admin_apply_menu_choices(m.id,coalesce(p_options->'choice_definition',m.choice_definition));
 END IF;
 RETURN m;
END $$;
CREATE OR REPLACE FUNCTION "public"."menu_size_price_sync_batch"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
 IF pg_trigger_depth()>1 THEN RETURN NULL; END IF;
 IF EXISTS(SELECT 1 FROM changed_sizes n JOIN public.menu_items p ON p.id=n.size_parent_id
   WHERE n.restaurant_id<>p.restaurant_id OR (NOT n.is_archived AND
    (n.price<>CASE WHEN p.size_prices='{}'::jsonb THEN p.price ELSE (p.size_prices->>n.portion_code)::numeric END
     OR n.meal_choices<>p.meal_choices OR n.choice_definition<>p.choice_definition))) THEN RAISE EXCEPTION 'MENU_SIZE_PRICE_MANAGED_BY_PARENT'; END IF;
 UPDATE public.menu_items c SET
  price=CASE WHEN p.size_prices='{}'::jsonb THEN p.price ELSE coalesce((p.size_prices->>c.portion_code)::numeric,c.price) END,
  name=p.option_base_names->>'name',name_ko=p.option_base_names->>'name_ko',name_vi=p.option_base_names->>'name_vi',name_en=p.option_base_names->>'name_en',
  paperless_name_vi=p.option_base_names->>'paperless_name_vi',option_base_names=p.option_base_names,
  spice_level=p.spice_level,spice_choice=p.spice_choice,meal_choices=p.meal_choices,choice_definition=p.choice_definition,
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
  fulfillment_route,vat_category,beverage_sugar_tax_class,sugar_g_per_100ml,tax_basis_note,invoice_sale_unit,choice_definition)
 SELECT p.restaurant_id,p.category_id,p.option_base_names->>'name',p.option_base_names->>'name_ko',p.option_base_names->>'name_vi',p.option_base_names->>'name_en',p.option_base_names->>'paperless_name_vi',
  CASE WHEN p.size_prices='{}'::jsonb THEN p.price ELSE (p.size_prices->>sizes.portion)::numeric END,
  sizes.portion,p.spice_level,p.spice_choice,p.option_base_names,p.id,p.meal_choices,meals.choice,
  p.sort_order,p.is_available,p.is_archived,p.is_visible_public,p.description,p.image_url,p.image_storage_path,
  p.fulfillment_route,p.vat_category,p.beverage_sugar_tax_class,p.sugar_g_per_100ml,p.tax_basis_note,p.invoice_sale_unit,p.choice_definition
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


NOTIFY pgrst,'reload schema';
DO $verify$ BEGIN
 IF NOT public.menu_choice_definition_valid('{}') OR public.menu_choice_definition_valid('{"schema_version":1,"groups":[]}')
 OR has_function_privilege('authenticated','public.admin_apply_menu_choices(uuid,jsonb)','EXECUTE')
 OR has_function_privilege('anon','public.admin_update_menu_item_with_options(uuid,text,text,text,text,numeric,jsonb,jsonb)','EXECUTE')
 THEN RAISE EXCEPTION 'MENU_CHOICE_REGISTRATION_CONTRACT_INVALID'; END IF;
END $verify$;
COMMIT;
