-- Stage 2a: request-line identity through approval, tax and stock snapshots.
-- Full effective definitions, verified against the 2026-10-21 schema. Existing
-- response shapes and the per-request menu uniqueness constraint stay intact.
-- A new approved request uses its request-line UUID for the order and ticket
-- line. Historical order IDs are never rewritten. The subsequent choice phase
-- must migrate public/cart protocols before relaxing menu uniqueness.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';
CREATE OR REPLACE FUNCTION "public"."direct_order_prepare_combo_items"("p_store_id" "uuid", "p_items" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
DECLARE prepared jsonb;
BEGIN
 IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 50 THEN
  RAISE EXCEPTION 'DIRECT_ORDER_ITEM_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_items) e WHERE jsonb_typeof(e) IS DISTINCT FROM 'object'
  OR COALESCE(e->>'menu_item_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  OR COALESCE(e->>'quantity','') !~ '^[1-9][0-9]?$'
  OR jsonb_typeof(COALESCE(e->'combo_drink_choices','[]')) IS DISTINCT FROM 'array'
  OR char_length(COALESCE(e->>'note',''))>300) THEN RAISE EXCEPTION 'DIRECT_ORDER_ITEM_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_items) e WHERE (e->>'quantity')::integer>50
  OR jsonb_array_length(COALESCE(e->'combo_drink_choices','[]'))>500)
 OR (SELECT count(DISTINCT (e->>'menu_item_id')::uuid) FROM jsonb_array_elements(p_items)e)<>jsonb_array_length(p_items)
 THEN RAISE EXCEPTION 'DIRECT_ORDER_ITEM_INVALID'; END IF;
 IF (SELECT sum((e->>'quantity')::integer) FROM jsonb_array_elements(p_items)e)>100 THEN RAISE EXCEPTION 'DIRECT_ORDER_QUANTITY_LIMIT'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_items)e CROSS JOIN LATERAL jsonb_array_elements(COALESCE(e->'combo_drink_choices','[]'))c
  WHERE jsonb_typeof(c) IS DISTINCT FROM 'string' OR (c#>>'{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
 THEN RAISE EXCEPTION 'DIRECT_ORDER_COMBO_CHOICES_INVALID'; END IF;
 PERFORM public.validate_menu_option_batch(p_store_id,p_items,'direct');
 -- Stable lock order covers parent menus, fixed components and chosen drinks.
 PERFORM m.id FROM public.menu_items m JOIN (
  SELECT (e->>'menu_item_id')::uuid id FROM jsonb_array_elements(p_items)e
  UNION SELECT co.component_menu_item_id FROM public.menu_combo_components co
   JOIN jsonb_array_elements(p_items)e ON co.combo_menu_item_id=(e->>'menu_item_id')::uuid WHERE co.restaurant_id=p_store_id
  UNION SELECT c::uuid FROM jsonb_array_elements(p_items)e CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(e->'combo_drink_choices','[]'))c
 ) ids ON ids.id=m.id WHERE m.restaurant_id=p_store_id ORDER BY m.id FOR SHARE OF m;
 WITH lines AS MATERIALIZED(
  SELECT e.raw,e.ord,m.id,m.name,m.name_ko,m.name_vi,m.name_en,m.vat_category,m.price,m.is_combo,
   m.combo_drink_choice_count,m.effective_vat_rate,(e.raw->>'quantity')::integer qty,
   m.restaurant_id=p_store_id AND m.is_available AND m.is_visible_public AND NOT m.is_archived
    AND (m.category_id IS NULL OR cat.is_active) valid
  FROM jsonb_array_elements(p_items) WITH ORDINALITY e(raw,ord)
  LEFT JOIN public.menu_items m ON m.id=(e.raw->>'menu_item_id')::uuid AND m.restaurant_id=p_store_id
  LEFT JOIN public.menu_categories cat ON cat.id=m.category_id AND cat.restaurant_id=p_store_id
 ), fixed AS MATERIALIZED(
  SELECT l.id parent,co.component_menu_item_id id,co.quantity,co.sort_order,
   m.name,m.name_ko,m.name_vi,m.name_en,m.price,m.effective_vat_rate,m.fulfillment_route,
   m.id IS NOT NULL AND m.is_available AND m.is_visible_public AND NOT m.is_archived AND NOT m.is_combo
    AND m.price>0 AND co.quantity>0 AND (m.category_id IS NULL OR cat.is_active) valid
  FROM lines l JOIN public.menu_combo_components co ON co.combo_menu_item_id=l.id AND co.restaurant_id=p_store_id AND l.is_combo
  LEFT JOIN public.menu_items m ON m.id=co.component_menu_item_id AND m.restaurant_id=p_store_id
  LEFT JOIN public.menu_categories cat ON cat.id=m.category_id AND cat.restaurant_id=p_store_id
  WHERE m.id IS NULL OR COALESCE(l.combo_drink_choice_count,0)=0 OR lower(btrim(COALESCE(NULLIF(m.name_ko,''),m.name))) NOT IN('음료','drink','beverage','đồ uống','nước uống')
 ), selected AS MATERIALIZED(
  SELECT l.id parent,c.id::uuid id,count(*)::integer quantity,min(c.ord)::integer sort_order
  FROM lines l CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(l.raw->'combo_drink_choices','[]')) WITH ORDINALITY c(id,ord)
  GROUP BY l.id,c.id
 ), drinks AS MATERIALIZED(
  SELECT s.*,m.name,m.name_ko,m.name_vi,m.name_en,m.price,m.effective_vat_rate,m.fulfillment_route,
   m.id IS NOT NULL AND m.is_available AND m.is_visible_public AND NOT m.is_archived AND NOT m.is_combo
    AND m.price>0 AND cat.is_active AND cat.system_key='drink' valid
  FROM selected s LEFT JOIN public.menu_items m ON m.id=s.id AND m.restaurant_id=p_store_id
  LEFT JOIN public.menu_categories cat ON cat.id=m.category_id AND cat.restaurant_id=p_store_id
 ), parts AS MATERIALIZED(
  SELECT *,false is_total FROM fixed UNION ALL SELECT *,true FROM drinks
 ), normalized AS MATERIALIZED(
  SELECT p.parent,p.id,p.name,p.name_ko,p.name_vi,p.name_en,p.price,p.effective_vat_rate,p.fulfillment_route,
   min(p.sort_order) sort_order,bool_and(p.valid) valid,bool_or(p.is_total) is_total,
   COALESCE(sum(p.quantity) FILTER(WHERE NOT p.is_total),0)::integer fixed_quantity,
   CASE WHEN bool_or(p.is_total) AND bool_or(NOT p.is_total)
    THEN sum(p.quantity*CASE WHEN p.is_total THEN 1 ELSE l.qty END) ELSE sum(p.quantity) END quantity
  FROM parts p JOIN lines l ON l.id=p.parent
  GROUP BY p.parent,p.id,p.name,p.name_ko,p.name_vi,p.name_en,p.price,p.effective_vat_rate,p.fulfillment_route
 ), snapshots AS(
  SELECT parent,bool_and(valid) valid,count(*) component_count,jsonb_agg(jsonb_build_object(
   'menu_item_id',id,'label',name,'name_ko',COALESCE(NULLIF(name_ko,''),name),
   'name_vi',COALESCE(NULLIF(name_vi,''),name),'name_en',COALESCE(NULLIF(name_en,''),name),
   'quantity',quantity,'fixed_quantity',fixed_quantity,'is_total_quantity',is_total,'fulfillment_route',fulfillment_route,
   'tax_unit_price',price,'tax_vat_rate',effective_vat_rate) ORDER BY is_total,sort_order,id) components
  FROM normalized GROUP BY parent
 ), rates AS(
  SELECT p.parent,p.effective_vat_rate rate,sum(p.price*p.quantity*CASE WHEN p.is_total THEN 1 ELSE l.qty END) weight
  FROM parts p JOIN lines l ON l.id=p.parent GROUP BY p.parent,p.effective_vat_rate
 ), profiles AS(SELECT parent,jsonb_agg(jsonb_build_object('rate',rate,'weight',weight) ORDER BY rate) profile FROM rates GROUP BY parent)
 SELECT jsonb_agg(jsonb_build_object('line_id',gen_random_uuid(),'menu_item_id',l.id,'display_name',l.name,
  'name_ko',COALESCE(NULLIF(l.name_ko,''),l.name),'name_vi',COALESCE(NULLIF(l.name_vi,''),l.name),'name_en',COALESCE(NULLIF(l.name_en,''),l.name),
  'vat_category',COALESCE(l.vat_category,'food'),'unit_price',l.price,'quantity',l.qty,'item_note',NULLIF(btrim(l.raw->>'note'),''),'sort_order',l.ord-1,
  'combo_drink_choices',COALESCE(l.raw->'combo_drink_choices','[]'),'combo_components',COALESCE(s.components,'[]'),
  'vat_profile_snapshot',CASE WHEN l.is_combo THEN pr.profile ELSE jsonb_build_array(jsonb_build_object('rate',l.effective_vat_rate,'weight',1)) END,
  'valid',COALESCE(l.valid,false) AND (NOT l.is_combo OR (COALESCE(s.valid,false) AND s.component_count>0))
   AND jsonb_array_length(COALESCE(l.raw->'combo_drink_choices','[]'))=COALESCE(l.combo_drink_choice_count,0)*l.qty
  ) ORDER BY l.ord) INTO prepared FROM lines l LEFT JOIN snapshots s ON s.parent=l.id LEFT JOIN profiles pr ON pr.parent=l.id;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(prepared)e WHERE NOT (e->>'valid')::boolean) THEN
  RAISE EXCEPTION 'DIRECT_ORDER_COMBO_UNAVAILABLE'; END IF;
 RETURN prepared;
