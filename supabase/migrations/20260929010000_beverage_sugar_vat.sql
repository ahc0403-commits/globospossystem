BEGIN;
SET LOCAL lock_timeout = '5s';

-- Expand only. Historical payment and invoice rows are never reclassified.
CREATE TABLE public.beverage_vat_20260929_backup (
  object_identity text PRIMARY KEY,
  definition text NOT NULL
);
ALTER TABLE public.beverage_vat_20260929_backup ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.beverage_vat_20260929_backup FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.menu_effective_vat_rate(p_category text, p_sugar_class text)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT CASE WHEN p_category = 'alcohol' OR p_sugar_class = 'gt_5' THEN 10::numeric ELSE 8::numeric END
$$;

ALTER TABLE public.menu_items
  ADD COLUMN beverage_sugar_tax_class text NOT NULL DEFAULT 'not_applicable',
  ADD COLUMN sugar_g_per_100ml numeric,
  ADD COLUMN tax_basis_note text,
  ADD COLUMN effective_vat_rate numeric(5,2) GENERATED ALWAYS AS (
    public.menu_effective_vat_rate(vat_category, beverage_sugar_tax_class)
  ) STORED,
  ADD CONSTRAINT menu_beverage_tax_valid CHECK (
    beverage_sugar_tax_class IN ('not_applicable','lte_5','gt_5')
    AND (sugar_g_per_100ml IS NULL OR sugar_g_per_100ml BETWEEN 0 AND 100)
    AND char_length(COALESCE(tax_basis_note,'')) <= 500
    AND (vat_category <> 'alcohol' OR beverage_sugar_tax_class = 'not_applicable')
    AND (NOT is_combo OR beverage_sugar_tax_class='not_applicable')
    AND CASE WHEN beverage_sugar_tax_class = 'not_applicable' THEN sugar_g_per_100ml IS NULL
      WHEN sugar_g_per_100ml IS NULL THEN NULLIF(btrim(tax_basis_note),'') IS NOT NULL
      ELSE beverage_sugar_tax_class = CASE WHEN sugar_g_per_100ml > 5 THEN 'gt_5' ELSE 'lte_5' END END
  );
COMMENT ON COLUMN public.menu_items.beverage_sugar_tax_class IS
  '2026 VAT: eligible labelled soft drink >5g/100ml=10%; <=5=8%. not_applicable preserves food/alcohol classification. Review VAT relief at year end.';

CREATE FUNCTION public.admin_set_menu_beverage_tax(p_item_id uuid, p_tax jsonb)
RETURNS public.menu_items LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth, pg_catalog AS $$
DECLARE v_old public.menu_items; v_new public.menu_items; v_class text; v_sugar numeric; v_note text;
BEGIN
  SELECT * INTO v_old FROM public.menu_items WHERE id=p_item_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND'; END IF;
  PERFORM public.require_admin_actor_for_restaurant(v_old.restaurant_id);
  IF p_tax IS NULL OR jsonb_typeof(p_tax) <> 'object'
    OR NOT p_tax ? 'beverage_sugar_tax_class'
    OR jsonb_typeof(p_tax->'beverage_sugar_tax_class') <> 'string'
    OR (p_tax ? 'sugar_g_per_100ml' AND jsonb_typeof(p_tax->'sugar_g_per_100ml') NOT IN ('number','null'))
    OR (p_tax ? 'tax_basis_note' AND jsonb_typeof(p_tax->'tax_basis_note') NOT IN ('string','null')) THEN
    RAISE EXCEPTION 'MENU_TAX_INVALID';
  END IF;
  v_class := p_tax->>'beverage_sugar_tax_class';
  v_sugar := (p_tax->>'sugar_g_per_100ml')::numeric;
  v_note := NULLIF(btrim(p_tax->>'tax_basis_note'),'');
  IF v_class NOT IN ('not_applicable','lte_5','gt_5')
    OR (v_sugar IS NOT NULL AND NOT (v_sugar BETWEEN 0 AND 100))
    OR char_length(COALESCE(v_note,'')) > 500
    OR ((v_old.vat_category='alcohol' OR v_old.is_combo) AND v_class <> 'not_applicable')
    OR (v_class='not_applicable' AND v_sugar IS NOT NULL)
    OR (v_class<>'not_applicable' AND v_sugar IS NULL AND v_note IS NULL)
    OR (v_class<>'not_applicable' AND v_sugar IS NOT NULL
      AND v_class <> CASE WHEN v_sugar>5 THEN 'gt_5' ELSE 'lte_5' END) THEN
    RAISE EXCEPTION 'MENU_TAX_INVALID';
  END IF;
  UPDATE public.menu_items SET beverage_sugar_tax_class=v_class,
    sugar_g_per_100ml=v_sugar,tax_basis_note=v_note,updated_at=now()
  WHERE id=p_item_id RETURNING * INTO v_new;
  IF ROW(v_old.beverage_sugar_tax_class,v_old.sugar_g_per_100ml,v_old.tax_basis_note)
     IS DISTINCT FROM ROW(v_new.beverage_sugar_tax_class,v_new.sugar_g_per_100ml,v_new.tax_basis_note) THEN
    INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
    VALUES(auth.uid(),'admin_update_menu_beverage_tax','menu_items',p_item_id,
      jsonb_build_object('store_id',v_old.restaurant_id,
        'old_values',jsonb_build_object('class',v_old.beverage_sugar_tax_class,'sugar',v_old.sugar_g_per_100ml,'basis',v_old.tax_basis_note,'vat_rate',v_old.effective_vat_rate),
        'new_values',jsonb_build_object('class',v_class,'sugar',v_sugar,'basis',v_note,'vat_rate',v_new.effective_vat_rate)));
  END IF;
  RETURN v_new;
