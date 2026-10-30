-- Existing promotions/categories are retained. NULL/no row means unlimited;
-- zero means normal-price sales. Reservations belong to order lines, not payments.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TABLE public.menu_discount_quantities (
  menu_item_id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL,
  remaining integer CHECK (remaining >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (menu_item_id, restaurant_id)
    REFERENCES public.menu_items(id, restaurant_id)
);
CREATE INDEX menu_discount_quantities_store_idx
  ON public.menu_discount_quantities(restaurant_id);
ALTER TABLE public.menu_discount_quantities ENABLE ROW LEVEL SECURITY;
CREATE POLICY menu_discount_quantities_read ON public.menu_discount_quantities
FOR SELECT TO authenticated USING (
  public.is_super_admin() OR restaurant_id IN (
    SELECT public.user_accessible_stores((SELECT auth.uid()))
  )
);
REVOKE ALL ON public.menu_discount_quantities FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.menu_discount_quantities TO authenticated;
GRANT ALL ON public.menu_discount_quantities TO service_role;

ALTER TABLE public.order_items ADD COLUMN promotion_quantity_snapshot jsonb;

CREATE FUNCTION public.admin_set_menu_discount_quantity(
  p_store_id uuid, p_item_id uuid, p_remaining integer,
  p_expected_remaining integer
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, pg_catalog AS $$
DECLARE v_remaining integer;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);
  IF p_remaining < 0 THEN RAISE EXCEPTION 'MENU_DISCOUNT_QUANTITY_INVALID'; END IF;
  PERFORM id FROM public.menu_items WHERE id=p_item_id AND restaurant_id=p_store_id
    AND catalog_parent_id IS NULL AND NOT is_archived FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND'; END IF;
  INSERT INTO public.menu_discount_quantities(menu_item_id,restaurant_id)
    VALUES(p_item_id,p_store_id) ON CONFLICT DO NOTHING;
  SELECT remaining INTO v_remaining FROM public.menu_discount_quantities
    WHERE menu_item_id=p_item_id AND restaurant_id=p_store_id FOR UPDATE;
  IF v_remaining IS DISTINCT FROM p_expected_remaining THEN
    RAISE EXCEPTION 'MENU_DISCOUNT_QUANTITY_CHANGED';
  END IF;
  UPDATE public.menu_discount_quantities SET remaining=p_remaining,updated_at=now()
    WHERE menu_item_id=p_item_id AND restaurant_id=p_store_id;
  INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
    VALUES(auth.uid(),'admin_set_menu_discount_quantity','menu_items',p_item_id,
      jsonb_build_object('store_id',p_store_id,'previous',v_remaining,'remaining',p_remaining));
END $$;
REVOKE ALL ON FUNCTION public.admin_set_menu_discount_quantity(uuid,uuid,integer,integer)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_set_menu_discount_quantity(uuid,uuid,integer,integer)
  TO authenticated;

-- Row locks make reservation/release transactional with the order write. All
-- channels insert canonical order lines; payment and VAT-only writes do nothing.
CREATE FUNCTION public.reserve_menu_discount_quantity() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE
  v_snapshot jsonb;
  v_menu_id uuid;
  v_promotion public.store_promotions%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_remaining integer;
  v_previous integer := 0;
  v_requested integer := 0;
  v_allocated integer := 0;
  v_release integer := 0;
  v_source_id uuid;
  v_source public.order_items%ROWTYPE;
  v_transfer_setting text;
BEGIN
  IF TG_OP='UPDATE' AND pg_trigger_depth()>1
    AND current_setting('pos.discount_quantity_transfer',true)='on' THEN RETURN NEW; END IF;
  -- The existing cashier split copies the complete row before reducing its
  -- source. Transfer the reservation with that split rather than reserving twice.
  IF TG_OP='INSERT' AND NEW.promotion_quantity_snapshot IS NOT NULL
    AND current_setting('globos.cashier_item_mutation',true)='on'
    AND to_regclass('pg_temp.workflow_move_map') IS NOT NULL THEN
    EXECUTE 'SELECT source_item_id FROM pg_temp.workflow_move_map
      WHERE target_item_id=$1 AND move_count=$2 AND move_count<original_count'
      INTO v_source_id USING NEW.id,NEW.quantity;
    IF v_source_id IS NOT NULL THEN
      SELECT * INTO v_source FROM public.order_items WHERE id=v_source_id
        AND restaurant_id=NEW.restaurant_id AND menu_item_id=NEW.menu_item_id FOR UPDATE;
      IF v_source.promotion_quantity_snapshot IS DISTINCT FROM NEW.promotion_quantity_snapshot
        OR v_source.status='cancelled' THEN RAISE EXCEPTION 'CASHIER_ITEM_CHANGED'; END IF;
      v_allocated:=least((v_source.promotion_quantity_snapshot->>'quantity')::integer,NEW.quantity);
      v_transfer_setting:=current_setting('pos.discount_quantity_transfer',true);
      PERFORM set_config('pos.discount_quantity_transfer','on',true);
      UPDATE public.order_items SET promotion_quantity_snapshot=jsonb_set(promotion_quantity_snapshot,'{quantity}',
        to_jsonb((promotion_quantity_snapshot->>'quantity')::integer-v_allocated)) WHERE id=v_source_id;
      PERFORM set_config('pos.discount_quantity_transfer',coalesce(v_transfer_setting,''),true);
      NEW.promotion_quantity_snapshot:=jsonb_set(NEW.promotion_quantity_snapshot,'{quantity}',to_jsonb(v_allocated));
      RETURN NEW;
    END IF;
  END IF;
  IF TG_OP='UPDATE' THEN
    -- Snapshots cannot be edited through an ordinary order UPDATE.
    NEW.promotion_quantity_snapshot := OLD.promotion_quantity_snapshot;
    IF ROW(NEW.quantity,NEW.status,NEW.menu_item_id,NEW.is_service_item)
      IS NOT DISTINCT FROM ROW(OLD.quantity,OLD.status,OLD.menu_item_id,OLD.is_service_item)
    THEN RETURN NEW; END IF;
    v_snapshot := OLD.promotion_quantity_snapshot;
  ELSIF TG_OP='DELETE' THEN
    v_snapshot := OLD.promotion_quantity_snapshot;
  ELSE
    NEW.promotion_quantity_snapshot := NULL;
  END IF;

  IF v_snapshot IS NOT NULL THEN
    v_menu_id := (v_snapshot->>'menu_id')::uuid;
    v_previous := (v_snapshot->>'quantity')::integer;
    IF TG_OP='DELETE' THEN v_release:=v_previous;
    ELSIF NEW.status='cancelled' OR coalesce(NEW.is_service_item,false)
      OR NEW.menu_item_id IS DISTINCT FROM OLD.menu_item_id THEN v_release:=v_previous;
    ELSE v_release:=greatest(v_previous-NEW.quantity,0); END IF;
    IF v_release>0 THEN
      UPDATE public.menu_discount_quantities SET remaining=remaining+v_release,updated_at=now()
        WHERE menu_item_id=v_menu_id AND restaurant_id=OLD.restaurant_id AND remaining IS NOT NULL;
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    v_previous:=v_previous-v_release;
    v_snapshot:=jsonb_set(v_snapshot,'{quantity}',to_jsonb(v_previous));
    NEW.promotion_quantity_snapshot:=v_snapshot;
    IF NEW.status='cancelled' OR coalesce(NEW.is_service_item,false) THEN RETURN NEW; END IF;
    IF NEW.menu_item_id IS NOT DISTINCT FROM OLD.menu_item_id THEN
      v_requested:=greatest(NEW.quantity-CASE WHEN OLD.status='cancelled' OR coalesce(OLD.is_service_item,false)
        THEN 0 ELSE OLD.quantity END,0);
      IF v_requested=0 THEN RETURN NEW; END IF;
    ELSE
      v_snapshot:=NULL;
      NEW.promotion_quantity_snapshot:=NULL;
    END IF;
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  IF NEW.item_type<>'menu_item' OR NEW.status='cancelled' OR coalesce(NEW.is_service_item,false)
    THEN RETURN NEW; END IF;
  IF TG_OP='UPDATE' AND v_snapshot IS NULL AND NEW.menu_item_id IS NOT DISTINCT FROM OLD.menu_item_id
    AND OLD.status<>'cancelled' AND NOT coalesce(OLD.is_service_item,false)
    THEN RETURN NEW; END IF; -- Enabling a limit never reallocates earlier orders.

  SELECT * INTO v_order FROM public.orders WHERE id=NEW.order_id AND restaurant_id=NEW.restaurant_id;
  IF v_order.status IN ('completed','cancelled') OR coalesce(v_order.order_purpose,'customer')<>'customer'
    THEN RETURN NEW; END IF;
  SELECT coalesce(catalog_parent_id,size_parent_id,id) INTO v_menu_id FROM public.menu_items
    WHERE id=NEW.menu_item_id AND restaurant_id=NEW.restaurant_id;
  SELECT remaining INTO v_remaining FROM public.menu_discount_quantities
    WHERE menu_item_id=v_menu_id AND restaurant_id=NEW.restaurant_id FOR UPDATE;
  IF NOT FOUND OR v_remaining IS NULL THEN RETURN NEW; END IF;

  SELECT p.* INTO v_promotion FROM public.store_promotions p
    WHERE p.restaurant_id=NEW.restaurant_id AND p.is_active
      AND p.starts_at<=now() AND p.ends_at>now()
      AND p.channel IN ('both',CASE WHEN v_order.order_source='qr' THEN 'qr' ELSE 'pos' END)
      AND (p.scope='all_menu' OR EXISTS(SELECT 1 FROM public.store_promotion_menu_items t
        WHERE t.promotion_id=p.id AND t.restaurant_id=NEW.restaurant_id
          AND t.menu_item_id IN (NEW.menu_item_id,v_menu_id)))
    ORDER BY p.starts_at DESC LIMIT 1;
  IF v_snapshot IS NULL THEN
    v_requested:=NEW.quantity;
    v_snapshot:=jsonb_build_object('menu_id',v_menu_id,'promotion_id',v_promotion.id,
      'percent',coalesce(v_promotion.discount_percent,0),'quantity',0);
  END IF;
  -- Increases retain the original campaign/rate; a later campaign cannot
  -- rewrite an already confirmed line.
  IF v_promotion.id IS NOT NULL AND v_promotion.id::text=v_snapshot->>'promotion_id'
    AND v_promotion.discount_percent=(v_snapshot->>'percent')::numeric THEN
    v_allocated:=least(v_remaining,v_requested);
  END IF;
  IF v_allocated>0 THEN
    UPDATE public.menu_discount_quantities SET remaining=remaining-v_allocated,updated_at=now()
      WHERE menu_item_id=v_menu_id AND restaurant_id=NEW.restaurant_id;
  END IF;
  NEW.promotion_quantity_snapshot:=jsonb_set(v_snapshot,'{quantity}',to_jsonb(v_previous+v_allocated));
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.reserve_menu_discount_quantity() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER reserve_menu_discount_quantity
BEFORE INSERT OR DELETE OR UPDATE ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.reserve_menu_discount_quantity();

CREATE TRIGGER pos_live_event_trigger AFTER INSERT OR UPDATE OR DELETE
ON public.menu_discount_quantities FOR EACH ROW EXECUTE FUNCTION public.emit_pos_live_event('menu');

ALTER FUNCTION public.sync_active_order_promotion(uuid,uuid,timestamptz)
  RENAME TO sync_active_order_promotion_unlimited;
REVOKE ALL ON FUNCTION public.sync_active_order_promotion_unlimited(uuid,uuid,timestamptz)
  FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.sync_active_order_promotion(
  p_order_id uuid,
  p_store_id uuid,
  p_at timestamptz DEFAULT now()
) RETURNS public.order_discounts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_promo public.store_promotions%ROWTYPE;
  v_existing public.order_discounts%ROWTYPE;
  v_vat_pricing_mode text := 'exclusive';
  v_total numeric(15,2) := 0;
  v_amount numeric(15,2) := 0;
  v_result public.order_discounts%ROWTYPE;
  v_desired_lines jsonb;
  v_existing_lines jsonb;
  v_active_promo public.store_promotions%ROWTYPE;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.order_items WHERE order_id=p_order_id
    AND restaurant_id=p_store_id AND promotion_quantity_snapshot IS NOT NULL) THEN
    RETURN public.sync_active_order_promotion_unlimited(p_order_id,p_store_id,p_at);
  END IF;
  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id AND restaurant_id = p_store_id;

  IF NOT FOUND OR v_order.status IN ('completed', 'cancelled')
     OR COALESCE(v_order.order_purpose, 'customer') <> 'customer' THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_existing
  FROM public.order_discounts
  WHERE order_id = p_order_id
    AND restaurant_id = p_store_id
    AND status = 'active'
  FOR UPDATE;

  -- Manager-approved manual/coupon discounts are never silently destroyed.
  -- The cashier now exposes their source and provides an explicit void action.
  IF FOUND AND v_existing.approved_via <> 'scheduled_promotion' THEN
    RETURN v_existing;
  END IF;

  SELECT * INTO v_promo
  FROM public.store_promotions promotion
  WHERE promotion.restaurant_id = p_store_id
    AND promotion.is_active = true
    AND promotion.starts_at <= p_at
    AND promotion.ends_at > p_at
    AND (
      promotion.channel = 'both'
      OR promotion.channel = CASE
        WHEN v_order.order_source = 'qr' THEN 'qr'
        ELSE 'pos'
      END
    )
  ORDER BY promotion.starts_at DESC
  LIMIT 1;

  v_active_promo:=v_promo;
  IF v_promo.id IS NULL THEN
    SELECT p.* INTO v_promo FROM public.store_promotions p
    JOIN public.order_items i ON (i.promotion_quantity_snapshot->>'promotion_id')::uuid=p.id
    WHERE i.order_id=p_order_id AND i.restaurant_id=p_store_id AND i.status<>'cancelled'
      AND (i.promotion_quantity_snapshot->>'quantity')::integer>0
    ORDER BY i.created_at,i.id LIMIT 1;
  END IF;

  SELECT COALESCE(restaurant.vat_pricing_mode, 'exclusive')
  INTO v_vat_pricing_mode
  FROM public.restaurants restaurant
  WHERE restaurant.id = p_store_id;

  WITH eligible AS MATERIALIZED (
    SELECT item.id AS order_item_id,item.menu_item_id,
      CASE WHEN item.promotion_quantity_snapshot IS NOT NULL
        THEN (item.promotion_quantity_snapshot->>'promotion_id')::uuid ELSE v_active_promo.id END promotion_id,
      CASE WHEN item.promotion_quantity_snapshot IS NOT NULL
        THEN (item.promotion_quantity_snapshot->>'percent')::numeric ELSE v_active_promo.discount_percent END percent,
      public.direct_order_payment_vat(
        coalesce(item.vat_profile_snapshot,jsonb_build_array(jsonb_build_object(
          'rate',coalesce(menu.effective_vat_rate,8),'weight',1))),
        round(item.unit_price*CASE WHEN item.promotion_quantity_snapshot IS NOT NULL
          THEN (item.promotion_quantity_snapshot->>'quantity')::integer ELSE item.quantity END,2),
        v_vat_pricing_mode)->>'total' AS amount_text
    FROM public.order_items item
    LEFT JOIN public.menu_items menu ON menu.id=item.menu_item_id
    WHERE item.order_id=p_order_id AND item.restaurant_id=p_store_id
      AND item.status<>'cancelled' AND item.item_type='menu_item' AND NOT coalesce(item.is_service_item,false)
      AND CASE WHEN item.promotion_quantity_snapshot IS NOT NULL
        THEN (item.promotion_quantity_snapshot->>'quantity')::integer>0
        ELSE v_active_promo.id IS NOT NULL AND (v_active_promo.scope='all_menu' OR EXISTS (
          SELECT 1 FROM public.store_promotion_menu_items t
          WHERE t.promotion_id=v_active_promo.id AND t.restaurant_id=p_store_id AND t.menu_item_id=item.menu_item_id)) END
  ), amounts AS (
    SELECT *,amount_text::numeric line_amount,amount_text::numeric*percent/100 raw_discount FROM eligible
  ), ranked AS (
    SELECT *,floor(raw_discount) base_amount,
      row_number() OVER(ORDER BY raw_discount-floor(raw_discount) DESC,order_item_id) allocation_rank,
      round(sum(raw_discount) OVER(),0)-sum(floor(raw_discount)) OVER() remainder
    FROM amounts
  )
  SELECT coalesce(sum(base_amount+CASE WHEN allocation_rank<=remainder THEN 1 ELSE 0 END),0),
    coalesce(jsonb_agg(jsonb_build_object(
      'order_item_id',order_item_id,'menu_item_id',menu_item_id,'restaurant_id',p_store_id,
      'promotion_id',promotion_id,'line_amount_before_discount',line_amount,
      'discount_percent',percent,'discount_amount',base_amount+CASE WHEN allocation_rank<=remainder THEN 1 ELSE 0 END
    ) ORDER BY order_item_id),'[]'::jsonb)
  INTO v_amount,v_desired_lines FROM ranked;

  IF v_amount<=0 THEN
    IF v_existing.id IS NOT NULL THEN
      UPDATE public.order_discounts SET status='voided',void_reason='promotion_total_empty',updated_at=now()
        WHERE id=v_existing.id;
    END IF;
    RETURN NULL;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'order_item_id', allocation.order_item_id,
    'menu_item_id', allocation.menu_item_id,
    'restaurant_id', allocation.restaurant_id,
    'promotion_id', allocation.promotion_id,
    'line_amount_before_discount', allocation.line_amount_before_discount,
    'discount_percent', allocation.discount_percent,
    'discount_amount', allocation.discount_amount
  ) ORDER BY allocation.order_item_id), '[]'::jsonb)
  INTO v_existing_lines
  FROM public.order_discount_lines allocation
  WHERE allocation.order_discount_id = v_existing.id;

  -- Compare the complete persisted contract, not just the order total. Equal
  -- totals can hide a different eligible menu, quantity, or rounding allocation.
  -- The existing active-discount row lock serializes concurrent refreshes.
  IF v_existing.id IS NOT NULL
     AND ROW(v_existing.discount_type, v_existing.discount_mode,
       v_existing.discount_value, v_existing.discount_amount,
       v_existing.reason, v_existing.coupon_code,
       v_existing.proof_storage_path, v_existing.applied_by,
       v_existing.approved_via)
       IS NOT DISTINCT FROM ROW('promotion'::text, 'percent'::text,
         v_promo.discount_percent, v_amount, v_promo.name,
         v_promo.id::text, 'system/promotion/' || v_promo.id::text,
         v_promo.created_by, 'scheduled_promotion'::text)
     AND v_existing_lines IS NOT DISTINCT FROM v_desired_lines THEN
    RETURN v_existing;
  END IF;

  IF v_existing.id IS NOT NULL THEN
    UPDATE public.order_discounts
    SET discount_type = 'promotion',
        discount_mode = 'percent',
        discount_value = v_promo.discount_percent,
        discount_amount = v_amount,
        reason = v_promo.name,
        coupon_code = v_promo.id::text,
        proof_storage_path = 'system/promotion/' || v_promo.id::text,
        applied_by = v_promo.created_by,
        approved_via = 'scheduled_promotion',
        updated_at = now()
    -- Line-only changes must also publish the existing parent-row event.
    WHERE id = v_existing.id
      AND (ROW(discount_type, discount_mode, discount_value, discount_amount,
        reason, coupon_code, proof_storage_path, applied_by, approved_via)
        IS DISTINCT FROM ROW('promotion'::text, 'percent'::text,
          v_promo.discount_percent, v_amount, v_promo.name,
          v_promo.id::text, 'system/promotion/' || v_promo.id::text,
          v_promo.created_by, 'scheduled_promotion'::text)
          OR v_existing_lines IS DISTINCT FROM v_desired_lines
        )
    RETURNING * INTO v_result;
    IF NOT FOUND THEN
      v_result := v_existing;
    END IF;
  ELSE
    INSERT INTO public.order_discounts (
      restaurant_id,
      order_id,
      discount_type,
      discount_mode,
      discount_value,
      discount_amount,
      reason,
      coupon_code,
      proof_storage_path,
      applied_by,
      approved_via,
      status
    ) VALUES (
      p_store_id,
      p_order_id,
      'promotion',
      'percent',
      v_promo.discount_percent,
      v_amount,
      v_promo.name,
      v_promo.id::text,
      'system/promotion/' || v_promo.id::text,
      v_promo.created_by,
      'scheduled_promotion',
      'active'
    ) RETURNING * INTO v_result;
  END IF;

  -- Header-only edits preserve line IDs and creation timestamps.
  IF v_existing_lines IS DISTINCT FROM v_desired_lines THEN
    DELETE FROM public.order_discount_lines allocation
    WHERE allocation.order_discount_id = v_result.id;

    INSERT INTO public.order_discount_lines (
      order_discount_id, restaurant_id, order_item_id, menu_item_id,
      promotion_id, line_amount_before_discount, discount_percent, discount_amount
    )
    SELECT v_result.id, line.restaurant_id, line.order_item_id, line.menu_item_id,
      line.promotion_id, line.line_amount_before_discount,
      line.discount_percent, line.discount_amount
    FROM jsonb_to_recordset(v_desired_lines) AS line(
      restaurant_id uuid, order_item_id uuid, menu_item_id uuid,
      promotion_id uuid, line_amount_before_discount numeric,
      discount_percent numeric, discount_amount numeric
    );
  END IF;

  IF (
    SELECT ROUND(COALESCE(sum(allocation.discount_amount), 0), 2)
    FROM public.order_discount_lines allocation
    WHERE allocation.order_discount_id = v_result.id
  ) IS DISTINCT FROM v_amount THEN
    RAISE EXCEPTION 'PROMOTION_ALLOCATION_MISMATCH';
  END IF;

  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.sync_active_order_promotion(uuid,uuid,timestamptz)
  FROM PUBLIC,anon,authenticated,service_role;
