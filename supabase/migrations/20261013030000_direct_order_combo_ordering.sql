-- Customer combo selection; checker mutations and payment anchor stay unchanged.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';
CREATE TABLE public.direct_order_combo_20261013_backup(identity text PRIMARY KEY,definition text NOT NULL);
ALTER TABLE public.direct_order_combo_20261013_backup ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.direct_order_combo_20261013_backup FROM PUBLIC,anon,authenticated,service_role;
INSERT INTO public.direct_order_combo_20261013_backup
SELECT signature,pg_get_functiondef(signature::regprocedure) FROM unnest(ARRAY[
 'public.process_payment(uuid,uuid,numeric,text)',
 'public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)',
 'public.process_payment_before_promotion_read_split(uuid,uuid,numeric,text)',
 'public.kds_complete_kitchen_batch_v1(uuid,jsonb)',
 'public.kds_complete_kitchen_batch_before_customer_progress(uuid,jsonb)',
 'public.direct_order_public_storefront_v2(text)',
 'public.direct_order_public_submit(uuid,text,uuid,jsonb)',
 'public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)',
 'public.direct_order_approve_payment(uuid,uuid,numeric,text)',
 'public.snapshot_order_item_combo_components()',
 'public.snapshot_order_item_vat()',
 'public.snapshot_direct_order_item_vat()',
 'public.direct_order_quote_preview_core(uuid,uuid,boolean)',
 'public.direct_order_staff_payment_document(uuid,uuid,uuid,integer,boolean)'
]) signature;
ALTER TABLE public.direct_order_request_items
 ADD COLUMN combo_drink_choices jsonb NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(combo_drink_choices)='array' AND jsonb_array_length(combo_drink_choices)<=500),
 ADD COLUMN combo_components jsonb NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(combo_components)='array');
CREATE INDEX direct_order_public_menu_page ON public.menu_items(restaurant_id,sort_order,id)
 WHERE is_available AND is_visible_public AND NOT is_archived;