END $$;
REVOKE ALL ON FUNCTION public.admin_set_menu_beverage_tax(uuid,jsonb) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.admin_set_menu_beverage_tax(uuid,jsonb) TO authenticated;

CREATE FUNCTION public.admin_create_menu_item_with_tax(
  p_store_id uuid,p_category_id uuid,p_name_ko text,p_name_vi text,p_name_en text,
  p_paperless_name_vi text,p_price numeric,p_tax jsonb,
  p_sort_order integer DEFAULT 0,p_is_available boolean DEFAULT true
) RETURNS public.menu_items LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public,auth,pg_catalog AS $$
DECLARE v_item public.menu_items;
BEGIN
  v_item := public.admin_create_menu_item_i18n_paperless(p_store_id,p_category_id,
    p_name_ko,p_name_vi,p_name_en,p_paperless_name_vi,p_price,p_sort_order,p_is_available);
  RETURN public.admin_set_menu_beverage_tax(v_item.id,p_tax);
END $$;
CREATE FUNCTION public.admin_update_menu_item_with_tax(
  p_item_id uuid,p_name_ko text,p_name_vi text,p_name_en text,
  p_paperless_name_vi text,p_price numeric,p_tax jsonb
) RETURNS public.menu_items LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public,auth,pg_catalog AS $$
BEGIN
  PERFORM public.admin_update_menu_item_i18n_paperless(p_item_id,p_name_ko,p_name_vi,
    p_name_en,p_paperless_name_vi,p_price);
  RETURN public.admin_set_menu_beverage_tax(p_item_id,p_tax);