END $_$;

CREATE OR REPLACE FUNCTION "public"."direct_order_public_submit"("p_session_id" "uuid", "p_secret_hash" "text", "p_client_request_id" "uuid", "p_payload" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
DECLARE
  v_prepared jsonb; v_previous_prepared text;
  v_session public.direct_order_sessions%ROWTYPE;
  v_storefront public.direct_order_storefronts%ROWTYPE;
  v_request public.direct_order_requests%ROWTYPE;
  v_existing public.direct_order_requests%ROWTYPE;
  v_address jsonb;
  v_item jsonb;
  v_menu public.menu_items%ROWTYPE;
  v_item_count integer := 0;
  v_total_quantity integer := 0;
  v_reference text;
  v_local_time time;
BEGIN
  IF p_client_request_id IS NULL
     OR p_payload IS NULL
     OR jsonb_typeof(p_payload) <> 'object'
     OR jsonb_typeof(p_payload->'items') <> 'array'
     OR jsonb_array_length(p_payload->'items') NOT BETWEEN 1 AND 50
     OR jsonb_typeof(p_payload->'address') <> 'object'
     OR COALESCE(p_payload->>'locale', '') NOT IN ('ko', 'vi', 'en') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_INPUT_INVALID';
  END IF;

  v_session := public.direct_order_validate_session(
    p_session_id, p_secret_hash
  );

  PERFORM pg_advisory_xact_lock(hashtextextended(v_session.restaurant_id::text||':direct-submit:'||p_client_request_id::text,0));
  SELECT * INTO v_existing
  FROM public.direct_order_requests request_row
  WHERE request_row.client_request_id = p_client_request_id;
  IF FOUND THEN
    IF v_existing.session_id <> v_session.id
       OR v_existing.restaurant_id <> v_session.restaurant_id THEN
      RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_INPUT_INVALID';
    END IF;
    RETURN jsonb_build_object(
      'request_id', v_existing.id,
      'reference_code', v_existing.reference_code,
      'state', v_existing.state,
      'idempotent', true
    );
  END IF;

  SELECT * INTO v_storefront
  FROM public.direct_order_storefronts storefront
  WHERE storefront.restaurant_id = v_session.restaurant_id
    AND storefront.is_enabled = true
  FOR SHARE;

  IF NOT FOUND OR v_storefront.is_paused THEN
    RAISE EXCEPTION 'DIRECT_ORDER_STOREFRONT_PAUSED';
  END IF;

  v_local_time := (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::time;
  IF v_storefront.ordering_hours_enforced
     AND (v_local_time < v_storefront.ordering_starts_at
          OR v_local_time >= v_storefront.ordering_cutoff_at) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_OUTSIDE_HOURS';
  END IF;


  v_address := p_payload->'address';
  IF char_length(btrim(COALESCE(v_address->>'customer_name', ''))) NOT BETWEEN 1 AND 100
     OR COALESCE(v_address->>'customer_phone', '') !~ '^[+]?[0-9][0-9 -]{7,19}$'
     OR char_length(btrim(COALESCE(v_address->>'formatted_address', ''))) NOT BETWEEN 3 AND 500
     OR char_length(btrim(COALESCE(v_address->>'detail_address', ''))) NOT BETWEEN 0 AND 300 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_INVALID';
  END IF;

  IF v_address->>'address_source' = 'manual' THEN
    -- A typed address has no verified location. Never manufacture coordinates
    -- or reuse a stale pin when the customer edits a previously saved address.
    IF v_address->>'latitude' IS NOT NULL
       OR v_address->>'longitude' IS NOT NULL
       OR NULLIF(btrim(COALESCE(v_address->>'google_place_id', '')), '') IS NOT NULL
       OR COALESCE(v_address->>'location_verified', 'false') <> 'false' THEN
      RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_INVALID';
    END IF;
  ELSIF COALESCE(v_address->>'address_source', '') NOT IN ('search', 'map_pin')
     OR COALESCE(v_address->>'location_verified', 'false') <> 'true'
     OR v_address->>'latitude' IS NULL
     OR v_address->>'longitude' IS NULL THEN
    -- Preserve in-flight legacy client compatibility without relaxing its
    -- existing location requirements.
    RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_INVALID';
  END IF;

  v_reference := 'D' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

  INSERT INTO public.direct_order_requests(
    restaurant_id, session_id, client_request_id, reference_code,
    state, locale, customer_note
  ) VALUES (
    v_session.restaurant_id,
    v_session.id,
    p_client_request_id,
    v_reference,
    'awaiting_quote',
    COALESCE(NULLIF(p_payload->>'locale', ''), v_session.locale),
    NULLIF(btrim(COALESCE(p_payload->>'customer_note', '')), '')
  ) RETURNING * INTO v_request;

  v_prepared:=public.direct_order_prepare_combo_items(v_session.restaurant_id,p_payload->'items');
  v_previous_prepared:=current_setting('pos.direct_prepared_items',true);
  PERFORM set_config('pos.direct_prepared_items',(SELECT jsonb_object_agg(e->>'line_id',e) FROM jsonb_array_elements(v_prepared)e)::text,true);
  INSERT INTO public.direct_order_request_items(id,request_id,restaurant_id,menu_item_id,display_name,name_ko,name_vi,name_en,vat_category,unit_price,quantity,item_note,sort_order,combo_drink_choices,combo_components,vat_profile_snapshot)
  SELECT (e->>'line_id')::uuid,v_request.id,v_request.restaurant_id,(e->>'menu_item_id')::uuid,e->>'display_name',e->>'name_ko',e->>'name_vi',e->>'name_en',e->>'vat_category',
   (e->>'unit_price')::numeric,(e->>'quantity')::integer,e->>'item_note',(e->>'sort_order')::integer,e->'combo_drink_choices',e->'combo_components',e->'vat_profile_snapshot'
  FROM jsonb_array_elements(v_prepared)e;
  PERFORM set_config('pos.direct_prepared_items',COALESCE(v_previous_prepared,''),true);
  SELECT sum((e->>'quantity')::integer) INTO v_total_quantity FROM jsonb_array_elements(v_prepared)e;
  IF v_total_quantity > 100 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_QUANTITY_LIMIT';
  END IF;

  INSERT INTO public.direct_order_request_addresses(
    request_id, restaurant_id, customer_name, customer_phone,
    formatted_address, detail_address, latitude, longitude,
    google_place_id, district, ward, address_source, location_verified
  ) VALUES (
    v_request.id,
    v_request.restaurant_id,
    btrim(v_address->>'customer_name'),
    btrim(v_address->>'customer_phone'),
    btrim(v_address->>'formatted_address'),
    btrim(v_address->>'detail_address'),
    (v_address->>'latitude')::numeric,
    (v_address->>'longitude')::numeric,
    NULLIF(btrim(COALESCE(v_address->>'google_place_id', '')), ''),
    NULLIF(btrim(COALESCE(v_address->>'district', '')), ''),
    NULLIF(btrim(COALESCE(v_address->>'ward', '')), ''),
    v_address->>'address_source',
    v_address->>'address_source' <> 'manual'
  );

  IF v_address->>'address_source' <> 'manual' THEN
    INSERT INTO public.direct_order_location_facts(
      request_id, restaurant_id, district, ward,
      coarse_latitude, coarse_longitude, requested_at
    ) VALUES (
      v_request.id,
      v_request.restaurant_id,
      NULLIF(btrim(COALESCE(v_address->>'district', '')), ''),
      NULLIF(btrim(COALESCE(v_address->>'ward', '')), ''),
      round((v_address->>'latitude')::numeric, 3),
      round((v_address->>'longitude')::numeric, 3),
      v_request.created_at
    );
  END IF;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, message_type, body
  ) VALUES (
    v_request.id,
    v_request.restaurant_id,
    'system',
    'system',
    'DIRECT_ORDER_REQUEST_RECEIVED'
  );

  RETURN jsonb_build_object(
    'request_id', v_request.id,
    'reference_code', v_request.reference_code,
    'state', v_request.state,
    'idempotent', false
  );
END;
$_$;

CREATE OR REPLACE FUNCTION "public"."direct_order_public_submit_v2"("p_session_id" "uuid", "p_secret_hash" "text", "p_client_request_id" "uuid", "p_payload" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
DECLARE
  v_prepared jsonb; v_previous_prepared text;
  v_session public.direct_order_sessions%ROWTYPE;
  v_storefront public.direct_order_storefronts%ROWTYPE;
  v_request public.direct_order_requests%ROWTYPE;
  v_existing public.direct_order_requests%ROWTYPE;
  v_address jsonb;
  v_type text := p_payload->>'fulfillment_type';
  v_item jsonb;
  v_menu public.menu_items%ROWTYPE;
  v_item_count integer := 0;
  v_total_quantity integer := 0;
  v_reference text;
  v_local_time time;
BEGIN
  IF p_client_request_id IS NULL
     OR p_payload IS NULL
     OR jsonb_typeof(p_payload) <> 'object'
     OR jsonb_typeof(p_payload->'items') <> 'array'
     OR jsonb_array_length(p_payload->'items') NOT BETWEEN 1 AND 50
     OR jsonb_typeof(p_payload->'address') <> 'object'
     OR COALESCE(p_payload->>'locale', '') NOT IN ('ko', 'vi', 'en') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_INPUT_INVALID';
  END IF;

  IF v_type IS NULL OR v_type NOT IN ('delivery','pickup') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_INPUT_INVALID';
  END IF;
  v_session := public.direct_order_validate_session(
    p_session_id, p_secret_hash
  );

  PERFORM pg_advisory_xact_lock(hashtextextended(v_session.restaurant_id::text||':direct-submit:'||p_client_request_id::text,0));
  SELECT * INTO v_existing
  FROM public.direct_order_requests request_row
  WHERE request_row.client_request_id = p_client_request_id;
  IF FOUND THEN
    IF v_existing.session_id <> v_session.id
       OR v_existing.restaurant_id <> v_session.restaurant_id THEN
      RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_INPUT_INVALID';
    END IF;
    IF v_existing.fulfillment_type <> v_type THEN
      RAISE EXCEPTION 'DIRECT_ORDER_FULFILLMENT_TYPE_LOCKED';
    END IF;
    RETURN jsonb_build_object(
      'request_id', v_existing.id,
      'reference_code', v_existing.reference_code,
      'state', v_existing.state,
      'idempotent', true
    );
  END IF;

  SELECT * INTO v_storefront
  FROM public.direct_order_storefronts storefront
  WHERE storefront.restaurant_id = v_session.restaurant_id
    AND storefront.is_enabled = true
  FOR SHARE;

  IF NOT FOUND OR v_storefront.is_paused THEN
    RAISE EXCEPTION 'DIRECT_ORDER_STOREFRONT_PAUSED';
  END IF;

  v_local_time := (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::time;
  IF v_storefront.ordering_hours_enforced
     AND (v_local_time < v_storefront.ordering_starts_at
          OR v_local_time >= v_storefront.ordering_cutoff_at) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_OUTSIDE_HOURS';
  END IF;


  v_address := p_payload->'address';
  IF char_length(btrim(COALESCE(v_address->>'customer_name', ''))) NOT BETWEEN 1 AND 100
     OR COALESCE(v_address->>'customer_phone', '') !~ '^[+]?[0-9][0-9 -]{7,19}$'
     OR (v_type='delivery' AND (char_length(btrim(COALESCE(v_address->>'formatted_address', ''))) NOT BETWEEN 3 AND 500
     OR char_length(btrim(COALESCE(v_address->>'detail_address', ''))) NOT BETWEEN 0 AND 300)) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_INVALID';
  END IF;

  IF v_type='pickup' THEN
    IF v_address->>'address_source' IS DISTINCT FROM 'pickup'
       OR v_address->>'formatted_address' IS NOT NULL OR v_address->>'detail_address' IS NOT NULL
       OR v_address->>'latitude' IS NOT NULL OR v_address->>'longitude' IS NOT NULL
       OR v_address->>'google_place_id' IS NOT NULL
       OR v_address->>'district' IS NOT NULL OR v_address->>'ward' IS NOT NULL
       OR COALESCE(v_address->>'location_verified','false') <> 'false' THEN
      RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_INVALID';
    END IF;
  ELSIF v_address->>'address_source' = 'manual' THEN
    -- A typed address has no verified location. Never manufacture coordinates
    -- or reuse a stale pin when the customer edits a previously saved address.
    IF v_address->>'latitude' IS NOT NULL
       OR v_address->>'longitude' IS NOT NULL
       OR NULLIF(btrim(COALESCE(v_address->>'google_place_id', '')), '') IS NOT NULL
       OR COALESCE(v_address->>'location_verified', 'false') <> 'false' THEN
      RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_INVALID';
    END IF;
  ELSIF COALESCE(v_address->>'address_source', '') NOT IN ('search', 'map_pin')
     OR COALESCE(v_address->>'location_verified', 'false') <> 'true'
     OR v_address->>'latitude' IS NULL
     OR v_address->>'longitude' IS NULL THEN
    -- Preserve in-flight legacy client compatibility without relaxing its
    -- existing location requirements.
    RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_INVALID';
  END IF;

  v_reference := 'D' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

  INSERT INTO public.direct_order_requests(
    restaurant_id, session_id, client_request_id, reference_code,
    state, locale, customer_note, fulfillment_type
  ) VALUES (
    v_session.restaurant_id,
    v_session.id,
    p_client_request_id,
    v_reference,
    'awaiting_quote',
    COALESCE(NULLIF(p_payload->>'locale', ''), v_session.locale),
    NULLIF(btrim(COALESCE(p_payload->>'customer_note', '')), ''), v_type
  ) RETURNING * INTO v_request;

  v_prepared:=public.direct_order_prepare_combo_items(v_session.restaurant_id,p_payload->'items');
  v_previous_prepared:=current_setting('pos.direct_prepared_items',true);
  PERFORM set_config('pos.direct_prepared_items',(SELECT jsonb_object_agg(e->>'line_id',e) FROM jsonb_array_elements(v_prepared)e)::text,true);
  INSERT INTO public.direct_order_request_items(id,request_id,restaurant_id,menu_item_id,display_name,name_ko,name_vi,name_en,vat_category,unit_price,quantity,item_note,sort_order,combo_drink_choices,combo_components,vat_profile_snapshot)
  SELECT (e->>'line_id')::uuid,v_request.id,v_request.restaurant_id,(e->>'menu_item_id')::uuid,e->>'display_name',e->>'name_ko',e->>'name_vi',e->>'name_en',e->>'vat_category',
   (e->>'unit_price')::numeric,(e->>'quantity')::integer,e->>'item_note',(e->>'sort_order')::integer,e->'combo_drink_choices',e->'combo_components',e->'vat_profile_snapshot'
  FROM jsonb_array_elements(v_prepared)e;
  PERFORM set_config('pos.direct_prepared_items',COALESCE(v_previous_prepared,''),true);
  SELECT sum((e->>'quantity')::integer) INTO v_total_quantity FROM jsonb_array_elements(v_prepared)e;
  IF v_total_quantity > 100 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_QUANTITY_LIMIT';
  END IF;

  INSERT INTO public.direct_order_request_addresses(
    request_id, restaurant_id, customer_name, customer_phone,
    formatted_address, detail_address, latitude, longitude,
    google_place_id, district, ward, address_source, location_verified
  ) VALUES (
    v_request.id,
    v_request.restaurant_id,
    btrim(v_address->>'customer_name'),
    btrim(v_address->>'customer_phone'),
    btrim(v_address->>'formatted_address'),
    btrim(v_address->>'detail_address'),
    (v_address->>'latitude')::numeric,
    (v_address->>'longitude')::numeric,
    NULLIF(btrim(COALESCE(v_address->>'google_place_id', '')), ''),
    NULLIF(btrim(COALESCE(v_address->>'district', '')), ''),
    NULLIF(btrim(COALESCE(v_address->>'ward', '')), ''),
    v_address->>'address_source',
    v_address->>'address_source' IN ('search','map_pin')
  );

  IF v_address->>'address_source' IN ('search','map_pin') THEN
    INSERT INTO public.direct_order_location_facts(
      request_id, restaurant_id, district, ward,
      coarse_latitude, coarse_longitude, requested_at
    ) VALUES (
      v_request.id,
      v_request.restaurant_id,
      NULLIF(btrim(COALESCE(v_address->>'district', '')), ''),
      NULLIF(btrim(COALESCE(v_address->>'ward', '')), ''),
      round((v_address->>'latitude')::numeric, 3),
      round((v_address->>'longitude')::numeric, 3),
      v_request.created_at
    );
  END IF;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, message_type, body
  ) VALUES (
    v_request.id,
    v_request.restaurant_id,
    'system',
    'system',
    'DIRECT_ORDER_REQUEST_RECEIVED'
  );

  RETURN jsonb_build_object(
    'request_id', v_request.id,
    'reference_code', v_request.reference_code,
    'state', v_request.state,
    'idempotent', false
  );
END;
$_$;

CREATE OR REPLACE FUNCTION "public"."direct_order_approve_payment"("p_store_id" "uuid", "p_request_id" "uuid", "p_confirmed_amount" numeric, "p_confirmed_bank_reference" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $$
DECLARE previous_snapshot text; previous_lines text; line_snapshots jsonb; result jsonb; snapshot jsonb; already_approved boolean;
BEGIN
 previous_snapshot:=current_setting('pos.direct_combo_snapshot',true);
 previous_lines:=current_setting('pos.direct_line_snapshots',true);
 PERFORM public.direct_order_require_actor(p_store_id,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 PERFORM pg_advisory_xact_lock(hashtextextended('direct-order-approval:'||p_request_id::text,0));
 PERFORM 1 FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id FOR UPDATE;
 already_approved:=EXISTS(SELECT 1 FROM public.direct_order_financials WHERE request_id=p_request_id);
 IF NOT already_approved THEN
  PERFORM public.direct_order_validate_combo_request(p_store_id,p_request_id);
 END IF;
 -- Hydrate every approved line in one query. Individual snapshot triggers
 -- read the transaction map instead of re-querying each request/menu/recipe.
 WITH lines AS MATERIALIZED (
  SELECT i.id,jsonb_array_length(i.combo_components)>0 is_combo,
   jsonb_build_object('vat_profile_snapshot',i.vat_profile_snapshot,'combo_components',
    coalesce((SELECT jsonb_agg(c||jsonb_build_object('fulfillment_route','kitchen_tray_floor'))
     FROM jsonb_array_elements(i.combo_components)c),'[]'::jsonb)) payload
  FROM public.direct_order_request_items i WHERE i.request_id=p_request_id AND i.restaurant_id=p_store_id
 ) SELECT jsonb_object_agg(id::text,payload),jsonb_object_agg(id::text,payload) FILTER(WHERE is_combo)
 INTO line_snapshots,snapshot FROM lines;
 IF NOT already_approved AND snapshot IS NOT NULL THEN PERFORM public.direct_order_lock_combo_stock(p_store_id,p_request_id); END IF;
 PERFORM set_config('pos.direct_combo_snapshot',COALESCE(snapshot,'{}')::text,true);
 PERFORM set_config('pos.direct_line_snapshots',COALESCE(line_snapshots,'{}')::text,true);
 result:=public.direct_order_approve_payment_before_combo(p_store_id,p_request_id,p_confirmed_amount,p_confirmed_bank_reference);
 IF NOT already_approved THEN PERFORM public.direct_order_deduct_combo_stock(p_store_id,p_request_id); END IF;
 PERFORM set_config('pos.direct_line_snapshots',COALESCE(previous_lines,''),true);
 PERFORM set_config('pos.direct_combo_snapshot',COALESCE(previous_snapshot,''),true);
 RETURN result;
EXCEPTION WHEN OTHERS THEN
 PERFORM set_config('pos.direct_line_snapshots',COALESCE(previous_lines,''),true);
 PERFORM set_config('pos.direct_combo_snapshot',COALESCE(previous_snapshot,''),true); RAISE;
END $$;

CREATE OR REPLACE FUNCTION "public"."direct_order_approve_payment_before_combo"("p_store_id" "uuid", "p_request_id" "uuid", "p_confirmed_amount" numeric, "p_confirmed_bank_reference" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_reviewed_proof_id uuid;
  v_request public.direct_order_requests%ROWTYPE;
  v_quote public.direct_order_quotes%ROWTYPE;
  v_existing public.direct_order_financials%ROWTYPE;
  v_storefront public.direct_order_storefronts%ROWTYPE;
  v_mode text;
  v_order public.orders%ROWTYPE;
  v_previous_direct_pos text := current_setting('app.direct_order_pos_id',true);
  v_previous_direct_request text := current_setting('app.direct_order_request_id',true);
  v_payment public.payments%ROWTYPE;
  v_ticket public.direct_delivery_fulfillment_tickets%ROWTYPE;
  v_order_total numeric(15,2);
  v_local_time time;
BEGIN
  v_actor := public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  IF p_confirmed_amount IS NULL OR p_confirmed_amount <= 0
     OR char_length(COALESCE(p_confirmed_bank_reference, '')) > 200 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_APPROVAL_INPUT_INVALID';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('direct-order-approval:' || p_request_id::text, 0)
  );

  SELECT * INTO v_existing
  FROM public.direct_order_financials financial
  WHERE financial.request_id = p_request_id
    AND financial.restaurant_id = p_store_id;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'request_id', v_existing.request_id,
      'order_id', v_existing.order_id,
      'payment_id', v_existing.payment_id,
      'ticket_id', (
        SELECT ticket.id
        FROM public.direct_delivery_fulfillment_tickets ticket
        WHERE ticket.request_id = v_existing.request_id
          AND ticket.restaurant_id = p_store_id
      ),
      'final_total', v_existing.final_total,
      'idempotent', true
    );
  END IF;

  SELECT * INTO v_request
  FROM public.direct_order_requests request_row
  WHERE request_row.id = p_request_id
    AND request_row.restaurant_id = p_store_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
  IF v_request.state <> 'awaiting_payment_review' THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_APPROVABLE';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.direct_order_proof_review_requests review
    WHERE review.request_id = p_request_id
      AND review.restaurant_id = p_store_id
      AND review.status = 'requested'
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PROOF_RESUBMISSION_PENDING';
  END IF;

  SELECT * INTO v_storefront
  FROM public.direct_order_storefronts storefront
  WHERE storefront.restaurant_id = p_store_id
    AND storefront.is_enabled = true
  FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_STOREFRONT_DISABLED'; END IF;

  v_local_time := (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::time;
  -- The intake window never blocks review of an already submitted payment.

  SELECT COALESCE(settings.fulfillment_mode, 'pos_print') INTO v_mode
  FROM public.restaurant_settings settings
  WHERE settings.restaurant_id = p_store_id;
  v_mode := COALESCE(v_mode, 'pos_print');
  -- Direct delivery is routed through its isolated fulfillment ticket graph.
  -- Keep its financial order snapshots on pos_print so a paperless dine-in
  -- workflow cannot intercept or duplicate the delivery ticket.

  -- Direct delivery uses its own fulfillment ticket graph, so an active
  -- paperless emergency session cannot intercept or duplicate this ticket.

  IF EXISTS (
    SELECT 1 FROM public.store_promotions promotion
    WHERE promotion.restaurant_id = p_store_id
      AND promotion.is_active = true
      AND now() >= promotion.starts_at
      AND now() < promotion.ends_at
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PROMOTION_ACTIVE';
  END IF;

  SELECT * INTO v_quote
  FROM public.direct_order_quotes quote
  WHERE quote.request_id = v_request.id
    AND quote.restaurant_id = p_store_id
    AND quote.status = 'locked'
  ORDER BY quote.version DESC
  LIMIT 1
  FOR UPDATE;
  -- Uploading payment proof locks the quoted amount. The locked quote remains
  -- approvable after its browsing TTL because amount, proof, and menu integrity
  -- are all revalidated below before the atomic payment is created.
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_EXPIRED';
  END IF;
  IF round(p_confirmed_amount, 2) IS DISTINCT FROM round(v_quote.final_total, 2) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_AMOUNT_MISMATCH';
  END IF;
  SELECT message.id INTO v_reviewed_proof_id
  FROM public.direct_order_messages message
  WHERE message.request_id = v_request.id
    AND message.restaurant_id = p_store_id
    AND message.sender_type = 'customer'
    AND message.message_type = 'payment_proof'
    AND message.attachment_storage_path IS NOT NULL
    AND message.metadata->>'quote_id' = v_quote.id::text
    AND message.metadata->>'quote_version' = v_quote.version::text
  ORDER BY message.created_at DESC, message.id DESC
  LIMIT 1;

  -- Preserve the optional legacy verified-transfer caller. Photo review is
  -- sufficient for authenticated staff and never requires that integration.
  IF v_reviewed_proof_id IS NULL AND NOT EXISTS (
    SELECT 1
    FROM public.direct_order_sepay_candidates payment_link
    JOIN public.sepay_transactions payment_transaction
      ON payment_transaction.id = payment_link.sepay_transaction_id
    WHERE payment_link.request_id = v_request.id
      AND payment_link.restaurant_id = p_store_id
      AND payment_transaction.restaurant_id = p_store_id
      AND payment_transaction.transfer_type = 'in'
      AND payment_transaction.resolution_status = 'matched'
      AND payment_transaction.transfer_amount::numeric = v_quote.final_total
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_PROOF_REQUIRED';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.direct_order_request_items request_item
    LEFT JOIN public.menu_items menu ON menu.id = request_item.menu_item_id
    WHERE request_item.request_id = v_request.id
      AND (
        menu.id IS NULL OR menu.restaurant_id <> p_store_id
        OR menu.is_available = false OR menu.is_visible_public = false
        OR menu.price IS DISTINCT FROM request_item.unit_price
      )
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_MENU_CHANGED';
  END IF;

  IF v_quote.delivery_fee_total IS DISTINCT FROM 0::numeric THEN
    RAISE EXCEPTION 'DELIVERY_FEE_DISABLED';
  END IF;

  INSERT INTO public.orders(
    restaurant_id, table_id, sales_channel, status, guest_count,
    created_by, notes, order_source, order_purpose,
    fulfillment_mode_snapshot
  ) VALUES (
    p_store_id, NULL, CASE WHEN v_request.fulfillment_type='pickup' THEN 'takeaway' ELSE 'delivery' END, 'serving', v_request.diner_count,
    (SELECT auth.uid()),
    CASE WHEN v_request.fulfillment_type='pickup' THEN 'Direct pickup ' ELSE 'Direct delivery ' END || v_request.reference_code,
    'staff', 'customer', 'pos_print'
  ) RETURNING * INTO v_order;
  PERFORM set_config('app.direct_order_pos_id',v_order.id::text,true);
  PERFORM set_config('app.direct_order_request_id',v_request.id::text,true);

  PERFORM set_config('pos.direct_vat_request',v_request.id::text,true);
  INSERT INTO public.order_items(
    id, restaurant_id, order_id, menu_item_id, item_type, label,
    display_name, unit_price, quantity, status, notes,
    vat_rate, vat_amount, total_amount_ex_tax, paying_amount_inc_tax,
    is_service_item, fulfillment_mode_snapshot
  )
  SELECT
    item.id,
    p_store_id,
    v_order.id,
    item.menu_item_id,
    'menu_item',
    item.display_name,
    item.display_name,
    item.unit_price,
    item.quantity,
    'served',
    item.item_note,
    0, 0, 0, 0,
    false,
    'pos_print'
  FROM public.direct_order_request_items item
  WHERE item.request_id = v_request.id
  ORDER BY item.sort_order, item.id;

  -- No delivery fee item is created, including a zero-value placeholder.

  INSERT INTO public.direct_delivery_fulfillment_tickets(
    request_id, restaurant_id, pickup_code, updated_by
  ) VALUES (
    v_request.id, p_store_id, v_request.reference_code, (SELECT auth.uid())
  ) RETURNING * INTO v_ticket;

  INSERT INTO public.direct_delivery_fulfillment_ticket_items(
    id, ticket_id, restaurant_id, menu_item_id,
    display_name_ko, display_name_vi, display_name_en,
    quantity, item_note, sort_order
  )
  SELECT
    item.id, v_ticket.id, p_store_id, item.menu_item_id,
    item.name_ko, item.name_vi, item.name_en,
    item.quantity, item.item_note, item.sort_order
  FROM public.direct_order_request_items item
  WHERE item.request_id = v_request.id
  ORDER BY item.sort_order, item.id;

  PERFORM set_config('pos.direct_vat_request','',true);
  -- This is the unchanged, authoritative payment anchor. It also produces
  -- brand service-charge lines, VAT snapshots, inventory deductions, and the
  -- asynchronous MISA queue record. Any mismatch below rolls all of it back.
  v_payment := public.process_payment(
    v_order.id, p_store_id, v_quote.final_total, 'BANKTRANSFER'
  );

  SELECT round(COALESCE(sum(item.paying_amount_inc_tax), 0), 2)
  INTO v_order_total
  FROM public.order_items item
  WHERE item.order_id = v_order.id
    AND item.status <> 'cancelled'
    AND COALESCE(item.is_service_item, false) = false;

  IF v_order_total IS DISTINCT FROM round(v_quote.final_total, 2)
     OR round(v_payment.amount_portion, 2) IS DISTINCT FROM round(v_quote.final_total, 2)
     OR NOT EXISTS (
       SELECT 1 FROM public.orders completed_order
       WHERE completed_order.id = v_order.id
         AND completed_order.status = 'completed'
     ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_FINANCIAL_RECONCILIATION_FAILED';
  END IF;

  INSERT INTO public.direct_order_financials(
    request_id, restaurant_id, quote_id, order_id, payment_id,
    delivery_fee_item_id, menu_total, service_charge_total,
    delivery_fee_total, final_total, confirmed_bank_reference, delivery_payment_mode,
    approved_by
  ) VALUES (
    v_request.id, p_store_id, v_quote.id, v_order.id, v_payment.id,
    NULL::uuid, v_quote.menu_total, v_quote.service_charge_total,
    v_quote.delivery_fee_total, v_quote.final_total,
    NULLIF(btrim(COALESCE(p_confirmed_bank_reference, '')), ''), v_quote.delivery_payment_mode,
    (SELECT auth.uid())
  );

  UPDATE public.direct_order_requests
  SET state = 'approved', approved_at = now(), updated_at = now()
  WHERE id = v_request.id;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, message_type, body,
    metadata
  ) VALUES (
    v_request.id, p_store_id, 'system', 'system',
    'DIRECT_ORDER_PAYMENT_APPROVED',
    jsonb_build_object('order_id', v_order.id, 'ticket_id', v_ticket.id)
  );

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    (SELECT auth.uid()),
    'direct_order_payment_approved',
    'direct_order_requests',
    v_request.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'quote_id', v_quote.id,
      'order_id', v_order.id,
      'payment_id', v_payment.id,
      'ticket_id', v_ticket.id,
      'final_total', v_quote.final_total,
      'review_method', CASE WHEN v_reviewed_proof_id IS NOT NULL
        THEN 'customer_photo' ELSE 'sepay' END,
      'proof_message_id', v_reviewed_proof_id
    )
  );

  PERFORM set_config('app.direct_order_pos_id',COALESCE(v_previous_direct_pos,''),true);
  PERFORM set_config('app.direct_order_request_id',COALESCE(v_previous_direct_request,''),true);
  RETURN jsonb_build_object(
    'request_id', v_request.id,
    'order_id', v_order.id,
    'payment_id', v_payment.id,
    'ticket_id', v_ticket.id,
    'final_total', v_quote.final_total,
    'idempotent', false
  );
END;
$$;

CREATE OR REPLACE FUNCTION "public"."snapshot_direct_order_item_vat"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
 IF TG_OP='INSERT' AND NULLIF(current_setting('pos.direct_prepared_items',true),'') IS NOT NULL THEN
  NEW.combo_components:=current_setting('pos.direct_prepared_items',true)::jsonb->NEW.id::text->'combo_components';
  NEW.combo_drink_choices:=current_setting('pos.direct_prepared_items',true)::jsonb->NEW.id::text->'combo_drink_choices';
  NEW.vat_profile_snapshot:=current_setting('pos.direct_prepared_items',true)::jsonb->NEW.id::text->'vat_profile_snapshot';
  RETURN NEW;
 END IF;
 IF TG_OP='UPDATE' THEN NEW.combo_components:=OLD.combo_components; NEW.combo_drink_choices:=OLD.combo_drink_choices; END IF;
  IF TG_OP='INSERT' THEN
    NEW.vat_profile_snapshot:=public.menu_vat_profile(NEW.menu_item_id,NEW.restaurant_id);
  ELSE NEW.vat_profile_snapshot:=OLD.vat_profile_snapshot;
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION "public"."snapshot_order_item_combo_components"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_payload_text text;
  v_selected jsonb := '[]'::jsonb;
  v_fixed jsonb := '[]'::jsonb;
  v_drinks jsonb := '[]'::jsonb;
  v_direct_enabled boolean := false;
BEGIN
 IF TG_OP='INSERT' AND NULLIF(current_setting('pos.direct_line_snapshots',true),'') IS NOT NULL
  AND current_setting('pos.direct_line_snapshots',true)::jsonb ? NEW.id::text THEN
  NEW.combo_components:=current_setting('pos.direct_line_snapshots',true)::jsonb->NEW.id::text->'combo_components';
  RETURN NEW;
 END IF;
 IF current_setting('globos.cashier_item_mutation',true)='on' THEN RETURN NEW; END IF;
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
$$;

CREATE OR REPLACE FUNCTION "public"."snapshot_order_item_vat"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE direct_profile jsonb;
BEGIN
  IF TG_OP='UPDATE' AND TG_TABLE_NAME='order_items'
    AND (to_jsonb(NEW)->'menu_option_snapshot') IS DISTINCT FROM (to_jsonb(OLD)->'menu_option_snapshot')
    AND (to_jsonb(NEW)-'menu_option_snapshot')=(to_jsonb(OLD)-'menu_option_snapshot') THEN RETURN NEW; END IF;

 IF TG_OP='INSERT' AND NULLIF(current_setting('pos.direct_line_snapshots',true),'') IS NOT NULL
  AND current_setting('pos.direct_line_snapshots',true)::jsonb ? NEW.id::text THEN
  NEW.vat_profile_snapshot:=current_setting('pos.direct_line_snapshots',true)::jsonb->NEW.id::text->'vat_profile_snapshot';
  NEW.vat_rate:=CASE WHEN jsonb_array_length(NEW.vat_profile_snapshot)=1 THEN (NEW.vat_profile_snapshot->0->>'rate')::numeric ELSE -1 END;
  NEW.vat_breakdown:=NULL;
  RETURN NEW;
 END IF;
 IF current_setting('globos.cashier_item_mutation',true)='on' THEN RETURN NEW; END IF;
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
        AND i.restaurant_id=NEW.restaurant_id AND i.id=NEW.id;
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
END $$;

CREATE OR REPLACE FUNCTION "public"."capture_menu_option_batch"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
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
    AND r.id=n.id AND r.restaurant_id=n.restaurant_id
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

CREATE OR REPLACE FUNCTION "public"."direct_order_deduct_combo_stock"("p_store_id" "uuid", "p_request_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $$
DECLARE expected integer; applied integer;
BEGIN
 WITH lines AS MATERIALIZED(SELECT oi.id,oi.quantity,oi.combo_components FROM public.direct_order_financials f
  JOIN public.order_items oi ON oi.order_id=f.order_id AND oi.restaurant_id=f.restaurant_id
  JOIN public.direct_order_request_items i ON i.request_id=f.request_id AND i.id=oi.id
  WHERE f.request_id=p_request_id AND f.restaurant_id=p_store_id AND jsonb_array_length(i.combo_components)>0),
 consumption AS MATERIALIZED(SELECT l.id order_item_id,mr.ingredient_id,
  sum(mr.quantity_g*(c.value->>'quantity')::numeric*CASE WHEN COALESCE((c.value->>'is_total_quantity')::boolean,false) THEN 1 ELSE l.quantity END) quantity
  FROM lines l CROSS JOIN LATERAL jsonb_array_elements(l.combo_components)c
  JOIN public.menu_recipes mr ON mr.menu_item_id=(c.value->>'menu_item_id')::uuid AND mr.restaurant_id=p_store_id
  GROUP BY l.id,mr.ingredient_id),
 totals AS(SELECT ingredient_id,sum(quantity) quantity FROM consumption GROUP BY ingredient_id),
 changed AS(UPDATE public.inventory_items stock SET current_stock=stock.current_stock-t.quantity,updated_at=now()
  FROM totals t WHERE stock.id=t.ingredient_id AND stock.restaurant_id=p_store_id RETURNING stock.id),
 journal AS(INSERT INTO public.inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,reference_type,reference_id,created_by)
  SELECT p_store_id,ingredient_id,'deduct',-quantity,'order_item',order_item_id,auth.uid() FROM consumption RETURNING ingredient_id)
 SELECT (SELECT count(*) FROM totals),(SELECT count(*) FROM changed) INTO expected,applied;
 IF expected<>applied THEN RAISE EXCEPTION 'DIRECT_ORDER_COMBO_STOCK_UNAVAILABLE'; END IF;
END $$;

CREATE OR REPLACE FUNCTION "public"."process_payment_without_scoped_promotions"("p_order_id" "uuid", "p_store_id" "uuid", "p_amount" numeric, "p_method" "text") RETURNS "public"."payments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor                  users%ROWTYPE;
  v_order                  orders%ROWTYPE;
  v_payment                payments%ROWTYPE;
  v_brand                  brands%ROWTYPE;
  v_discount               order_discounts%ROWTYPE;
  v_has_discount           boolean := false;
  v_table_id               uuid;
  v_food_subtotal          decimal(15,2) := 0;
  v_alcohol_subtotal       decimal(15,2) := 0;
  v_menu_inc_total         decimal(15,2) := 0;
  v_menu_inc_cents         bigint := 0;
  v_sc_rate                decimal(5,2)  := 0;
  v_sc_pretax              decimal(15,2);
  v_sc_vat                 decimal(15,2);
  v_sc_total               decimal(15,2);
  v_is_revenue             boolean := true;
  v_payment_method_storage text := p_method;
  v_order_total            decimal(15,2) := 0;
  v_total_paid_before      decimal(15,2) := 0;
  v_total_paid_after       decimal(15,2) := 0;
  v_remaining_due          decimal(15,2) := 0;
  v_should_complete        boolean := false;
  v_vat_pricing_mode       text := 'exclusive';
  v_discount_total         decimal(15,2) := 0;
  v_discount_cents         bigint := 0;
  v_remainder_cents        bigint := 0;
BEGIN
  SELECT * INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier','admin','store_admin','brand_admin','super_admin') THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'PAYMENT_STORE_REQUIRED';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN';
  END IF;

  IF p_method = 'SERVICE' THEN
    v_is_revenue := FALSE;
    v_payment_method_storage := 'OTHER';
  ELSIF p_method NOT IN (
    'CASH','CREDITCARD','ATM','MOMO','ZALOPAY',
    'VNPAY','SHOPEEPAY','BANKTRANSFER','VOUCHER','CREDITSALE','OTHER'
  ) THEN
    RAISE EXCEPTION 'INVALID_PAYMENT_METHOD';
  END IF;

  SELECT * INTO v_order
  FROM orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed','cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_PAYABLE';
  END IF;

  IF COALESCE(v_order.order_purpose, 'customer') = 'staff_meal'
     AND p_method <> 'SERVICE' THEN
    RAISE EXCEPTION 'STAFF_MEAL_SERVICE_REQUIRED';
  END IF;

  -- Contract invariant I3 (ORDER_LIFECYCLE_STATE_CONTRACT_2026_07_03):
  -- an order is payable only when every active item is ready or served.
  IF EXISTS (
    SELECT 1
    FROM order_items oi
    WHERE oi.order_id = p_order_id
      AND oi.status NOT IN ('ready', 'served', 'cancelled')
  ) THEN
    RAISE EXCEPTION 'ORDER_NOT_PAYABLE';
  END IF;

  IF p_amount < 0 THEN
    RAISE EXCEPTION 'PAYMENT_AMOUNT_INVALID';
  END IF;

  SELECT b.* INTO v_brand
  FROM restaurants r
  JOIN brands b ON b.id = r.brand_id
  WHERE r.id = p_store_id;

  SELECT COALESCE(r.vat_pricing_mode, 'exclusive')
  INTO v_vat_pricing_mode
  FROM restaurants r
  WHERE r.id = p_store_id;

  IF FOUND AND v_brand.service_charge_enabled THEN
    v_sc_rate := COALESCE(v_brand.service_charge_rate, 0);
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS payment_discount_lines (
    line_id uuid PRIMARY KEY,
    menu_item_id uuid,
    unit_price numeric(12,2) NOT NULL,
    quantity integer NOT NULL,
    display_name text,
    label text,
    vat_category text NOT NULL,
    vat_rate numeric(5,2) NOT NULL,
    tax_profile jsonb NOT NULL,
    undiscounted_pretax numeric(15,2) NOT NULL,
    undiscounted_vat numeric(15,2) NOT NULL,
    undiscounted_inc numeric(15,2) NOT NULL,
    line_inc_cents bigint NOT NULL,
    base_discount_cents bigint NOT NULL DEFAULT 0,
    discount_fraction numeric NOT NULL DEFAULT 0,
    allocated_discount_cents bigint NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL
  ) ON COMMIT DROP;

  TRUNCATE TABLE payment_discount_lines;

  UPDATE public.order_items SET vat_rate=0,vat_amount=0,total_amount_ex_tax=0,paying_amount_inc_tax=0
  WHERE order_id=p_order_id AND restaurant_id=p_store_id AND status<>'cancelled'
    AND item_type='menu_item' AND is_service_item=true;

  WITH lines AS MATERIALIZED (
    SELECT oi.id,oi.menu_item_id,oi.unit_price,oi.quantity,oi.display_name,oi.label,oi.created_at,
      coalesce(mi.vat_category,'food') vat_category,
      coalesce(oi.vat_profile_snapshot,jsonb_build_array(jsonb_build_object('rate',
        CASE WHEN oi.vat_rate IN (8,10) THEN oi.vat_rate ELSE mi.effective_vat_rate END,'weight',1))) tax_profile
    FROM public.order_items oi LEFT JOIN public.menu_items mi ON mi.id=oi.menu_item_id
    WHERE oi.order_id=p_order_id AND oi.restaurant_id=p_store_id AND oi.status<>'cancelled'
      AND oi.item_type='menu_item' AND coalesce(oi.is_service_item,false)=false
  ), priced AS MATERIALIZED (
    SELECT l.*,public.direct_order_payment_vat(l.tax_profile,round(l.unit_price*l.quantity,2),v_vat_pricing_mode) tax
    FROM lines l
  ), inserted AS (
    INSERT INTO payment_discount_lines(line_id,menu_item_id,unit_price,quantity,display_name,label,
      vat_category,vat_rate,tax_profile,undiscounted_pretax,undiscounted_vat,undiscounted_inc,line_inc_cents,created_at)
    SELECT id,menu_item_id,unit_price,quantity,display_name,label,vat_category,(tax->>'vat_rate')::numeric,
      tax_profile,(tax->>'supply')::numeric,(tax->>'vat')::numeric,(tax->>'total')::numeric,
      round((tax->>'total')::numeric*100)::bigint,created_at FROM priced RETURNING line_id
  ) SELECT
    (SELECT coalesce(sum((tax->>'total')::numeric),0) FROM priced),
    (SELECT coalesce(sum(round((tax->>'total')::numeric*100)::bigint),0) FROM priced),
    coalesce(sum((part->>'total_amount_ex_tax')::numeric) FILTER(WHERE (part->>'vat_rate')::numeric=10),0),
    coalesce(sum((part->>'total_amount_ex_tax')::numeric) FILTER(WHERE (part->>'vat_rate')::numeric=8),0)
  INTO v_menu_inc_total,v_menu_inc_cents,v_alcohol_subtotal,v_food_subtotal
  FROM priced p CROSS JOIN LATERAL jsonb_array_elements(p.tax->'parts') part;


  SELECT *
  INTO v_discount
  FROM order_discounts
  WHERE order_id = p_order_id
    AND restaurant_id = p_store_id
    AND status = 'active'
  FOR UPDATE;

  IF FOUND THEN
    v_has_discount := true;
    IF v_menu_inc_total <= 0 THEN
      RAISE EXCEPTION 'ORDER_TOTAL_INVALID';
    END IF;

    IF v_discount.discount_mode = 'percent' THEN
      v_discount_total := ROUND(v_menu_inc_total * v_discount.discount_value / 100, 2);
    ELSE
      v_discount_total := LEAST(ROUND(v_discount.discount_value, 2), v_menu_inc_total);
    END IF;

    IF v_discount_total < 0 THEN
      RAISE EXCEPTION 'DISCOUNT_AMOUNT_INVALID';
    END IF;

    v_discount_cents := LEAST(ROUND(v_discount_total * 100)::bigint, v_menu_inc_cents);

    IF v_discount_cents > 0 AND v_menu_inc_cents > 0 THEN
      UPDATE payment_discount_lines
      SET base_discount_cents = FLOOR((v_discount_cents::numeric * line_inc_cents::numeric) / v_menu_inc_cents::numeric)::bigint,
          discount_fraction = ((v_discount_cents::numeric * line_inc_cents::numeric) / v_menu_inc_cents::numeric)
            - FLOOR((v_discount_cents::numeric * line_inc_cents::numeric) / v_menu_inc_cents::numeric)
      WHERE line_inc_cents > 0;

      SELECT v_discount_cents - COALESCE(SUM(base_discount_cents), 0)
      INTO v_remainder_cents
      FROM payment_discount_lines;

      WITH ranked AS (
        SELECT
          line_id,
          row_number() OVER (ORDER BY discount_fraction DESC, line_id) AS rn
        FROM payment_discount_lines
      )
      UPDATE payment_discount_lines l
      SET allocated_discount_cents =
        l.base_discount_cents + CASE WHEN ranked.rn <= v_remainder_cents THEN 1 ELSE 0 END
      FROM ranked
      WHERE ranked.line_id = l.line_id;
    END IF;
  END IF;

  -- Final targeted allocation before invoice snapshots.
  IF v_has_discount AND v_discount.approved_via = 'scheduled_promotion'
     AND EXISTS (SELECT 1 FROM public.order_discount_lines
                 WHERE order_discount_id = v_discount.id) THEN
    IF EXISTS (
      SELECT 1 FROM public.order_discount_lines allocation
      LEFT JOIN payment_discount_lines line ON line.line_id = allocation.order_item_id
      WHERE allocation.order_discount_id = v_discount.id
        AND (line.line_id IS NULL OR allocation.discount_amount < 0
          OR round(allocation.discount_amount * 100) > line.line_inc_cents)
    ) OR (SELECT round(sum(discount_amount) * 100)
          FROM public.order_discount_lines WHERE order_discount_id = v_discount.id)
         IS DISTINCT FROM v_discount_cents THEN
      RAISE EXCEPTION 'PROMOTION_ALLOCATION_MISMATCH';
    END IF;
    WITH allocations AS (
      SELECT line.line_id,coalesce(round(a.discount_amount*100)::bigint,0) cents
      FROM payment_discount_lines line LEFT JOIN public.order_discount_lines a
        ON a.order_discount_id=v_discount.id AND a.order_item_id=line.line_id
    ) UPDATE payment_discount_lines line SET allocated_discount_cents=a.cents
    FROM allocations a WHERE a.line_id=line.line_id;
  END IF;

  WITH priced AS MATERIALIZED (
    SELECT line_id,public.direct_order_payment_vat(tax_profile,round(unit_price*quantity,2),
      v_vat_pricing_mode,allocated_discount_cents::numeric/100) tax FROM payment_discount_lines
  ) UPDATE public.order_items oi SET vat_rate=(p.tax->>'vat_rate')::numeric,
    vat_amount=(p.tax->>'vat')::numeric,total_amount_ex_tax=(p.tax->>'supply')::numeric,
    paying_amount_inc_tax=(p.tax->>'total')::numeric,vat_breakdown=p.tax->'parts'
  FROM priced p WHERE oi.id=p.line_id;


  IF v_sc_rate > 0 AND v_food_subtotal > 0 THEN
    v_sc_pretax := ROUND(v_food_subtotal * v_sc_rate / 100, CASE WHEN COALESCE(NULLIF(current_setting('pos.direct_combo_snapshot',true),''),'{}')<>'{}' THEN 0 ELSE 2 END);
    v_sc_vat := ROUND(v_sc_pretax * 8 / 100, CASE WHEN COALESCE(NULLIF(current_setting('pos.direct_combo_snapshot',true),''),'{}')<>'{}' THEN 0 ELSE 2 END);
    v_sc_total := v_sc_pretax + v_sc_vat;

    IF NOT EXISTS (
      SELECT 1 FROM order_items
      WHERE order_id = p_order_id
        AND item_type = 'service_charge'
        AND display_name IN ('Service Charge (Food)','Service Charge (VAT 8%)')
    ) THEN
      INSERT INTO order_items (
        order_id, restaurant_id, item_type, display_name, menu_item_id,
        unit_price, quantity, label, status, vat_rate, vat_amount,
        total_amount_ex_tax, paying_amount_inc_tax
      )
      VALUES (
        p_order_id, p_store_id, 'service_charge', 'Service Charge (VAT 8%)', NULL,
        v_sc_pretax, 1, 'Service Charge (VAT 8%)', 'served', 8, v_sc_vat,
        v_sc_pretax, v_sc_total
      );
    ELSE
      UPDATE order_items
      SET unit_price = v_sc_pretax,
          quantity = 1,
          vat_rate = 8,
          vat_amount = v_sc_vat,
          total_amount_ex_tax = v_sc_pretax,
          paying_amount_inc_tax = v_sc_total,
          status = 'served'
      WHERE order_id = p_order_id
        AND item_type = 'service_charge'
        AND display_name IN ('Service Charge (Food)','Service Charge (VAT 8%)');
    END IF;

  END IF;

  IF v_sc_rate > 0 AND v_alcohol_subtotal > 0 THEN
    v_sc_pretax := ROUND(v_alcohol_subtotal * v_sc_rate / 100, CASE WHEN COALESCE(NULLIF(current_setting('pos.direct_combo_snapshot',true),''),'{}')<>'{}' THEN 0 ELSE 2 END);
    v_sc_vat := ROUND(v_sc_pretax * 10 / 100, CASE WHEN COALESCE(NULLIF(current_setting('pos.direct_combo_snapshot',true),''),'{}')<>'{}' THEN 0 ELSE 2 END);
    v_sc_total := v_sc_pretax + v_sc_vat;

    IF NOT EXISTS (
      SELECT 1 FROM order_items
      WHERE order_id = p_order_id
        AND item_type = 'service_charge'
        AND display_name IN ('Service Charge (Alcohol)','Service Charge (VAT 10%)')
    ) THEN
      INSERT INTO order_items (
        order_id, restaurant_id, item_type, display_name, menu_item_id,
        unit_price, quantity, label, status, vat_rate, vat_amount,
        total_amount_ex_tax, paying_amount_inc_tax
      )
      VALUES (
        p_order_id, p_store_id, 'service_charge', 'Service Charge (VAT 10%)', NULL,
        v_sc_pretax, 1, 'Service Charge (VAT 10%)', 'served', 10, v_sc_vat,
        v_sc_pretax, v_sc_total
      );
    ELSE
      UPDATE order_items
      SET unit_price = v_sc_pretax,
          quantity = 1,
          vat_rate = 10,
          vat_amount = v_sc_vat,
          total_amount_ex_tax = v_sc_pretax,
          paying_amount_inc_tax = v_sc_total,
          status = 'served'
      WHERE order_id = p_order_id
        AND item_type = 'service_charge'
        AND display_name IN ('Service Charge (Alcohol)','Service Charge (VAT 10%)');
    END IF;

  END IF;

  -- Never silently reprice a partly paid legacy zero-VAT charge.
  IF EXISTS (SELECT 1 FROM order_items WHERE order_id = p_order_id
             AND item_type = 'wet_tissue_charge' AND status <> 'cancelled'
             AND vat_rate IS DISTINCT FROM 8)
     AND EXISTS (SELECT 1 FROM payments WHERE order_id = p_order_id) THEN
    RAISE EXCEPTION 'WET_TISSUE_LEGACY_PAYMENT_REVIEW_REQUIRED';
  END IF;
  UPDATE order_items item
  SET vat_rate = 8,
      total_amount_ex_tax = CASE WHEN v_vat_pricing_mode = 'inclusive'
        THEN round(item.unit_price * item.quantity / 1.08, 2)
        ELSE item.unit_price * item.quantity END,
      vat_amount = CASE WHEN v_vat_pricing_mode = 'inclusive'
        THEN item.unit_price * item.quantity - round(item.unit_price * item.quantity / 1.08, 2)
        ELSE round(item.unit_price * item.quantity * .08, 2) END,
      paying_amount_inc_tax = CASE WHEN v_vat_pricing_mode = 'inclusive'
        THEN item.unit_price * item.quantity ELSE round(item.unit_price * item.quantity * 1.08, 2) END
  WHERE item.order_id = p_order_id AND item.restaurant_id = p_store_id
    AND item.item_type = 'wet_tissue_charge' AND item.status <> 'cancelled'
    AND NOT EXISTS (SELECT 1 FROM payments WHERE order_id = p_order_id);

  SELECT ROUND(COALESCE(SUM(COALESCE(paying_amount_inc_tax, unit_price * quantity)), 0), 2)
  INTO v_order_total
  FROM order_items
  WHERE order_id = p_order_id
    AND status <> 'cancelled'
    AND COALESCE(is_service_item, false) = false;

  IF v_order_total < 0 OR (v_order_total <= 0 AND NOT v_has_discount) THEN
    RAISE EXCEPTION 'ORDER_TOTAL_INVALID';
  END IF;

  SELECT COALESCE(SUM(amount_portion), 0)
  INTO v_total_paid_before
  FROM payments
  WHERE order_id = p_order_id;

  v_remaining_due := ROUND(v_order_total - v_total_paid_before, 2);

  IF v_remaining_due < -0.01 THEN
    RAISE EXCEPTION 'PAYMENT_AMOUNT_EXCEEDS_REMAINING';
  END IF;

  IF GREATEST(v_remaining_due, 0) <= 0.01 THEN
    IF ABS(ROUND(COALESCE(p_amount, -1), 2)) > 0.01 THEN
      RAISE EXCEPTION 'PAYMENT_AMOUNT_EXCEEDS_REMAINING';
    END IF;
  ELSE
    IF ROUND(COALESCE(p_amount, -1), 2) <= 0 THEN
      RAISE EXCEPTION 'PAYMENT_AMOUNT_INVALID';
    END IF;

    IF ROUND(COALESCE(p_amount, -1), 2) - v_remaining_due > 0.01 THEN
      RAISE EXCEPTION 'PAYMENT_AMOUNT_EXCEEDS_REMAINING';
    END IF;
  END IF;

  v_total_paid_after := ROUND(v_total_paid_before + p_amount, 2);
  v_should_complete := v_total_paid_after >= v_order_total - 0.01;

  INSERT INTO payments (
    order_id,
    restaurant_id,
    amount,
    method,
    processed_by,
    is_revenue,
    amount_portion
  )
  VALUES (
    p_order_id,
    p_store_id,
    p_amount,
    v_payment_method_storage,
    auth.uid(),
    v_is_revenue,
    p_amount
  )
  RETURNING * INTO v_payment;

  IF v_has_discount AND v_should_complete THEN
    UPDATE order_discounts
    SET status = 'consumed',
        discount_amount = v_discount_cents::numeric / 100,
        updated_at = now()
    WHERE id = v_discount.id;
  END IF;

  IF v_should_complete THEN
    UPDATE orders
    SET status = 'completed', updated_at = now()
    WHERE id = p_order_id
    RETURNING table_id INTO v_table_id;

    IF v_table_id IS NOT NULL THEN
      UPDATE tables
      SET status = 'available', updated_at = now()
      WHERE id = v_table_id;
    END IF;

    -- Lock the complete ingredient set in stable order, then consume and post
    -- one ledger row per order line / ingredient. No item -> recipe SQL loop.
    PERFORM stock.id FROM public.inventory_items stock
    JOIN (SELECT DISTINCT mr.ingredient_id
      FROM public.order_items oi JOIN public.menu_recipes mr
        ON mr.menu_item_id=oi.menu_item_id AND mr.restaurant_id=p_store_id
      WHERE oi.order_id=p_order_id AND oi.restaurant_id=p_store_id
        AND oi.item_type='menu_item' AND (oi.status<>'cancelled' OR oi.cancelled_consumed_quantity>0)
        AND NOT (coalesce(nullif(current_setting('pos.direct_combo_snapshot',true),''),'{}')::jsonb ? oi.id::text)
    ) ingredients ON ingredients.ingredient_id=stock.id
    WHERE stock.restaurant_id=p_store_id ORDER BY stock.id FOR UPDATE OF stock;
    WITH consumption AS MATERIALIZED (
      SELECT oi.id order_item_id,mr.ingredient_id,
        sum((CASE WHEN oi.status='cancelled' THEN oi.cancelled_consumed_quantity
          ELSE oi.quantity+oi.cancelled_consumed_quantity END)*mr.quantity_g) quantity
      FROM public.order_items oi JOIN public.menu_recipes mr
        ON mr.menu_item_id=oi.menu_item_id AND mr.restaurant_id=p_store_id
      WHERE oi.order_id=p_order_id AND oi.restaurant_id=p_store_id
        AND oi.item_type='menu_item' AND (oi.status<>'cancelled' OR oi.cancelled_consumed_quantity>0)
        AND NOT (coalesce(nullif(current_setting('pos.direct_combo_snapshot',true),''),'{}')::jsonb ? oi.id::text)
      GROUP BY oi.id,mr.ingredient_id
    ), totals AS (SELECT ingredient_id,sum(quantity) quantity FROM consumption GROUP BY ingredient_id),
    changed AS (UPDATE public.inventory_items stock SET current_stock=stock.current_stock-t.quantity,updated_at=now()
      FROM totals t WHERE stock.id=t.ingredient_id AND stock.restaurant_id=p_store_id RETURNING stock.id)
    INSERT INTO public.inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,reference_type,reference_id,created_by)
    SELECT p_store_id,c.ingredient_id,'deduct',-c.quantity,'order_item',c.order_item_id,auth.uid()
    FROM consumption c;


  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'process_payment',
    'payments',
    v_payment.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', p_order_id,
      'amount', p_amount,
      'input_method', p_method,
      'stored_method', v_payment_method_storage,
      'is_revenue', v_is_revenue,
      'order_total', v_order_total,
      'discount_id', CASE WHEN v_has_discount THEN v_discount.id ELSE NULL END,
      'discount_amount', v_discount_cents::numeric / 100,
      'total_paid_before', v_total_paid_before,
      'total_paid_after', v_total_paid_after,
      'payment_completes_order', v_should_complete
    )
  );

  RETURN v_payment;
END;
$$;

DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.direct_order_request_items'::regclass
  AND conname='direct_order_request_items_request_id_menu_item_id_key') THEN
  RAISE EXCEPTION 'MIGRATION_DIRECT_LINE_UNIQUENESS_REQUIRED'; END IF;
 IF has_function_privilege('anon','public.direct_order_approve_payment(uuid,uuid,numeric,text)','EXECUTE')
 OR has_function_privilege('authenticated','public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)','EXECUTE') THEN
  RAISE EXCEPTION 'MIGRATION_DIRECT_LINE_ACCESS_INVALID'; END IF;
END $$;
NOTIFY pgrst,'reload schema';
COMMIT;