-- This is an internal mutation helper. Public callers use the existing
-- authenticated payment/admin RPCs or the token-authorized QR order RPC.

-- Moving a line between orders must refresh both allocation headers.
CREATE OR REPLACE FUNCTION public.trg_sync_order_promotion()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
  PERFORM public.sync_active_order_promotion(coalesce(NEW.order_id,OLD.order_id),
    coalesce(NEW.restaurant_id,OLD.restaurant_id),now());
  IF TG_OP='UPDATE' AND OLD.order_id IS DISTINCT FROM NEW.order_id THEN
    PERFORM public.sync_active_order_promotion(OLD.order_id,OLD.restaurant_id,now());
  END IF;
  RETURN coalesce(NEW,OLD);
END $$;
DROP TRIGGER trg_sync_order_promotion ON public.order_items;
CREATE TRIGGER trg_sync_order_promotion AFTER INSERT OR DELETE OR UPDATE OF
  unit_price,quantity,status,menu_item_id,is_service_item,order_id,promotion_quantity_snapshot
ON public.order_items FOR EACH ROW EXECUTE FUNCTION public.trg_sync_order_promotion();

-- One bounded catalog join, preserving the existing token checks, option keys,
-- category order, translations and combo data.
ALTER FUNCTION public.qr_get_menu(text) RENAME TO qr_get_menu_before_discount_quantity;
REVOKE ALL ON FUNCTION public.qr_get_menu_before_discount_quantity(text) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.qr_get_menu(p_token text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE payload jsonb;
BEGIN
  payload:=public.qr_get_menu_before_discount_quantity(p_token);
  payload:=payload||jsonb_build_object('items',(
    WITH active AS MATERIALIZED (
      SELECT p.* FROM public.store_promotions p
      WHERE p.restaurant_id=(payload->>'store_id')::uuid AND p.is_active
        AND p.starts_at<=now() AND p.ends_at>now() AND p.channel IN ('qr','both')
      ORDER BY p.starts_at DESC LIMIT 1
    ), items AS (
      SELECT i.raw,i.ord,q.remaining,q.menu_item_id,
        CASE WHEN q.remaining>0 AND (p.scope='all_menu' OR EXISTS (
          SELECT 1 FROM public.store_promotion_menu_items t WHERE t.promotion_id=p.id
            AND t.restaurant_id=m.restaurant_id AND t.menu_item_id IN(m.id,q.menu_item_id)))
          THEN coalesce(p.discount_percent,0) ELSE 0 END percent
      FROM jsonb_array_elements(payload->'items') WITH ORDINALITY i(raw,ord)
      JOIN public.menu_items m ON m.id=(i.raw->>'id')::uuid AND m.restaurant_id=(payload->>'store_id')::uuid
      LEFT JOIN public.menu_discount_quantities q ON q.menu_item_id=coalesce(m.catalog_parent_id,m.size_parent_id,m.id)
        AND q.restaurant_id=m.restaurant_id
      LEFT JOIN active p ON true
    ) SELECT coalesce(jsonb_agg(raw||CASE WHEN remaining IS NULL THEN '{}'::jsonb
      ELSE jsonb_build_object('discount_remaining',remaining,'discount_quantity_menu_id',menu_item_id,
        'discount_percent',percent,'price',round(coalesce(raw->>'original_price',raw->>'price')::numeric*(100-percent)/100,0))
      END ORDER BY ord),'[]'::jsonb) FROM items
  ));
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(payload->'items') item
    WHERE (item->>'discount_percent')::numeric>0) THEN
    payload:=payload||jsonb_build_object('promotion_discount_percent',0);
  END IF;
  RETURN payload;