END $$;
REVOKE ALL ON FUNCTION public.admin_create_menu_item_with_tax(uuid,uuid,text,text,text,text,numeric,jsonb,integer,boolean) FROM PUBLIC,anon,service_role;
REVOKE ALL ON FUNCTION public.admin_update_menu_item_with_tax(uuid,text,text,text,text,numeric,jsonb) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.admin_create_menu_item_with_tax(uuid,uuid,text,text,text,text,numeric,jsonb,integer,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_menu_item_with_tax(uuid,text,text,text,text,numeric,jsonb) TO authenticated;

-- Wrap the deployed Excel functions without replacing their matching/archival logic.
INSERT INTO public.beverage_vat_20260929_backup
SELECT signature, pg_get_functiondef(signature::regprocedure)
FROM unnest(ARRAY['public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb)',
  'public.admin_import_menu_items(uuid,jsonb)']) signature;
ALTER FUNCTION public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb) RENAME TO admin_update_menu_workbook_before_beverage_tax;
ALTER FUNCTION public.admin_import_menu_items(uuid,jsonb) RENAME TO admin_import_menu_items_before_beverage_tax;
REVOKE ALL ON FUNCTION public.admin_update_menu_workbook_before_beverage_tax(uuid,jsonb,jsonb) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.admin_import_menu_items_before_beverage_tax(uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.admin_update_menu_workbook_i18n(p_store_id uuid,p_categories jsonb,p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public,auth,pg_catalog AS $$
DECLARE result jsonb; entry jsonb;
BEGIN
  result:=public.admin_update_menu_workbook_before_beverage_tax(p_store_id,p_categories,p_items);
  FOR entry IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    IF entry ? 'beverage_sugar_tax_class' THEN
      IF NOT EXISTS(SELECT 1 FROM public.menu_items WHERE id=(entry->>'item_id')::uuid AND restaurant_id=p_store_id) THEN
        RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
      END IF;
      PERFORM public.admin_set_menu_beverage_tax((entry->>'item_id')::uuid,entry);
    END IF;
  END LOOP;
  RETURN result;
END $$;
CREATE FUNCTION public.admin_import_menu_items(p_store_id uuid,p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public,auth,pg_catalog AS $$
DECLARE result jsonb; entry jsonb; item_id uuid;
BEGIN
  result:=public.admin_import_menu_items_before_beverage_tax(p_store_id,p_rows);
  FOR entry IN SELECT value FROM jsonb_array_elements(p_rows) LOOP
    IF entry ? 'beverage_sugar_tax_class' THEN
      SELECT m.id INTO STRICT item_id FROM public.menu_items m
      JOIN public.menu_categories c ON c.id=m.category_id
      WHERE m.restaurant_id=p_store_id AND NOT m.is_archived
        AND lower(btrim(m.name))=lower(btrim(entry->>'name'))
        AND lower(btrim(c.name))=lower(btrim(entry->>'category_name'));
      PERFORM public.admin_set_menu_beverage_tax(item_id,entry);
    END IF;
  END LOOP;
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb) FROM PUBLIC,anon,service_role;
REVOKE ALL ON FUNCTION public.admin_import_menu_items(uuid,jsonb) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_import_menu_items(uuid,jsonb) TO authenticated;

-- Tax profiles retain rate weights, independent of later menu edits. A mixed
-- parent uses -1 only as an internal marker; invoice/export lines are expanded
-- into real 8/10% slices. Never send this marker to an invoice provider.
ALTER TABLE public.order_items
  ADD COLUMN vat_profile_snapshot jsonb,
  ADD COLUMN vat_breakdown jsonb;
ALTER TABLE public.direct_order_request_items ADD COLUMN vat_profile_snapshot jsonb;
COMMENT ON COLUMN public.order_items.vat_breakdown IS
  'Final discounted supply/VAT/gross by legal rate. Mixed-rate parents have vat_rate=-1; expand these slices for tax documents.';

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
REVOKE ALL ON FUNCTION public.menu_vat_profile(uuid,uuid,jsonb,integer) FROM PUBLIC,anon,authenticated,service_role;

-- Deterministic largest-remainder allocation, ties resolved by rate. Amounts
-- retain the established two-decimal money precision of process_payment.
CREATE FUNCTION public.allocate_vat_cents(p_cents bigint,p_weights jsonb)
RETURNS TABLE(rate numeric,cents bigint) LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
  WITH weights AS (
    SELECT (entry->>'rate')::numeric rate,sum((entry->>'weight')::numeric) weight
    FROM jsonb_array_elements(p_weights) entry GROUP BY 1
  ), exact AS (
    SELECT rate,p_cents*weight/sum(weight) OVER() amount FROM weights
  ), ranked AS (
    SELECT rate,floor(amount)::bigint base,
      row_number() OVER(ORDER BY amount-floor(amount) DESC,rate) ranking,
      p_cents-sum(floor(amount)) OVER() remaining FROM exact
  ) SELECT rate,base+CASE WHEN ranking<=remaining THEN 1 ELSE 0 END FROM ranked ORDER BY rate
$$;
CREATE FUNCTION public.calculate_item_vat(p_profile jsonb,p_amount numeric,p_mode text,p_discount numeric DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path=public,pg_catalog AS $$
DECLARE part record; base numeric; gross numeric; parts jsonb:='[]'; weights jsonb:='[]';
  discount_cents bigint; total numeric:=0; supply numeric:=0; vat numeric:=0;
  result_parts jsonb:='[]'; net numeric; allocated bigint; marker numeric;
BEGIN
  IF p_profile IS NULL OR jsonb_typeof(p_profile)<>'array' OR jsonb_array_length(p_profile)=0
     OR p_amount IS NULL OR p_amount<0 OR p_amount::text IN ('NaN','Infinity','-Infinity')
     OR p_mode IS NULL OR p_mode NOT IN ('inclusive','exclusive') OR p_discount IS NULL OR p_discount<0
     OR p_discount::text IN ('NaN','Infinity','-Infinity') THEN RAISE EXCEPTION 'MENU_TAX_PROFILE_INVALID'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_profile) e WHERE
     COALESCE((e->>'rate')::numeric NOT IN (0,8,10),true) OR COALESCE((e->>'weight')::numeric,0)<=0
     OR (e->>'weight')::numeric::text IN ('NaN','Infinity','-Infinity') OR NOT e ? 'rate') THEN
    RAISE EXCEPTION 'MENU_TAX_PROFILE_INVALID';
  END IF;
  FOR part IN SELECT * FROM public.allocate_vat_cents(round(p_amount*100)::bigint,p_profile) LOOP
    base:=part.cents::numeric/100;
    gross:=CASE WHEN p_mode='inclusive' THEN base ELSE base+round(base*part.rate/100,2) END;
    parts:=parts||jsonb_build_array(jsonb_build_object('rate',part.rate,'gross',gross));
    weights:=weights||jsonb_build_array(jsonb_build_object('rate',part.rate,'weight',gross));
    total:=total+gross;
  END LOOP;
  discount_cents:=round(LEAST(p_discount,total)*100)::bigint;
  FOR part IN SELECT (e->>'rate')::numeric rate,(e->>'gross')::numeric gross FROM jsonb_array_elements(parts) e LOOP
    allocated:=0;
    IF discount_cents>0 AND part.gross>0 THEN
      SELECT cents INTO allocated FROM public.allocate_vat_cents(discount_cents,weights) a WHERE a.rate=part.rate;
    END IF;
    net:=part.gross-COALESCE(allocated,0)::numeric/100;
    base:=round(net/(1+part.rate/100),2);
    supply:=supply+base; vat:=vat+net-base;
    result_parts:=result_parts||jsonb_build_array(jsonb_build_object('vat_rate',part.rate,
      'total_amount_ex_tax',base,'vat_amount',net-base,'paying_amount_inc_tax',net));
  END LOOP;
  marker:=CASE WHEN jsonb_array_length(result_parts)=1 THEN (result_parts->0->>'vat_rate')::numeric ELSE -1 END;
  RETURN jsonb_build_object('vat_rate',marker,'supply',supply,'vat',vat,'total',supply+vat,'parts',result_parts);
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
REVOKE ALL ON FUNCTION public.snapshot_combo_tax_components(jsonb,jsonb,uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.snapshot_order_item_vat() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE direct_profile jsonb;
BEGIN
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
END $$;

-- Snapshot open legacy lines before any catalogue correction. A partial
-- payment keeps the already recorded rate; completed historical rows stay as-is.
UPDATE public.order_items oi SET vat_profile_snapshot=jsonb_build_array(jsonb_build_object(
  'rate',CASE WHEN oi.vat_rate IN (8,10) THEN oi.vat_rate ELSE mi.effective_vat_rate END,'weight',1))
FROM public.menu_items mi,public.orders o
WHERE mi.id=oi.menu_item_id AND mi.restaurant_id=oi.restaurant_id AND o.id=oi.order_id
  AND o.status NOT IN ('completed','cancelled') AND oi.item_type='menu_item';
CREATE TRIGGER zzz_order_item_vat_snapshot BEFORE INSERT OR UPDATE ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.snapshot_order_item_vat();


CREATE FUNCTION public.snapshot_direct_order_item_vat() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
  IF TG_OP='INSERT' THEN
    NEW.vat_profile_snapshot:=public.menu_vat_profile(NEW.menu_item_id,NEW.restaurant_id);
  ELSE NEW.vat_profile_snapshot:=OLD.vat_profile_snapshot;
  END IF;
  RETURN NEW;
END $$;
UPDATE public.direct_order_request_items SET vat_profile_snapshot=jsonb_build_array(jsonb_build_object(
  'rate',CASE WHEN vat_category='alcohol' THEN 10 ELSE 8 END,'weight',1));
CREATE TRIGGER direct_order_item_vat_snapshot BEFORE INSERT OR UPDATE ON public.direct_order_request_items
FOR EACH ROW EXECUTE FUNCTION public.snapshot_direct_order_item_vat();


CREATE FUNCTION pg_temp.patch_beverage_vat(signature text, old_text text, new_text text, expected integer DEFAULT 1)
RETURNS void LANGUAGE plpgsql AS $helper$
DECLARE definition text;
BEGIN
  SELECT pg_get_functiondef(signature::regprocedure) INTO definition;
  IF (length(definition)-length(replace(definition,old_text,'')))/length(old_text)<>expected THEN
    RAISE EXCEPTION 'BEVERAGE_VAT_ANCHOR_CHANGED: % / %',signature,left(old_text,90);
  END IF;
  INSERT INTO public.beverage_vat_20260929_backup VALUES(signature,definition) ON CONFLICT DO NOTHING;
  EXECUTE replace(definition,old_text,new_text);
END $helper$;

SELECT pg_temp.patch_beverage_vat('public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)', $old$DECLARE$old$, $new$DECLARE
  v_tax jsonb;$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.process_payment_before_promotion_read_split(uuid,uuid,numeric,text)', $old$DECLARE$old$, $new$DECLARE
  v_tax jsonb;$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.calculate_order_discountable_total(uuid,uuid)', $old$DECLARE$old$, $new$DECLARE
  v_tax jsonb;$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.direct_order_staff_quote(uuid,uuid,numeric,text)', $old$DECLARE$old$, $new$DECLARE
  v_tax jsonb;$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)', $old$COALESCE(mi.vat_category, 'food') AS vat_category$old$, $new$COALESCE(mi.vat_category, 'food') AS vat_category,
      COALESCE(oi.vat_profile_snapshot,jsonb_build_array(jsonb_build_object('rate',CASE WHEN oi.vat_rate IN (8,10) THEN oi.vat_rate ELSE mi.effective_vat_rate END,'weight',1))) AS tax_profile$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.calculate_order_discountable_total(uuid,uuid)', $old$COALESCE(mi.vat_category, 'food') AS vat_category$old$, $new$COALESCE(mi.vat_category, 'food') AS vat_category,
      COALESCE(oi.vat_profile_snapshot,jsonb_build_array(jsonb_build_object('rate',CASE WHEN oi.vat_rate IN (8,10) THEN oi.vat_rate ELSE mi.effective_vat_rate END,'weight',1))) AS tax_profile$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)', $old$    vat_rate numeric(5,2) NOT NULL,$old$, $new$    vat_rate numeric(5,2) NOT NULL,
    tax_profile jsonb NOT NULL,$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)', $old$      vat_category,
      vat_rate,$old$, $new$      vat_category,
      vat_rate,
      tax_profile,$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)', $old$      v_item.vat_category,
      v_vat_rate,$old$, $new$      v_item.vat_category,
      v_vat_rate,
      v_item.tax_profile,$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)', $old$    v_vat_rate := CASE v_item.vat_category WHEN 'alcohol' THEN 10 ELSE 8 END;
    IF v_vat_pricing_mode = 'inclusive' THEN
      v_total_inc := v_line_gross;
      v_pretax := ROUND(v_line_gross / (1 + (v_vat_rate / 100)), 2);
      v_vat_amt := v_line_gross - v_pretax;
    ELSE
      v_pretax := v_line_gross;
      v_vat_amt := ROUND(v_pretax * v_vat_rate / 100, 2);
      v_total_inc := v_pretax + v_vat_amt;
    END IF;$old$, $new$    v_tax := public.calculate_item_vat(v_item.tax_profile,v_line_gross,v_vat_pricing_mode);
    v_vat_rate := (v_tax->>'vat_rate')::numeric;
    v_pretax := (v_tax->>'supply')::numeric;
    v_vat_amt := (v_tax->>'vat')::numeric;
    v_total_inc := (v_tax->>'total')::numeric;$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)', $old$    IF v_item.vat_category = 'alcohol' THEN
      v_alcohol_subtotal := v_alcohol_subtotal + v_pretax;
    ELSE
      v_food_subtotal := v_food_subtotal + v_pretax;
    END IF;$old$, $new$    SELECT v_alcohol_subtotal+COALESCE(sum((p->>'total_amount_ex_tax')::numeric) FILTER(WHERE (p->>'vat_rate')::numeric=10),0),
           v_food_subtotal+COALESCE(sum((p->>'total_amount_ex_tax')::numeric) FILTER(WHERE (p->>'vat_rate')::numeric=8),0)
      INTO v_alcohol_subtotal,v_food_subtotal FROM jsonb_array_elements(v_tax->'parts') p;$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)', $old$    v_vat_rate := v_item.vat_rate;
    v_pretax := ROUND(v_total_inc / (1 + (v_vat_rate / 100)), 2);
    v_vat_amt := v_total_inc - v_pretax;$old$, $new$    v_tax := public.calculate_item_vat(v_item.tax_profile,
      round(v_item.unit_price*v_item.quantity,2),v_vat_pricing_mode,v_item.allocated_discount_cents::numeric/100);
    v_vat_rate := (v_tax->>'vat_rate')::numeric;
    v_pretax := (v_tax->>'supply')::numeric;
    v_vat_amt := (v_tax->>'vat')::numeric;
    v_total_inc := (v_tax->>'total')::numeric;$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)', $old$      paying_amount_inc_tax = v_total_inc
    WHERE id = v_item.line_id;$old$, $new$      paying_amount_inc_tax = v_total_inc,
      vat_breakdown = v_tax->'parts'
    WHERE id = v_item.line_id;$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.calculate_order_discountable_total(uuid,uuid)', $old$    v_vat_rate := CASE v_item.vat_category WHEN 'alcohol' THEN 10 ELSE 8 END;
    IF v_vat_pricing_mode = 'inclusive' THEN
      v_line_inc := v_line_gross;
    ELSE
      v_line_inc := v_line_gross + ROUND(v_line_gross * v_vat_rate / 100, 2);
    END IF;
