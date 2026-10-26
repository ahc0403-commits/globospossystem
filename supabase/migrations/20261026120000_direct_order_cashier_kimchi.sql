-- Atomic request acceptance, bounded attachment authorization and catalog consolidation.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

CREATE FUNCTION public.direct_order_staff_attachment_context(p_store_id uuid,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE r record;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 SELECT id,support_closed_at,state,pii_purged_at INTO r FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1;
 IF NOT FOUND OR r.pii_purged_at IS NOT NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 RETURN jsonb_build_object('support',jsonb_build_object('chat_open',r.support_closed_at IS NULL
   AND r.state NOT IN('cancelled','expired','rejected') AND public.direct_order_access_is_open(r.id)));
END $$;
REVOKE ALL ON FUNCTION public.direct_order_staff_attachment_context(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_attachment_context(uuid,uuid) TO authenticated;

CREATE FUNCTION public.direct_order_staff_accept_requirement(p_store_id uuid,p_request_id uuid,
 p_requirement_id uuid,p_expected_version integer,p_mutation_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE q public.direct_order_customer_requirements%ROWTYPE; r public.direct_order_requests%ROWTYPE;
 printable text; body text; previous public.direct_order_messages%ROWTYPE;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 SELECT * INTO r FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF r.pii_purged_at IS NOT NULL OR r.support_closed_at IS NOT NULL OR r.state IN('cancelled','expired','rejected')
   OR NOT public.direct_order_access_is_open(r.id) THEN RAISE EXCEPTION 'DIRECT_ORDER_ORDER_CLOSED'; END IF;
 SELECT * INTO q FROM public.direct_order_customer_requirements WHERE id=$3 AND request_id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUIREMENT_NOT_FOUND'; END IF;
 IF $5 IS NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUIREMENT_REPLY_INVALID'; END IF;
 SELECT * INTO previous FROM public.direct_order_messages WHERE request_id=$2 AND metadata->>'requirement_mutation_id'=$5::text;
 IF FOUND THEN
  IF previous.metadata->>'requirement_id' IS DISTINCT FROM $3::text OR previous.metadata->>'accepted_original' IS DISTINCT FROM 'true'
    THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUIREMENT_VERSION_CONFLICT'; END IF;
  RETURN public.direct_order_staff_detail_v8($1,$2);
 END IF;
 IF q.version IS DISTINCT FROM $4 OR q.status<>'awaiting_reply' THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUIREMENT_VERSION_CONFLICT'; END IF;
 printable:=CASE WHEN q.source_locale='vi' THEN q.request_text ELSE
  (SELECT translated_text FROM public.direct_order_translation_jobs WHERE request_id=$2 AND source_id=q.source_id
   AND source_text=q.request_text AND target_locale='vi' AND status='translated' ORDER BY completed_at DESC,id DESC LIMIT 1) END;
 printable:=coalesce(nullif(printable,''),q.print_request_vi,
  CASE WHEN q.request_text ~ '^[ -~ÀÁÂÃÈÉÊÌÍÒÓÔÕÙÚÝàáâãèéêìíòóôõùúýĂăĐđĨĩŨũƠơƯưẠ-ỹ]+$' THEN q.request_text END);
 IF q.print_scope<>'cashier' AND (printable IS NULL OR NOT printable ~ '^[ -~ÀÁÂÃÈÉÊÌÍÒÓÔÕÙÚÝàáâãèéêìíòóôõùúýĂăĐđĨĩŨũƠơƯưẠ-ỹ]+$')
  THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUIREMENT_REPLY_INVALID'; END IF;
 body:=CASE q.source_locale WHEN 'ko' THEN '요청하신 내용으로 수락했습니다.' WHEN 'en' THEN 'Your request has been accepted.' ELSE 'Đã chấp nhận yêu cầu của bạn.' END;
 PERFORM public.direct_order_staff_reply_requirement($1,$2,$3,$4,$5,body,q.source_locale,false,
   coalesce(printable,''),coalesce(printable,''),q.print_scope);
 UPDATE public.direct_order_messages SET metadata=metadata||jsonb_build_object('accepted_original',true)
  WHERE request_id=$2 AND metadata->>'requirement_mutation_id'=$5::text;
 RETURN public.direct_order_staff_detail_v8($1,$2);
END $$;
REVOKE ALL ON FUNCTION public.direct_order_staff_accept_requirement(uuid,uuid,uuid,integer,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_accept_requirement(uuid,uuid,uuid,integer,uuid) TO authenticated;

-- Department projections carry preparation instructions, not cashier chat replies.
DO $notes$
DECLARE sig text; d text; changed integer:=0;
BEGIN
 FOREACH sig IN ARRAY ARRAY['public.emergency_enrich_start_ready_orders(jsonb)',
  'public.emergency_enrich_start_ready_orders_pre_options(jsonb)',
  'public.direct_delivery_ticket_list_v3(uuid,text[],integer)',
  'public.bunsik_kds_enrich_orders_v1(jsonb,text)',
  'public.jeongabok_kds_enrich_orders_v1(jsonb,text)'] LOOP
  IF to_regprocedure(sig) IS NULL THEN CONTINUE; END IF;
  d:=pg_get_functiondef(sig::regprocedure);
  IF strpos(d,'q.print_reply_vi')>0 THEN
   d:=replace(d,'q.print_reply_vi','(CASE WHEN q.needs_confirmation THEN q.print_reply_vi ELSE q.print_request_vi END)');
  ELSIF strpos(d,'n.print_reply_vi')>0 THEN
   d:=replace(d,'n.print_reply_vi','(CASE WHEN n.needs_confirmation THEN n.print_reply_vi ELSE n.print_request_vi END)');
  ELSE CONTINUE;
  END IF;
  EXECUTE d; changed:=changed+1;
 END LOOP;
 IF changed<2 THEN RAISE EXCEPTION 'DIRECT_ORDER_PREPARATION_NOTE_DRIFT'; END IF;
 d:=pg_get_functiondef('public.direct_order_requirement_print_snapshot(uuid,text)'::regprocedure);
 IF strpos(d,'''reply_text'',reply_text')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_PREPARATION_NOTE_DRIFT'; END IF;
 EXECUTE replace(d,'''reply_text'',reply_text','''reply_text'',CASE WHEN $2=''receipt'' THEN reply_text ELSE NULL END');
END $notes$;

DO $$ BEGIN
 IF has_function_privilege('anon','public.direct_order_staff_attachment_context(uuid,uuid)','EXECUTE')
 OR has_function_privilege('anon','public.direct_order_staff_accept_requirement(uuid,uuid,uuid,integer,uuid)','EXECUTE') THEN
 RAISE EXCEPTION 'DIRECT_ORDER_ACCEPTANCE_ACL_FAILED'; END IF;
END $$;

-- menu-consolidation-section
-- Original sellable IDs stay available to existing combos and frozen orders.
-- They disappear only from standalone catalogs after explicit consolidation.
ALTER TABLE public.menu_items ADD COLUMN catalog_parent_id uuid REFERENCES public.menu_items(id);
ALTER TABLE public.menu_items ADD CONSTRAINT menu_catalog_parent_not_self CHECK(catalog_parent_id IS NULL OR catalog_parent_id<>id);
CREATE INDEX menu_catalog_parent_idx ON public.menu_items(catalog_parent_id) WHERE catalog_parent_id IS NOT NULL;
CREATE FUNCTION public.guard_menu_catalog_parent() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF NEW.catalog_parent_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.menu_items p
  WHERE p.id=NEW.catalog_parent_id AND p.restaurant_id=NEW.restaurant_id AND p.catalog_parent_id IS NULL)
 THEN RAISE EXCEPTION 'MENU_SELECTION_DEFINITION_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM public.menu_items c WHERE c.catalog_parent_id=NEW.id AND (c.restaurant_id<>NEW.restaurant_id OR NEW.catalog_parent_id IS NOT NULL))
 THEN RAISE EXCEPTION 'MENU_SELECTION_DEFINITION_INVALID'; END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.guard_menu_catalog_parent() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER guard_menu_catalog_parent BEFORE INSERT OR UPDATE OF catalog_parent_id,restaurant_id ON public.menu_items
 FOR EACH ROW EXECUTE FUNCTION public.guard_menu_catalog_parent();

DO $catalogs$
DECLARE sig text; d text;
BEGIN
 FOREACH sig IN ARRAY ARRAY['public.direct_order_public_storefront_pre_options(text)',
  'public.direct_order_public_storefront_v3_pre_options(text,integer,uuid,integer)',
  'public.qr_get_menu_pre_takeout_availability(text)'] LOOP
  d:=pg_get_functiondef(sig::regprocedure);
  IF sig LIKE '%v3_pre_options%' THEN
   IF strpos(d,'WHERE m.is_available AND m.is_visible_public AND NOT m.is_archived AND (m.category_id')=0 THEN RAISE EXCEPTION 'MENU_CATALOG_ANCHOR_DRIFT'; END IF;
   d:=replace(d,'WHERE m.is_available AND m.is_visible_public AND NOT m.is_archived AND (m.category_id',
    'WHERE m.catalog_parent_id IS NULL AND m.is_available AND m.is_visible_public AND NOT m.is_archived AND (m.category_id');
  ELSE
   IF strpos(d,'AND menu.is_available = true')=0 THEN RAISE EXCEPTION 'MENU_CATALOG_ANCHOR_DRIFT'; END IF;
   d:=replace(d,'AND menu.is_available = true','AND menu.catalog_parent_id IS NULL AND menu.is_available = true');
  END IF;
  EXECUTE d;
 END LOOP;
 -- Reject a stale standalone cart, while keeping existing combo components valid.
 d:=pg_get_functiondef('public.validate_menu_option_batch(uuid,jsonb,text)'::regprocedure);
 IF strpos(d,'WHERE CASE WHEN m.choice_definition')=0 THEN RAISE EXCEPTION 'MENU_CATALOG_ANCHOR_DRIFT'; END IF;
 EXECUTE replace(d,'WHERE CASE WHEN m.choice_definition','WHERE m.catalog_parent_id IS NOT NULL OR CASE WHEN m.choice_definition');
END $catalogs$;

-- The legacy QR facade otherwise queries drink options and promotion targets
-- once per catalog row. Aggregate both once for the selected store/promotion.
DO $qr_batch$
DECLARE d text; promotion_clause text;
BEGIN
 d:=pg_get_functiondef('public.qr_get_menu_pre_takeout_availability(text)'::regprocedure);
 IF strpos(d,'public.combo_drink_options(menu.id)')>0 THEN
  IF strpos(d,'v_items jsonb')=0 THEN RAISE EXCEPTION 'MENU_CATALOG_ANCHOR_DRIFT'; END IF;
  d:=replace(d,'v_items jsonb', $new$v_drink_options jsonb; v_promotion_targets uuid[]; v_items jsonb$new$);
  d:=replace(d,'public.combo_drink_choice_count(menu.id)','menu.combo_drink_choice_count');
  d:=replace(d,'public.combo_drink_options(menu.id)','v_drink_options');
  promotion_clause:=$old$NOT EXISTS (
             SELECT 1
             FROM public.store_promotion_menu_items target
             WHERE target.promotion_id = v_promotion.id
               AND target.restaurant_id = v_table.restaurant_id
               AND target.menu_item_id = menu.id
           )$old$;
  IF strpos(d,promotion_clause)=0 THEN RAISE EXCEPTION 'MENU_CATALOG_ANCHOR_DRIFT'; END IF;
  d:=replace(d,promotion_clause,'NOT (menu.id=ANY(v_promotion_targets))');
  d:=replace(d,$old$  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', menu.id$old$,
  $new$  SELECT COALESCE(array_agg(target.menu_item_id),'{}'::uuid[]) INTO v_promotion_targets
  FROM public.store_promotion_menu_items target WHERE target.promotion_id=v_promotion.id
    AND target.restaurant_id=v_table.restaurant_id;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id',option_item.id::text,'name',option_item.name,
    'name_ko',COALESCE(NULLIF(option_item.name_ko,''),option_item.name),
    'name_vi',COALESCE(NULLIF(option_item.name_vi,''),option_item.name),
    'name_en',COALESCE(NULLIF(option_item.name_en,''),option_item.name))
    ORDER BY option_item.sort_order,option_item.name,option_item.id),'[]'::jsonb) INTO v_drink_options
  FROM public.menu_items option_item JOIN public.menu_categories drink_category
    ON drink_category.id=option_item.category_id AND drink_category.restaurant_id=option_item.restaurant_id
  WHERE option_item.restaurant_id=v_table.restaurant_id AND drink_category.system_key='drink' AND drink_category.is_active
    AND NOT option_item.is_archived AND option_item.is_available AND option_item.is_visible_public AND NOT option_item.is_combo;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', menu.id$new$);
  IF strpos(d,'INTO v_drink_options')=0 OR strpos(d,'target.menu_item_id = menu.id')>0 THEN RAISE EXCEPTION 'MENU_CATALOG_ANCHOR_DRIFT'; END IF;
  EXECUTE d;
 END IF;
END $qr_batch$;

-- Hidden source sellables are not rows omitted from a replacement workbook.
DO $workbook$
DECLARE sig text:='public.admin_update_menu_workbook_i18n_catalog(uuid,jsonb,jsonb)'; d text;
BEGIN
 IF to_regprocedure(sig) IS NOT NULL THEN
  d:=pg_get_functiondef(sig::regprocedure);
  IF strpos(d,'AND mi.is_archived = false')=0 THEN RAISE EXCEPTION 'MENU_CATALOG_ANCHOR_DRIFT'; END IF;
  EXECUTE replace(d,'AND mi.is_archived = false','AND mi.is_archived = false AND mi.catalog_parent_id IS NULL');
 END IF;
END $workbook$;

CREATE FUNCTION public.admin_consolidate_kimchi_jjigae(p_store_id uuid,p_sources jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE base public.menu_items; parent public.menu_items; definition jsonb; ids uuid[]; duplicate_ids uuid[];
 common_recipe jsonb; existing_parent uuid; expected_names text[]:=ARRAY['돼지고기 김치찌개 (쌀밥포함)','해물 김치찌개 (쌀밥포함)','참치 김치찌개 (쌀밥포함)'];
BEGIN
 PERFORM public.require_admin_actor_for_restaurant($1);
 PERFORM pg_advisory_xact_lock(hashtextextended($1::text,0));
 IF p_sources IS NULL THEN
  WITH candidates AS MATERIALIZED(SELECT id,name_ko FROM public.menu_items WHERE restaurant_id=$1
    AND name_ko=ANY(expected_names) AND NOT is_archived AND NOT is_combo AND size_parent_id IS NULL),
  recipe_counts AS(SELECT r.menu_item_id,count(*) n FROM public.menu_recipes r JOIN candidates c ON c.id=r.menu_item_id
    WHERE r.restaurant_id=$1 GROUP BY r.menu_item_id),
  chosen AS(SELECT DISTINCT ON(c.name_ko) c.* FROM candidates c LEFT JOIN recipe_counts r ON r.menu_item_id=c.id
    ORDER BY c.name_ko,coalesce(r.n,0) DESC,c.id),
  labels AS(SELECT * FROM (VALUES(1,'pork','돼지고기','Thịt heo','Pork'),(2,'seafood','해산물','Hải sản','Seafood'),(3,'tuna','참치','Cá ngừ','Tuna')) v(ord,value_id,ko,vi,en))
  SELECT jsonb_agg(jsonb_build_object('menu_id',c.id,'value_id',l.value_id,'name_ko',l.ko,'name_vi',l.vi,'name_en',l.en) ORDER BY l.ord)
    INTO p_sources FROM labels l JOIN chosen c ON c.name_ko=expected_names[l.ord];
 END IF;
 IF jsonb_typeof($2) IS DISTINCT FROM 'array' OR jsonb_array_length($2)<>3 THEN RAISE EXCEPTION 'MENU_SELECTION_DEFINITION_INVALID'; END IF;
 SELECT array_agg((x->>'menu_id')::uuid ORDER BY ord) INTO ids FROM jsonb_array_elements($2) WITH ORDINALITY s(x,ord);
 IF (SELECT count(DISTINCT id) FROM unnest(ids) id)<>3 THEN RAISE EXCEPTION 'MENU_SELECTION_DEFINITION_INVALID'; END IF;
 PERFORM id FROM public.menu_items WHERE id=ANY(ids) AND restaurant_id=$1 ORDER BY id FOR UPDATE;
 IF (SELECT count(*) FROM public.menu_items WHERE id=ANY(ids) AND restaurant_id=$1 AND NOT is_archived AND NOT is_combo AND size_parent_id IS NULL)<>3
 THEN RAISE EXCEPTION 'MENU_SELECTION_DEFINITION_INVALID'; END IF;
 SELECT * INTO base FROM public.menu_items WHERE id=ids[1];
 SELECT catalog_parent_id INTO existing_parent FROM public.menu_items WHERE id=ids[1];
 IF existing_parent IS NOT NULL THEN
  IF (SELECT bool_and(catalog_parent_id=existing_parent) FROM public.menu_items WHERE id=ANY(ids))
   THEN RETURN jsonb_build_object('menu_id',existing_parent,'idempotent',true); END IF;
  RAISE EXCEPTION 'MENU_SELECTION_DEFINITION_INVALID';
 END IF;
 IF EXISTS(SELECT 1 FROM unnest(ids) WITH ORDINALITY x(id,ord) JOIN public.menu_items m USING(id)
   WHERE m.name_ko<>expected_names[ord] OR m.price<>CASE WHEN ord=2 THEN 69000 ELSE 59000 END
   OR m.category_id IS DISTINCT FROM base.category_id OR m.vat_category IS DISTINCT FROM base.vat_category OR m.catalog_parent_id IS NOT NULL
   OR m.choice_definition<>'{}'::jsonb OR m.meal_choices OR m.size_prices<>'{}'::jsonb)
  OR EXISTS(SELECT 1 FROM public.store_promotion_menu_items WHERE menu_item_id=ANY(ids))
 THEN RAISE EXCEPTION 'MENU_SELECTION_DEFINITION_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM public.menu_items extra WHERE extra.restaurant_id=$1 AND extra.name_ko=ANY(expected_names)
   AND extra.id<>ALL(ids) AND NOT extra.is_archived AND extra.catalog_parent_id IS NULL
   AND (EXISTS(SELECT 1 FROM public.menu_recipes r WHERE r.menu_item_id=extra.id)
    OR EXISTS(SELECT 1 FROM public.menu_combo_components c WHERE c.component_menu_item_id=extra.id)))
 THEN RAISE EXCEPTION 'MENU_SELECTION_DEFINITION_INVALID'; END IF;
 -- One bounded set reads all recipes. The common exact quantities are retained;
 -- differences are attached to the selected value, never inferred multipliers.
 WITH recipes AS MATERIALIZED(SELECT menu_item_id,ingredient_id,sum(quantity_g) qty FROM public.menu_recipes
  WHERE restaurant_id=$1 AND menu_item_id=ANY(ids) GROUP BY menu_item_id,ingredient_id),
 common AS(SELECT ingredient_id,min(qty) qty FROM recipes GROUP BY ingredient_id HAVING count(*)=3)
 SELECT coalesce(jsonb_agg(jsonb_build_object('ingredient_id',ingredient_id,'quantity_g',qty) ORDER BY ingredient_id),'[]') INTO common_recipe FROM common;
 IF jsonb_array_length(common_recipe)=0 THEN RAISE EXCEPTION 'MENU_SELECTION_RECIPE_INVALID'; END IF;
 WITH variants AS(SELECT x,ord,m.price,m.id FROM jsonb_array_elements($2) WITH ORDINALITY s(x,ord) JOIN public.menu_items m ON m.id=(x->>'menu_id')::uuid),
 recipes AS MATERIALIZED(SELECT menu_item_id,ingredient_id,sum(quantity_g) qty FROM public.menu_recipes
  WHERE restaurant_id=$1 AND menu_item_id=ANY(ids) GROUP BY menu_item_id,ingredient_id),
 additions AS(SELECT r.menu_item_id,jsonb_agg(jsonb_build_object('ingredient_id',r.ingredient_id,'quantity_g',r.qty-coalesce((c->>'quantity_g')::numeric,0)) ORDER BY r.ingredient_id) recipe
  FROM recipes r LEFT JOIN jsonb_array_elements(common_recipe)c ON (c->>'ingredient_id')::uuid=r.ingredient_id
  WHERE r.qty>coalesce((c->>'quantity_g')::numeric,0) GROUP BY r.menu_item_id)
 SELECT jsonb_build_object('schema_version',1,'groups',jsonb_build_array(jsonb_build_object('id','kimchi_protein',
  'name_ko','주재료 선택','name_vi','Chọn nguyên liệu chính','name_en','Choose protein','min',1,'max',1,'repeat',false,
  'channels',jsonb_build_array('pos','qr','direct'),'values',jsonb_agg(jsonb_build_object('id',v.x->>'value_id',
   'name_ko',v.x->>'name_ko','name_vi',v.x->>'name_vi','name_en',v.x->>'name_en','price_delta',v.price-base.price,
   'available',true,'default_quantity',0,'recipe_additions',coalesce(a.recipe,'[]'::jsonb)) ORDER BY v.ord))), 'rules','[]'::jsonb)
 INTO definition FROM variants v LEFT JOIN additions a ON a.menu_item_id=v.id;
 IF NOT public.menu_choice_definition_valid(definition) THEN RAISE EXCEPTION 'MENU_SELECTION_DEFINITION_INVALID'; END IF;
 parent:=public.admin_create_menu_item_with_options($1,base.category_id,'김치찌개 (쌀밥포함)',
  'Canh Kimchi (Kèm Cơm Trắng)','Kimchi Stew (Rice Included)',NULL,base.price,
  jsonb_build_object('choice_definition',definition),base.sort_order,true,NULL,base.invoice_sale_unit);
 INSERT INTO public.menu_recipes(restaurant_id,menu_item_id,ingredient_id,quantity_g)
 SELECT $1,parent.id,(r->>'ingredient_id')::uuid,(r->>'quantity_g')::numeric FROM jsonb_array_elements(common_recipe)r;
 UPDATE public.menu_items SET image_url=base.image_url,is_visible_public=base.is_visible_public WHERE id=parent.id;
 -- Same-name records with no recipe/combination reference remain auditable too.
 SELECT array_agg(m.id) INTO duplicate_ids FROM public.menu_items m WHERE m.restaurant_id=$1 AND m.name_ko=ANY(expected_names)
  AND m.id<>ALL(ids) AND NOT m.is_combo AND NOT m.is_archived AND m.catalog_parent_id IS NULL
  AND NOT EXISTS(SELECT 1 FROM public.menu_recipes r WHERE r.menu_item_id=m.id)
  AND NOT EXISTS(SELECT 1 FROM public.menu_combo_components c WHERE c.component_menu_item_id=m.id);
 UPDATE public.menu_items SET catalog_parent_id=parent.id,updated_at=clock_timestamp()
 WHERE restaurant_id=$1 AND (id=ANY(ids) OR id=ANY(coalesce(duplicate_ids,'{}'::uuid[])));
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'menu_catalog_consolidated','menu_items',parent.id,
  jsonb_build_object('restaurant_id',$1,'source_menu_ids',ids,'duplicate_menu_ids',duplicate_ids,'preserved_prices',true));
 RETURN jsonb_build_object('menu_id',parent.id,'source_menu_ids',ids,'idempotent',false);
END $$;
REVOKE ALL ON FUNCTION public.admin_consolidate_kimchi_jjigae(uuid,jsonb) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.admin_consolidate_kimchi_jjigae(uuid,jsonb) TO authenticated;

DO $$ BEGIN
 IF has_function_privilege('anon','public.admin_consolidate_kimchi_jjigae(uuid,jsonb)','EXECUTE')
 OR has_function_privilege('service_role','public.admin_consolidate_kimchi_jjigae(uuid,jsonb)','EXECUTE')
 OR NOT has_function_privilege('authenticated','public.admin_consolidate_kimchi_jjigae(uuid,jsonb)','EXECUTE') THEN
 RAISE EXCEPTION 'MENU_CONSOLIDATION_ACL_FAILED'; END IF;
END $$;
NOTIFY pgrst,'reload schema';
COMMIT;