-- Validate and hydrate at most 50 lines / 100 units in sets. The caller has
-- already validated its scoped session. Never accept client prices or taxes.
CREATE FUNCTION public.direct_order_prepare_combo_items(p_store_id uuid,p_items jsonb) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
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
 SELECT jsonb_agg(jsonb_build_object('menu_item_id',l.id,'display_name',l.name,
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
END $$;
REVOKE ALL ON FUNCTION public.direct_order_prepare_combo_items(uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;

-- Request item inserts use the single prepared batch; legacy inserts retain
-- their existing VAT behavior. Updates keep the saved component/tax snapshot.
DO $request_trigger$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.snapshot_direct_order_item_vat()'::regprocedure) INTO d;
 IF strpos(d,E'BEGIN\n')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_COMBO_ANCHOR_DRIFT'; END IF;
 d:=replace(d,E'BEGIN\n',$patch$BEGIN
 IF TG_OP='INSERT' AND NULLIF(current_setting('pos.direct_prepared_items',true),'') IS NOT NULL THEN
  NEW.combo_components:=current_setting('pos.direct_prepared_items',true)::jsonb->NEW.menu_item_id::text->'combo_components';
  NEW.combo_drink_choices:=current_setting('pos.direct_prepared_items',true)::jsonb->NEW.menu_item_id::text->'combo_drink_choices';
  NEW.vat_profile_snapshot:=current_setting('pos.direct_prepared_items',true)::jsonb->NEW.menu_item_id::text->'vat_profile_snapshot';
  RETURN NEW;
 END IF;
 IF TG_OP='UPDATE' THEN NEW.combo_components:=OLD.combo_components; NEW.combo_drink_choices:=OLD.combo_drink_choices; END IF;
$patch$); EXECUTE d;
END $request_trigger$;

DO $submit$
DECLARE d text; signature text; a integer; b integer;
BEGIN
 FOREACH signature IN ARRAY ARRAY['public.direct_order_public_submit(uuid,text,uuid,jsonb)','public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)'] LOOP
  SELECT pg_get_functiondef(signature::regprocedure) INTO d;
  a:=strpos(d,'  FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->''items'')');
  b:=strpos(d,'  IF v_total_quantity > 100 THEN');
  IF a=0 OR b<=a THEN RAISE EXCEPTION 'DIRECT_ORDER_COMBO_ANCHOR_DRIFT'; END IF;
  d:=replace(d,E'DECLARE\n',E'DECLARE\n  v_prepared jsonb; v_previous_prepared text;\n');
  a:=strpos(d,'  FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->''items'')'); b:=strpos(d,'  IF v_total_quantity > 100 THEN');
  d:=substr(d,1,a-1)||$items$  v_prepared:=public.direct_order_prepare_combo_items(v_session.restaurant_id,p_payload->'items');
  v_previous_prepared:=current_setting('pos.direct_prepared_items',true);
  PERFORM set_config('pos.direct_prepared_items',(SELECT jsonb_object_agg(e->>'menu_item_id',e) FROM jsonb_array_elements(v_prepared)e)::text,true);
  INSERT INTO public.direct_order_request_items(request_id,restaurant_id,menu_item_id,display_name,name_ko,name_vi,name_en,vat_category,unit_price,quantity,item_note,sort_order,combo_drink_choices,combo_components,vat_profile_snapshot)
  SELECT v_request.id,v_request.restaurant_id,(e->>'menu_item_id')::uuid,e->>'display_name',e->>'name_ko',e->>'name_vi',e->>'name_en',e->>'vat_category',
   (e->>'unit_price')::numeric,(e->>'quantity')::integer,e->>'item_note',(e->>'sort_order')::integer,e->'combo_drink_choices',e->'combo_components',e->'vat_profile_snapshot'
  FROM jsonb_array_elements(v_prepared)e;
  PERFORM set_config('pos.direct_prepared_items',COALESCE(v_previous_prepared,''),true);
  SELECT sum((e->>'quantity')::integer) INTO v_total_quantity FROM jsonb_array_elements(v_prepared)e;
$items$||substr(d,b);
  IF strpos(d,'  SELECT * INTO v_existing')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_COMBO_ANCHOR_DRIFT'; END IF;
  d:=replace(d,'  SELECT * INTO v_existing',E'  PERFORM pg_advisory_xact_lock(hashtextextended(v_session.restaurant_id::text||'':direct-submit:''||p_client_request_id::text,0));\n  SELECT * INTO v_existing');
  EXECUTE d;
 END LOOP;
END $submit$;

CREATE FUNCTION public.direct_order_validate_combo_request(p_store_id uuid,p_request_id uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF EXISTS(
  WITH lines AS MATERIALIZED(SELECT i.*,p.is_combo,p.is_archived,p.combo_drink_choice_count FROM public.direct_order_request_items i
   JOIN public.menu_items p ON p.id=i.menu_item_id AND p.restaurant_id=p_store_id
   WHERE i.request_id=p_request_id AND i.restaurant_id=p_store_id AND jsonb_array_length(i.combo_components)>0),
  saved AS MATERIALIZED(SELECT i.id,c.value FROM lines i CROSS JOIN LATERAL jsonb_array_elements(i.combo_components)c),
  availability AS(SELECT s.id,bool_and(m.id IS NOT NULL AND m.is_available AND m.is_visible_public AND NOT m.is_archived AND NOT m.is_combo
    AND m.price>0 AND (m.category_id IS NULL OR COALESCE(cat.is_active,false))
    AND (NOT COALESCE((s.value->>'is_total_quantity')::boolean,false) OR cat.system_key='drink')) valid
   FROM saved s LEFT JOIN public.menu_items m ON m.id=(s.value->>'menu_item_id')::uuid AND m.restaurant_id=p_store_id
   LEFT JOIN public.menu_categories cat ON cat.id=m.category_id AND cat.restaurant_id=p_store_id GROUP BY s.id),
  current_fixed AS(SELECT l.id,jsonb_agg(jsonb_build_array(co.component_menu_item_id,co.quantity) ORDER BY co.component_menu_item_id) signature
   FROM lines l JOIN public.menu_combo_components co ON co.combo_menu_item_id=l.menu_item_id AND co.restaurant_id=p_store_id
   JOIN public.menu_items m ON m.id=co.component_menu_item_id AND m.restaurant_id=p_store_id
   WHERE l.combo_drink_choice_count=0 OR lower(btrim(COALESCE(NULLIF(m.name_ko,''),m.name))) NOT IN('음료','drink','beverage','đồ uống','nước uống') GROUP BY l.id),
  saved_fixed AS(SELECT id,jsonb_agg(jsonb_build_array((value->>'menu_item_id')::uuid,COALESCE(NULLIF((value->>'fixed_quantity')::integer,0),(value->>'quantity')::integer))
    ORDER BY (value->>'menu_item_id')::uuid) signature FROM saved WHERE NOT COALESCE((value->>'is_total_quantity')::boolean,false) OR COALESCE((value->>'fixed_quantity')::integer,0)>0 GROUP BY id)
  SELECT 1 FROM lines l LEFT JOIN availability a ON a.id=l.id LEFT JOIN current_fixed cf ON cf.id=l.id LEFT JOIN saved_fixed sf ON sf.id=l.id
  WHERE NOT l.is_combo OR l.is_archived OR jsonb_array_length(l.combo_drink_choices)<>l.combo_drink_choice_count*l.quantity
   OR NOT COALESCE(a.valid,false) OR COALESCE(cf.signature,'[]') IS DISTINCT FROM COALESCE(sf.signature,'[]')
 ) THEN RAISE EXCEPTION 'DIRECT_ORDER_COMBO_UNAVAILABLE'; END IF;
END $$;
REVOKE ALL ON FUNCTION public.direct_order_validate_combo_request(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
-- New combo orders use whole VND VAT consistently in quote and payment.
-- Keep the general two-decimal calculator and historical financials intact.
CREATE FUNCTION public.direct_order_combo_vnd_vat(p_profile jsonb,p_amount numeric,p_mode text,p_discount numeric DEFAULT 0) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=public,pg_catalog AS $$
DECLARE original jsonb; result_parts jsonb; supply numeric; vat numeric; total numeric;
BEGIN
 original:=public.calculate_item_vat(p_profile,p_amount,p_mode,p_discount);
 WITH parts AS(SELECT e,(e->>'vat_amount')::numeric original_vat,(e->>'paying_amount_inc_tax')::numeric gross,
  (e->>'total_amount_ex_tax')::numeric base FROM jsonb_array_elements(original->'parts')e),
 rounded AS(SELECT e,(e->>'vat_rate')::numeric rate,round(original_vat) tax,
  CASE WHEN p_mode='inclusive' THEN gross-round(original_vat) ELSE base END base FROM parts)
 SELECT jsonb_agg(jsonb_build_object('vat_rate',rate,'total_amount_ex_tax',base,'vat_amount',tax,'paying_amount_inc_tax',base+tax) ORDER BY rate),
 sum(base),sum(tax),sum(base+tax) INTO result_parts,supply,vat,total FROM rounded;
 RETURN jsonb_build_object('vat_rate',original->'vat_rate','supply',supply,'vat',vat,'total',total,'parts',result_parts);
END $$;
REVOKE ALL ON FUNCTION public.direct_order_combo_vnd_vat(jsonb,numeric,text,numeric) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.direct_order_payment_vat(p_profile jsonb,p_amount numeric,p_mode text,p_discount numeric DEFAULT 0) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=public,pg_catalog AS $$
 SELECT CASE WHEN COALESCE(NULLIF(current_setting('pos.direct_combo_snapshot',true),''),'{}')<>'{}'
 THEN public.direct_order_combo_vnd_vat($1,$2,$3,$4) ELSE public.calculate_item_vat($1,$2,$3,$4) END
$$;
REVOKE ALL ON FUNCTION public.direct_order_payment_vat(jsonb,numeric,text,numeric) FROM PUBLIC,anon,authenticated,service_role;
DO $preview$ DECLARE d text; BEGIN
 SELECT pg_get_functiondef('public.direct_order_quote_preview_core(uuid,uuid,boolean)'::regprocedure) INTO d;
 IF strpos(d,' WITH priced AS MATERIALIZED(')=0 OR strpos(d,'public.calculate_item_vat(')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_COMBO_ANCHOR_DRIFT'; END IF;
 d:=replace(d,'DECLARE mode text;','DECLARE v_combo boolean; mode text;');
 d:=replace(d,' WITH priced AS MATERIALIZED(',E' IF p_validate_menu THEN PERFORM public.direct_order_validate_combo_request(p_store_id,p_request_id); END IF;\n SELECT EXISTS(SELECT 1 FROM public.direct_order_request_items WHERE request_id=p_request_id AND restaurant_id=p_store_id AND jsonb_array_length(combo_components)>0) INTO v_combo;\n WITH priced AS MATERIALIZED(');
 d:=replace(d,'public.calculate_item_vat(','CASE WHEN v_combo THEN public.direct_order_combo_vnd_vat(');
 d:=replace(d,'round(i.unit_price*i.quantity,2),mode) tax',
  'round(i.unit_price*i.quantity,2),mode) ELSE public.calculate_item_vat(COALESCE(NULLIF(to_jsonb(i)->''vat_profile_snapshot'',''null''::jsonb),jsonb_build_array(jsonb_build_object(''rate'',CASE WHEN i.vat_category=''alcohol'' THEN 10 ELSE 8 END,''weight'',1))),round(i.unit_price*i.quantity,2),mode) END tax');
 d:=replace(d,'supply*rate/100,2','supply*rate/100,CASE WHEN v_combo THEN 0 ELSE 2 END');
 d:=replace(d,'*vat_rate/100,2','*vat_rate/100,CASE WHEN v_combo THEN 0 ELSE 2 END');
 EXECUTE d;
END $preview$;

-- All order rows use their saved request snapshots, without per-item lookups.
DO $order_triggers$ DECLARE d text; signature text; patch text; BEGIN
 FOREACH signature IN ARRAY ARRAY['public.snapshot_order_item_combo_components()','public.snapshot_order_item_vat()'] LOOP
  SELECT pg_get_functiondef(signature::regprocedure) INTO d;
  IF strpos(d,'BEGIN')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_COMBO_ANCHOR_DRIFT'; END IF;
  patch:=$guard$BEGIN
 IF TG_OP='INSERT' AND NULLIF(current_setting('pos.direct_combo_snapshot',true),'') IS NOT NULL
  AND current_setting('pos.direct_combo_snapshot',true)::jsonb ? NEW.menu_item_id::text THEN
$guard$;
  IF signature LIKE '%combo_components%' THEN patch:=patch||$combo$  NEW.combo_components:=current_setting('pos.direct_combo_snapshot',true)::jsonb->NEW.menu_item_id::text->'combo_components';
$combo$;
  ELSE patch:=patch||$vat$  NEW.vat_profile_snapshot:=current_setting('pos.direct_combo_snapshot',true)::jsonb->NEW.menu_item_id::text->'vat_profile_snapshot';
  NEW.vat_rate:=CASE WHEN jsonb_array_length(NEW.vat_profile_snapshot)=1 THEN (NEW.vat_profile_snapshot->0->>'rate')::numeric ELSE -1 END;
  NEW.vat_breakdown:=NULL;
$vat$; END IF;
  patch:=patch||E'  RETURN NEW;\n END IF;\n';
  d:=regexp_replace(d,'BEGIN',patch); EXECUTE d;
 END LOOP;
END $order_triggers$;
DO $payment_rounding$ DECLARE d text; signature text; BEGIN
 FOREACH signature IN ARRAY ARRAY['public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)','public.process_payment_before_promotion_read_split(uuid,uuid,numeric,text)'] LOOP
  SELECT pg_get_functiondef(signature::regprocedure) INTO d;
  IF strpos(d,'public.calculate_item_vat(')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_COMBO_ANCHOR_DRIFT'; END IF;
  d:=replace(d,'public.calculate_item_vat(','public.direct_order_payment_vat(');
  d:=replace(d,'* v_sc_rate / 100, 2','* v_sc_rate / 100, CASE WHEN COALESCE(NULLIF(current_setting(''pos.direct_combo_snapshot'',true),''''),''{}'')<>''{}'' THEN 0 ELSE 2 END');
  d:=replace(d,'v_sc_pretax * 8 / 100, 2','v_sc_pretax * 8 / 100, CASE WHEN COALESCE(NULLIF(current_setting(''pos.direct_combo_snapshot'',true),''''),''{}'')<>''{}'' THEN 0 ELSE 2 END');
  d:=replace(d,'v_sc_pretax * 10 / 100, 2','v_sc_pretax * 10 / 100, CASE WHEN COALESCE(NULLIF(current_setting(''pos.direct_combo_snapshot'',true),''''),''{}'')<>''{}'' THEN 0 ELSE 2 END');
  EXECUTE d;
 END LOOP;
END $payment_rounding$;
-- The shared payment entry remains byte-identical. Only new direct-combo
-- parents skip its legacy parent-recipe deduction; their actual components
-- are deducted once in the same approval transaction, in sets.
DO $stock_guard$ DECLARE d text; a integer; b integer; segment text; BEGIN
 SELECT pg_get_functiondef('public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)'::regprocedure) INTO d;
 b:=strpos(d,'      FOR v_recipe IN');
 IF b=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_COMBO_ANCHOR_DRIFT'; END IF;
 a:=b-length(split_part(reverse(substr(d,1,b-1)),reverse('    FOR v_item IN'),1))-length('    FOR v_item IN');
 segment:=substr(d,a,b-a);
 IF strpos(segment,'AND oi.item_type = ''menu_item''')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_COMBO_ANCHOR_DRIFT'; END IF;
 segment:=replace(segment,'AND oi.item_type = ''menu_item''',
  'AND oi.item_type = ''menu_item'' AND NOT (COALESCE(NULLIF(current_setting(''pos.direct_combo_snapshot'',true),''''),''{}'')::jsonb ? oi.menu_item_id::text)');
 d:=substr(d,1,a-1)||segment||substr(d,b); EXECUTE d;
END $stock_guard$;
CREATE FUNCTION public.direct_order_deduct_combo_stock(p_store_id uuid,p_request_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE expected integer; applied integer;
BEGIN
 WITH lines AS MATERIALIZED(SELECT oi.id,oi.quantity,oi.combo_components FROM public.direct_order_financials f
  JOIN public.order_items oi ON oi.order_id=f.order_id AND oi.restaurant_id=f.restaurant_id
  JOIN public.direct_order_request_items i ON i.request_id=f.request_id AND i.menu_item_id=oi.menu_item_id
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
REVOKE ALL ON FUNCTION public.direct_order_deduct_combo_stock(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.direct_order_lock_combo_stock(p_store_id uuid,p_request_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 PERFORM stock.id FROM public.inventory_items stock JOIN(
  SELECT DISTINCT mr.ingredient_id FROM public.menu_recipes mr JOIN(
   SELECT i.menu_item_id FROM public.direct_order_request_items i WHERE i.request_id=p_request_id AND i.restaurant_id=p_store_id
   UNION SELECT (c.value->>'menu_item_id')::uuid FROM public.direct_order_request_items i
    CROSS JOIN LATERAL jsonb_array_elements(i.combo_components)c WHERE i.request_id=p_request_id AND i.restaurant_id=p_store_id
  ) menus ON menus.menu_item_id=mr.menu_item_id WHERE mr.restaurant_id=p_store_id
 ) used ON used.ingredient_id=stock.id WHERE stock.restaurant_id=p_store_id ORDER BY stock.id FOR UPDATE OF stock;
END $$;
REVOKE ALL ON FUNCTION public.direct_order_lock_combo_stock(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
ALTER FUNCTION public.direct_order_approve_payment(uuid,uuid,numeric,text) RENAME TO direct_order_approve_payment_before_combo;
REVOKE ALL ON FUNCTION public.direct_order_approve_payment_before_combo(uuid,uuid,numeric,text) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.direct_order_approve_payment(p_store_id uuid,p_request_id uuid,p_confirmed_amount numeric,p_confirmed_bank_reference text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE previous_snapshot text; result jsonb; snapshot jsonb; already_approved boolean;
BEGIN
 previous_snapshot:=current_setting('pos.direct_combo_snapshot',true);
 PERFORM public.direct_order_require_actor(p_store_id,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 PERFORM pg_advisory_xact_lock(hashtextextended('direct-order-approval:'||p_request_id::text,0));
 PERFORM 1 FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id FOR UPDATE;
 already_approved:=EXISTS(SELECT 1 FROM public.direct_order_financials WHERE request_id=p_request_id);
 IF NOT already_approved THEN
  PERFORM public.direct_order_validate_combo_request(p_store_id,p_request_id);
 END IF;
 SELECT jsonb_object_agg(i.menu_item_id::text,jsonb_build_object('vat_profile_snapshot',i.vat_profile_snapshot,
  'combo_components',(SELECT jsonb_agg(c||jsonb_build_object('fulfillment_route','kitchen_tray_floor')) FROM jsonb_array_elements(i.combo_components)c)))
 INTO snapshot FROM public.direct_order_request_items i WHERE i.request_id=p_request_id AND i.restaurant_id=p_store_id AND jsonb_array_length(i.combo_components)>0;
 IF NOT already_approved AND snapshot IS NOT NULL THEN PERFORM public.direct_order_lock_combo_stock(p_store_id,p_request_id); END IF;
 PERFORM set_config('pos.direct_combo_snapshot',COALESCE(snapshot,'{}')::text,true);
 result:=public.direct_order_approve_payment_before_combo(p_store_id,p_request_id,p_confirmed_amount,p_confirmed_bank_reference);
 IF NOT already_approved THEN PERFORM public.direct_order_deduct_combo_stock(p_store_id,p_request_id); END IF;
 PERFORM set_config('pos.direct_combo_snapshot',COALESCE(previous_snapshot,''),true);
 RETURN result;
EXCEPTION WHEN OTHERS THEN
 PERFORM set_config('pos.direct_combo_snapshot',COALESCE(previous_snapshot,''),true); RAISE;
END $$;
REVOKE ALL ON FUNCTION public.direct_order_approve_payment(uuid,uuid,numeric,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_approve_payment(uuid,uuid,numeric,text) TO authenticated,service_role;

-- Versioned reads preserve strict response contracts of cached old clients.
CREATE FUNCTION public.direct_order_public_status_v11(p_session_id uuid,p_secret_hash text,p_request_id uuid) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE payload jsonb; items jsonb;
BEGIN
 payload:=public.direct_order_public_status_v10($1,$2,$3);
 SELECT COALESCE(jsonb_agg(e.raw||CASE WHEN jsonb_array_length(i.combo_components)>0 THEN jsonb_build_object('combo_components',i.combo_components) ELSE '{}'::jsonb END ORDER BY e.ord),'[]')
 INTO items FROM jsonb_array_elements(payload->'items') WITH ORDINALITY e(raw,ord)
 LEFT JOIN public.direct_order_request_items i ON i.request_id=$3 AND i.menu_item_id=(e.raw->>'menu_item_id')::uuid;
 RETURN jsonb_set(payload,'{items}',items);
END $$;
REVOKE ALL ON FUNCTION public.direct_order_public_status_v11(uuid,text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_status_v11(uuid,text,uuid) TO service_role;
CREATE FUNCTION public.direct_order_staff_detail_v8(p_store_id uuid,p_request_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE payload jsonb; items jsonb;
BEGIN
 payload:=public.direct_order_staff_detail_v7($1,$2);
 SELECT COALESCE(jsonb_agg(e.raw||CASE WHEN jsonb_array_length(i.combo_components)>0 THEN jsonb_build_object('combo_components',i.combo_components) ELSE '{}'::jsonb END ORDER BY e.ord),'[]')
 INTO items FROM jsonb_array_elements(payload->'items') WITH ORDINALITY e(raw,ord)
 LEFT JOIN public.direct_order_request_items i ON i.request_id=$2 AND i.restaurant_id=$1 AND i.menu_item_id=(e.raw->>'menu_item_id')::uuid;
 RETURN jsonb_set(payload,'{items}',items);
END $$;
REVOKE ALL ON FUNCTION public.direct_order_staff_detail_v8(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_detail_v8(uuid,uuid) TO authenticated,service_role;
DO $documents$ DECLARE d text; needle text:='round(i.quantity*i.unit_price,2)) ORDER BY i.sort_order,i.id)'; BEGIN
 SELECT pg_get_functiondef('public.direct_order_staff_payment_document(uuid,uuid,uuid,integer,boolean)'::regprocedure) INTO d;
 IF strpos(d,needle)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_COMBO_ANCHOR_DRIFT'; END IF;
 d:=replace(d,needle,'round(i.quantity*i.unit_price,2))||CASE WHEN jsonb_array_length(i.combo_components)>0 THEN jsonb_build_object(''combo_components'',i.combo_components) ELSE ''{}''::jsonb END ORDER BY i.sort_order,i.id)');EXECUTE d;
END $documents$;

-- Page first, then aggregate only the page's fixed components. Drink options
-- are one store-scoped set shared by every choice combo on this page.
CREATE FUNCTION public.direct_order_public_storefront_v3(p_slug text,p_after_sort integer DEFAULT NULL,p_after_id uuid DEFAULT NULL,p_limit integer DEFAULT 200) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH shop AS MATERIALIZED(SELECT r.*,sf.public_slug,sf.is_paused,sf.ordering_hours_enforced,sf.ordering_starts_at,sf.ordering_cutoff_at,sf.minimum_order_amount,
  sf.default_latitude,sf.default_longitude,sf.bank_bin,sf.bank_account_number,sf.bank_account_holder,sf.bank_label
  FROM public.restaurants r JOIN public.direct_order_storefronts sf ON sf.restaurant_id=r.id
  WHERE sf.public_slug=lower(btrim(p_slug)) AND sf.is_enabled AND r.is_active),
 options AS MATERIALIZED(SELECT m.* FROM public.menu_items m JOIN shop s ON s.id=m.restaurant_id
  JOIN public.menu_categories cat ON cat.id=m.category_id AND cat.restaurant_id=m.restaurant_id AND cat.is_active AND cat.system_key='drink'
  WHERE m.is_available AND m.is_visible_public AND NOT m.is_archived AND NOT m.is_combo AND m.price>0),
 component_stock AS MATERIALIZED(SELECT co.combo_menu_item_id parent,count(*) component_count,
  bool_and(cm.id IS NOT NULL AND cm.is_available AND cm.is_visible_public AND NOT cm.is_archived AND NOT cm.is_combo
   AND cm.price>0 AND co.quantity>0 AND (cm.category_id IS NULL OR COALESCE(cc.is_active,false))) valid
  FROM public.menu_combo_components co JOIN public.menu_items pm ON pm.id=co.combo_menu_item_id AND pm.restaurant_id=co.restaurant_id
  JOIN shop s ON s.id=co.restaurant_id LEFT JOIN public.menu_items cm ON cm.id=co.component_menu_item_id AND cm.restaurant_id=co.restaurant_id
  LEFT JOIN public.menu_categories cc ON cc.id=cm.category_id AND cc.restaurant_id=co.restaurant_id
  WHERE cm.id IS NULL OR pm.combo_drink_choice_count=0 OR lower(btrim(COALESCE(NULLIF(cm.name_ko,''),cm.name))) NOT IN('음료','drink','beverage','đồ uống','nước uống')
  GROUP BY co.combo_menu_item_id),
 eligible AS NOT MATERIALIZED(SELECT m.* FROM public.menu_items m JOIN shop s ON s.id=m.restaurant_id
  LEFT JOIN public.menu_categories cat ON cat.id=m.category_id AND cat.restaurant_id=m.restaurant_id
  LEFT JOIN component_stock cs ON cs.parent=m.id
  WHERE m.is_available AND m.is_visible_public AND NOT m.is_archived AND (m.category_id IS NULL OR cat.is_active)
   AND (NOT m.is_combo OR (COALESCE(cs.valid,false) AND cs.component_count>0
    AND (m.combo_drink_choice_count=0 OR EXISTS(SELECT 1 FROM options))))),
 page_plus AS MATERIALIZED(SELECT * FROM eligible WHERE p_after_id IS NULL OR (sort_order,id)>(p_after_sort,p_after_id)
  ORDER BY sort_order,id LIMIT greatest(1,least(COALESCE(p_limit,200),200))+1),
 page AS MATERIALIZED(SELECT * FROM page_plus ORDER BY sort_order,id LIMIT greatest(1,least(COALESCE(p_limit,200),200))),
 components AS(SELECT co.combo_menu_item_id parent,jsonb_agg(jsonb_build_object('menu_item_id',cm.id,
   'name_ko',COALESCE(NULLIF(cm.name_ko,''),cm.name),'name_vi',COALESCE(NULLIF(cm.name_vi,''),cm.name),'name_en',COALESCE(NULLIF(cm.name_en,''),cm.name),'quantity',co.quantity)
   ORDER BY co.sort_order,co.id) data FROM public.menu_combo_components co JOIN page p ON p.id=co.combo_menu_item_id
   JOIN public.menu_items cm ON cm.id=co.component_menu_item_id AND cm.restaurant_id=p.restaurant_id
   WHERE co.restaurant_id=p.restaurant_id AND (p.combo_drink_choice_count=0 OR lower(btrim(COALESCE(NULLIF(cm.name_ko,''),cm.name))) NOT IN('음료','drink','beverage','đồ uống','nước uống')) GROUP BY co.combo_menu_item_id),
 option_data AS(SELECT COALESCE(jsonb_agg(jsonb_build_object('menu_item_id',id,'name_ko',COALESCE(NULLIF(name_ko,''),name),
  'name_vi',COALESCE(NULLIF(name_vi,''),name),'name_en',COALESCE(NULLIF(name_en,''),name),'quantity',1) ORDER BY sort_order,id),'[]') data FROM options)
 SELECT jsonb_build_object('store_id',s.id,'store_name',s.name,'store_address',s.address,'slug',s.public_slug,
 'paused',s.is_paused OR (s.ordering_hours_enforced AND NOT public.direct_order_is_within_hours(s.ordering_starts_at,s.ordering_cutoff_at)),
 'ordering_starts_at',s.ordering_starts_at,'ordering_cutoff_at',s.ordering_cutoff_at,'minimum_order_amount',s.minimum_order_amount,
 'default_latitude',s.default_latitude,'default_longitude',s.default_longitude,
 'bank',jsonb_build_object('bin',s.bank_bin,'account_number',s.bank_account_number,'account_holder',s.bank_account_holder,'label',s.bank_label),
 'categories',(SELECT COALESCE(jsonb_agg(jsonb_build_object('id',c.id,'name_ko',COALESCE(NULLIF(c.name_ko,''),c.name),
  'name_vi',COALESCE(NULLIF(c.name_vi,''),c.name),'name_en',COALESCE(NULLIF(c.name_en,''),c.name),'sort_order',c.sort_order) ORDER BY c.sort_order,c.id),'[]')
  FROM public.menu_categories c WHERE c.restaurant_id=s.id AND c.is_active AND EXISTS(SELECT 1 FROM eligible e WHERE e.category_id=c.id)),
 'items',(SELECT COALESCE(jsonb_agg(jsonb_build_object('id',p.id,'category_id',p.category_id,'name_ko',COALESCE(NULLIF(p.name_ko,''),p.name),
  'name_vi',COALESCE(NULLIF(p.name_vi,''),p.name),'name_en',COALESCE(NULLIF(p.name_en,''),p.name),'description',p.description,'price',p.price,'image_url',p.image_url,
  'vat_category',p.vat_category,'sort_order',p.sort_order,'is_combo',p.is_combo,'combo_drink_choice_count',p.combo_drink_choice_count,
  'combo_components',COALESCE(c.data,'[]')) ORDER BY p.sort_order,p.id),'[]')
  FROM page p LEFT JOIN components c ON c.parent=p.id CROSS JOIN option_data od),
 'combo_drink_options',(SELECT data FROM option_data),
 'next_cursor',CASE WHEN (SELECT count(*) FROM page_plus)>greatest(1,least(COALESCE(p_limit,200),200))
  THEN (SELECT jsonb_build_object('sort_order',sort_order,'id',id) FROM page ORDER BY sort_order DESC,id DESC LIMIT 1) ELSE NULL END
 ) FROM shop s;
$$;
REVOKE ALL ON FUNCTION public.direct_order_public_storefront_v3(text,integer,uuid,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_storefront_v3(text,integer,uuid,integer) TO service_role;

DO $verify$ BEGIN
 IF EXISTS(SELECT 1 FROM public.direct_order_combo_20261013_backup b WHERE b.identity IN(
  'public.process_payment(uuid,uuid,numeric,text)','public.kds_complete_kitchen_batch_v1(uuid,jsonb)',
  'public.kds_complete_kitchen_batch_before_customer_progress(uuid,jsonb)','public.direct_order_public_storefront_v2(text)')
  AND md5(b.definition)<>md5(pg_get_functiondef(b.identity::regprocedure)))
 OR has_function_privilege('anon','public.direct_order_prepare_combo_items(uuid,jsonb)','EXECUTE')
 OR has_function_privilege('authenticated','public.direct_order_prepare_combo_items(uuid,jsonb)','EXECUTE')
 OR has_function_privilege('anon','public.direct_order_public_storefront_v3(text,integer,uuid,integer)','EXECUTE')
 OR has_function_privilege('authenticated','public.direct_order_approve_payment_before_combo(uuid,uuid,numeric,text)','EXECUTE')
 THEN RAISE EXCEPTION 'DIRECT_ORDER_COMBO_VERIFICATION_FAILED'; END IF;
END $verify$;
NOTIFY pgrst,'reload schema';
COMMIT;