$old$, $new$    v_tax := public.calculate_item_vat(v_item.tax_profile,v_line_gross,v_vat_pricing_mode);
    v_line_inc := (v_tax->>'total')::numeric;
$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.process_payment_before_promotion_read_split(uuid,uuid,numeric,text)', $old$COALESCE(menu.vat_category, 'food') AS vat_category,$old$, $new$COALESCE(menu.vat_category, 'food') AS vat_category,
      COALESCE(item.vat_profile_snapshot,jsonb_build_array(jsonb_build_object('rate',menu.effective_vat_rate,'weight',1))) AS tax_profile,$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.process_payment_before_promotion_read_split(uuid,uuid,numeric,text)', $old$    v_vat_rate := CASE v_line.vat_category
      WHEN 'alcohol' THEN 10 ELSE 8 END;

    IF v_vat_pricing_mode = 'inclusive' THEN
      v_line_inc := v_line_gross;
    ELSE
      v_line_inc := v_line_gross
        + ROUND(v_line_gross * v_vat_rate / 100, 2);
    END IF;

    v_line_after_discount := ROUND(
      GREATEST(v_line_inc - v_line.discount_amount, 0),
      2
    );
    v_pretax := ROUND(
      v_line_after_discount / (1 + (v_vat_rate / 100)),
      2
    );
    v_vat_amount := v_line_after_discount - v_pretax;