END $$;
REVOKE ALL ON FUNCTION public.qr_get_menu(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qr_get_menu(text) TO anon,authenticated,service_role;

-- Every ordering path already validates its complete option batch. Acquire the
-- quantity locks in a consistent order once per batch, before line insertion.
ALTER FUNCTION public.validate_menu_option_batch(uuid,jsonb,text) RENAME TO validate_menu_option_batch_before_discount_quantity;
REVOKE ALL ON FUNCTION public.validate_menu_option_batch_before_discount_quantity(uuid,jsonb,text)
  FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.validate_menu_option_batch(p_store_id uuid,p_items jsonb,p_channel text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
  PERFORM public.validate_menu_option_batch_before_discount_quantity(p_store_id,p_items,p_channel);
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN RETURN; END IF;
  PERFORM q.menu_item_id FROM public.menu_discount_quantities q
    JOIN (SELECT DISTINCT coalesce(m.catalog_parent_id,m.size_parent_id,m.id) id
      FROM jsonb_array_elements(p_items)x JOIN public.menu_items m ON m.id=(x->>'menu_item_id')::uuid
      WHERE m.restaurant_id=p_store_id) requested ON requested.id=q.menu_item_id
    WHERE q.restaurant_id=p_store_id ORDER BY q.menu_item_id FOR UPDATE OF q;
  IF p_channel<>'qr' THEN RETURN; END IF;
  IF EXISTS (
    WITH active AS MATERIALIZED (
      SELECT p.* FROM public.store_promotions p WHERE p.restaurant_id=p_store_id AND p.is_active
        AND p.starts_at<=now() AND p.ends_at>now() AND p.channel IN ('qr','both')
        ORDER BY p.starts_at DESC LIMIT 1
    ), requested AS (
      SELECT x.raw,x.ord,m.id,q.menu_item_id,q.remaining,
        CASE WHEN p.scope='all_menu' OR EXISTS(SELECT 1 FROM public.store_promotion_menu_items t
          WHERE t.promotion_id=p.id AND t.restaurant_id=p_store_id AND t.menu_item_id IN(m.id,q.menu_item_id))
          THEN coalesce(p.discount_percent,0) ELSE 0 END percent,
        (x.raw->>'quantity')::integer quantity
      FROM jsonb_array_elements(p_items) WITH ORDINALITY x(raw,ord)
      JOIN public.menu_items m ON m.id=(x.raw->>'menu_item_id')::uuid AND m.restaurant_id=p_store_id
      JOIN public.menu_discount_quantities q ON q.menu_item_id=coalesce(m.catalog_parent_id,m.size_parent_id,m.id)
        AND q.restaurant_id=p_store_id
      LEFT JOIN active p ON true
      WHERE q.remaining IS NOT NULL OR x.raw ? 'expected_discount_quantity'
    ), expected AS (
      SELECT *,CASE WHEN percent>0 AND remaining IS NULL THEN quantity
        WHEN percent>0 THEN least(quantity,greatest(remaining-coalesce(sum(quantity)
        OVER(PARTITION BY menu_item_id ORDER BY ord ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0),0))
        ELSE 0 END allocated FROM requested
    ) SELECT 1 FROM expected WHERE (raw->>'expected_discount_quantity')::integer IS DISTINCT FROM allocated
      OR (allocated>0 AND (raw->>'expected_discount_percent')::numeric IS DISTINCT FROM percent)
  ) THEN RAISE EXCEPTION 'QR_DISCOUNT_QUANTITY_CHANGED'; END IF;
END $$;
REVOKE ALL ON FUNCTION public.validate_menu_option_batch(uuid,jsonb,text) FROM PUBLIC,anon,authenticated,service_role;

DO $$ BEGIN
  IF has_function_privilege('anon','public.admin_set_menu_discount_quantity(uuid,uuid,integer,integer)','EXECUTE')
    OR has_table_privilege('authenticated','public.menu_discount_quantities','UPDATE')
    OR has_function_privilege('authenticated','public.sync_active_order_promotion(uuid,uuid,timestamptz)','EXECUTE')
    OR NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.order_items'::regclass
      AND tgname='reserve_menu_discount_quantity' AND NOT tgisinternal)
  THEN RAISE EXCEPTION 'MENU_DISCOUNT_QUANTITY_VERIFY_FAILED'; END IF;
END $$;
COMMIT;