$old$, $new$    v_tax := public.calculate_item_vat(v_line.tax_profile,v_line_gross,v_vat_pricing_mode,v_line.discount_amount);
    v_vat_rate := (v_tax->>'vat_rate')::numeric;
    v_pretax := (v_tax->>'supply')::numeric;
    v_vat_amount := (v_tax->>'vat')::numeric;
    v_line_after_discount := (v_tax->>'total')::numeric;
$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.process_payment_before_promotion_read_split(uuid,uuid,numeric,text)', $old$        paying_amount_inc_tax = v_line_after_discount
    WHERE id = v_line.id;$old$, $new$        paying_amount_inc_tax = v_line_after_discount,
        vat_breakdown = v_tax->'parts'
    WHERE id = v_line.id;$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.direct_order_staff_quote(uuid,uuid,numeric,text)', $old$    v_vat_rate := CASE v_line.vat_category WHEN 'alcohol' THEN 10 ELSE 8 END;
    IF v_vat_pricing_mode = 'inclusive' THEN
      v_line_total := v_line_gross;
      v_line_pretax := round(v_line_total / (1 + v_vat_rate / 100), 2);
      v_line_vat := v_line_total - v_line_pretax;
    ELSE
      v_line_pretax := v_line_gross;
      v_line_vat := round(v_line_pretax * v_vat_rate / 100, 2);
      v_line_total := v_line_pretax + v_line_vat;
    END IF;
$old$, $new$    v_tax := public.calculate_item_vat(v_line.vat_profile_snapshot,v_line_gross,v_vat_pricing_mode);
    v_line_pretax := (v_tax->>'supply')::numeric;
    v_line_vat := (v_tax->>'vat')::numeric;
    v_line_total := (v_tax->>'total')::numeric;
$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.direct_order_staff_quote(uuid,uuid,numeric,text)', $old$    IF v_line.vat_category = 'alcohol' THEN
      v_alcohol_pretax := v_alcohol_pretax + v_line_pretax;
    ELSE
      v_food_pretax := v_food_pretax + v_line_pretax;
    END IF;$old$, $new$    SELECT v_alcohol_pretax+COALESCE(sum((e->>'total_amount_ex_tax')::numeric)
      FILTER (WHERE (e->>'vat_rate')::numeric=10),0),
      v_food_pretax+COALESCE(sum((e->>'total_amount_ex_tax')::numeric)
      FILTER (WHERE (e->>'vat_rate')::numeric=8),0)
    INTO v_alcohol_pretax,v_food_pretax FROM jsonb_array_elements(v_tax->'parts') e;$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.direct_order_approve_payment(uuid,uuid,numeric,text)', $old$  INSERT INTO public.order_items(
    restaurant_id, order_id, menu_item_id, item_type, label,
    display_name, unit_price, quantity, status, notes,$old$, $new$  PERFORM set_config('pos.direct_vat_request',v_request.id::text,true);
  INSERT INTO public.order_items(
    restaurant_id, order_id, menu_item_id, item_type, label,
    display_name, unit_price, quantity, status, notes,$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.direct_order_approve_payment(uuid,uuid,numeric,text)', $old$  -- This is the unchanged, authoritative payment anchor.$old$, $new$  PERFORM set_config('pos.direct_vat_request','',true);
  -- This is the unchanged, authoritative payment anchor.$new$, 1);

CREATE FUNCTION public.order_item_invoice_tax_lines(p_item public.order_items)
RETURNS TABLE(order_item_id text,display_name text,quantity numeric,unit_price numeric,
  vat_rate numeric,vat_amount numeric,total_amount_ex_tax numeric,paying_amount_inc_tax numeric)
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog AS $$
DECLARE part jsonb;
BEGIN
  IF p_item.vat_rate=-1 THEN
    IF p_item.vat_breakdown IS NULL OR jsonb_array_length(p_item.vat_breakdown)<2 THEN
      RAISE EXCEPTION 'MENU_TAX_BREAKDOWN_REQUIRED';
    END IF;
    FOR part IN SELECT value FROM jsonb_array_elements(p_item.vat_breakdown) LOOP
      RETURN QUERY SELECT p_item.id::text||':'||(part->>'vat_rate'),
        COALESCE(NULLIF(p_item.display_name,''),p_item.label,'Item')||' (VAT '||(part->>'vat_rate')||'%)',
        1::numeric,(part->>'total_amount_ex_tax')::numeric,(part->>'vat_rate')::numeric,
        (part->>'vat_amount')::numeric,(part->>'total_amount_ex_tax')::numeric,
        (part->>'paying_amount_inc_tax')::numeric;
    END LOOP;
  ELSE
    RETURN QUERY SELECT p_item.id::text,
      CASE p_item.display_name WHEN 'Service Charge (Food)' THEN 'Service Charge (VAT 8%)'
        WHEN 'Service Charge (Alcohol)' THEN 'Service Charge (VAT 10%)'
        ELSE COALESCE(NULLIF(p_item.display_name,''),p_item.label,'Item') END,
      p_item.quantity::numeric,p_item.unit_price::numeric,p_item.vat_rate::numeric,
      p_item.vat_amount::numeric,p_item.total_amount_ex_tax::numeric,p_item.paying_amount_inc_tax::numeric;
  END IF;
END $$;

SELECT pg_temp.patch_beverage_vat('public.enqueue_meinvoice_cash_register_job()', $old$  FROM public.order_items oi
  WHERE oi.order_id = NEW.id$old$, $new$  FROM public.order_items oi
  CROSS JOIN LATERAL public.order_item_invoice_tax_lines(oi) tax_line
  WHERE oi.order_id = NEW.id$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.enqueue_meinvoice_cash_register_job()', $old$'quantity', oi.quantity$old$, $new$'quantity', tax_line.quantity$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.enqueue_meinvoice_cash_register_job()', $old$'unit_price', oi.unit_price$old$, $new$'unit_price', tax_line.unit_price$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.enqueue_meinvoice_cash_register_job()', $old$'vat_rate', oi.vat_rate$old$, $new$'vat_rate', tax_line.vat_rate$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.enqueue_meinvoice_cash_register_job()', $old$'vat_amount', oi.vat_amount$old$, $new$'vat_amount', tax_line.vat_amount$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.enqueue_meinvoice_cash_register_job()', $old$'total_amount_ex_tax', oi.total_amount_ex_tax$old$, $new$'total_amount_ex_tax', tax_line.total_amount_ex_tax$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.enqueue_meinvoice_cash_register_job()', $old$'paying_amount_inc_tax', oi.paying_amount_inc_tax$old$, $new$'paying_amount_inc_tax', tax_line.paying_amount_inc_tax$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.enqueue_meinvoice_cash_register_job()', $old$'order_item_id', oi.id$old$, $new$'order_item_id', tax_line.order_item_id$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.enqueue_meinvoice_cash_register_job()', $old$COALESCE(NULLIF(oi.display_name, ''), oi.label, 'Item')$old$, $new$tax_line.display_name$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.get_restaurant_daily_sales_exports_by_tax_entity(date)', $old$      FROM public.order_items item
      WHERE item.order_id = paid.order_id$old$, $new$      FROM public.order_items item
  CROSS JOIN LATERAL public.order_item_invoice_tax_lines(item) tax_line
      WHERE item.order_id = paid.order_id$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.get_restaurant_daily_sales_exports_by_tax_entity(date)', $old$'quantity', item.quantity$old$, $new$'quantity', tax_line.quantity$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.get_restaurant_daily_sales_exports_by_tax_entity(date)', $old$'unit_price', item.unit_price$old$, $new$'unit_price', tax_line.unit_price$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.get_restaurant_daily_sales_exports_by_tax_entity(date)', $old$'vat_rate', item.vat_rate$old$, $new$'vat_rate', tax_line.vat_rate$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.get_restaurant_daily_sales_exports_by_tax_entity(date)', $old$'vat_amount', item.vat_amount$old$, $new$'vat_amount', tax_line.vat_amount$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.get_restaurant_daily_sales_exports_by_tax_entity(date)', $old$'total_amount_ex_tax', item.total_amount_ex_tax$old$, $new$'total_amount_ex_tax', tax_line.total_amount_ex_tax$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.get_restaurant_daily_sales_exports_by_tax_entity(date)', $old$COALESCE(
          NULLIF(item.display_name, ''), NULLIF(item.label, ''), 'Món ăn'
        )$old$, $new$tax_line.display_name$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.upsert_red_invoice_intake(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text)', $old$    FROM public.order_items item
    WHERE item.order_id = p_order_id$old$, $new$    FROM public.order_items item
  CROSS JOIN LATERAL public.order_item_invoice_tax_lines(item) tax_line
    WHERE item.order_id = p_order_id$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.upsert_red_invoice_intake(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text)', $old$'quantity', item.quantity$old$, $new$'quantity', tax_line.quantity$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.upsert_red_invoice_intake(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text)', $old$'unit_price', item.unit_price$old$, $new$'unit_price', tax_line.unit_price$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.upsert_red_invoice_intake(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text)', $old$'vat_rate', item.vat_rate$old$, $new$'vat_rate', tax_line.vat_rate$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.upsert_red_invoice_intake(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text)', $old$'vat_amount', item.vat_amount$old$, $new$'vat_amount', tax_line.vat_amount$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.upsert_red_invoice_intake(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text)', $old$'total_amount_ex_tax', item.total_amount_ex_tax$old$, $new$'total_amount_ex_tax', tax_line.total_amount_ex_tax$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.upsert_red_invoice_intake(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text)', $old$'paying_amount_inc_tax', item.paying_amount_inc_tax$old$, $new$'paying_amount_inc_tax', tax_line.paying_amount_inc_tax$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.upsert_red_invoice_intake(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text)', $old$'order_item_id', item.id$old$, $new$'order_item_id', tax_line.order_item_id$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.upsert_red_invoice_intake(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text)', $old$COALESCE(NULLIF(item.display_name, ''), item.label, 'Item')$old$, $new$tax_line.display_name$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)', $old$AND display_name = 'Service Charge (Food)'$old$, $new$AND display_name IN ('Service Charge (Food)','Service Charge (VAT 8%)')$new$, 2);
SELECT pg_temp.patch_beverage_vat('public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)', $old$p_store_id, 'service_charge', 'Service Charge (Food)', NULL,
        v_sc_pretax, 1, 'Service Charge (Food)'$old$, $new$p_store_id, 'service_charge', 'Service Charge (VAT 8%)', NULL,
        v_sc_pretax, 1, 'Service Charge (VAT 8%)'$new$, 1);
SELECT pg_temp.patch_beverage_vat('public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)', $old$AND display_name = 'Service Charge (Alcohol)'$old$, $new$AND display_name IN ('Service Charge (Alcohol)','Service Charge (VAT 10%)')$new$, 2);
SELECT pg_temp.patch_beverage_vat('public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)', $old$p_store_id, 'service_charge', 'Service Charge (Alcohol)', NULL,
        v_sc_pretax, 1, 'Service Charge (Alcohol)'$old$, $new$p_store_id, 'service_charge', 'Service Charge (VAT 10%)', NULL,
        v_sc_pretax, 1, 'Service Charge (VAT 10%)'$new$, 1);


-- Promotion eligibility and allocation must use the same frozen VAT profile.
SELECT pg_temp.patch_beverage_vat('public.sync_active_order_promotion(uuid,uuid,timestamptz)', $old$CASE
      WHEN v_vat_pricing_mode = 'inclusive'
        THEN ROUND(item.unit_price * item.quantity, 2)
      ELSE
        ROUND(item.unit_price * item.quantity, 2)
        + ROUND(
            ROUND(item.unit_price * item.quantity, 2)
            * CASE COALESCE(menu.vat_category, 'food')
                WHEN 'alcohol' THEN 10 ELSE 8 END / 100,
            2
          )
    END$old$, $new$(public.calculate_item_vat(COALESCE(item.vat_profile_snapshot,
        jsonb_build_array(jsonb_build_object('rate',CASE WHEN item.vat_rate IN (8,10) THEN item.vat_rate ELSE menu.effective_vat_rate END,'weight',1))),
        round(item.unit_price*item.quantity,2),v_vat_pricing_mode)->>'total')::numeric$new$, 1);

SELECT pg_temp.patch_beverage_vat('public.sync_active_order_promotion(uuid,uuid,timestamptz)', $old$CASE
        WHEN v_vat_pricing_mode = 'inclusive'
          THEN ROUND(item.unit_price * item.quantity, 2)
        ELSE
          ROUND(item.unit_price * item.quantity, 2)
          + ROUND(
              ROUND(item.unit_price * item.quantity, 2)
              * CASE COALESCE(menu.vat_category, 'food')
                  WHEN 'alcohol' THEN 10 ELSE 8 END / 100,
              2
            )
      END$old$, $new$(public.calculate_item_vat(COALESCE(item.vat_profile_snapshot,
        jsonb_build_array(jsonb_build_object('rate',CASE WHEN item.vat_rate IN (8,10) THEN item.vat_rate ELSE menu.effective_vat_rate END,'weight',1))),
        round(item.unit_price*item.quantity,2),v_vat_pricing_mode)->>'total')::numeric$new$, 1);

REVOKE ALL ON FUNCTION public.snapshot_order_item_vat() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.snapshot_direct_order_item_vat() FROM PUBLIC,anon,authenticated,service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
