-- Preserve scheduled-promotion allocations using one VAT update per payment.
-- Complements the payment-core batch without changing authorization or totals.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';
CREATE OR REPLACE FUNCTION public.process_payment_before_promotion_read_split(
 p_order_id uuid,p_store_id uuid,p_amount numeric,p_method text
) RETURNS public.payments LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE
 v_discount public.order_discounts%ROWTYPE;
 v_original_mode text;
 v_original_value numeric(12,2);
 v_allocation_total numeric(15,2);
 v_has_allocations boolean:=false;
 v_vat_pricing_mode text:='exclusive';
 v_payment public.payments%ROWTYPE;
BEGIN
 SELECT * INTO v_discount FROM public.order_discounts discount
 WHERE discount.order_id=p_order_id AND discount.restaurant_id=p_store_id AND discount.status='active' FOR UPDATE;
 IF FOUND AND v_discount.approved_via='scheduled_promotion' THEN
  SELECT count(*)>0,round(coalesce(sum(allocation.discount_amount),0),2)
  INTO v_has_allocations,v_allocation_total FROM public.order_discount_lines allocation
  WHERE allocation.order_discount_id=v_discount.id;
  IF v_has_allocations AND v_allocation_total IS DISTINCT FROM round(v_discount.discount_amount,2) THEN
   RAISE EXCEPTION 'PROMOTION_ALLOCATION_MISMATCH';
  END IF;
 END IF;
 IF v_has_allocations THEN
  v_original_mode:=v_discount.discount_mode;
  v_original_value:=v_discount.discount_value;
  UPDATE public.order_discounts SET discount_mode='amount',discount_value=v_allocation_total,
   discount_amount=v_allocation_total,updated_at=now() WHERE id=v_discount.id;
 END IF;
 v_payment:=public.process_payment_without_scoped_promotions(p_order_id,p_store_id,p_amount,p_method);
 IF NOT v_has_allocations THEN RETURN v_payment; END IF;
 UPDATE public.order_discounts SET discount_mode=v_original_mode,discount_value=v_original_value,
  discount_amount=v_allocation_total,updated_at=now() WHERE id=v_discount.id;
 SELECT coalesce(restaurant.vat_pricing_mode,'exclusive') INTO v_vat_pricing_mode
 FROM public.restaurants restaurant WHERE restaurant.id=p_store_id;
 WITH priced AS MATERIALIZED (
  SELECT item.id,public.direct_order_payment_vat(
   coalesce(item.vat_profile_snapshot,jsonb_build_array(jsonb_build_object('rate',menu.effective_vat_rate,'weight',1))),
   round(item.unit_price*item.quantity,2),v_vat_pricing_mode,coalesce(allocation.discount_amount,0)) tax
  FROM public.order_items item
  LEFT JOIN public.menu_items menu ON menu.id=item.menu_item_id
  LEFT JOIN public.order_discount_lines allocation ON allocation.order_discount_id=v_discount.id AND allocation.order_item_id=item.id
  WHERE item.order_id=p_order_id AND item.restaurant_id=p_store_id AND item.status<>'cancelled'
   AND item.item_type='menu_item' AND coalesce(item.is_service_item,false)=false
 ) UPDATE public.order_items item SET vat_rate=(p.tax->>'vat_rate')::numeric,vat_amount=(p.tax->>'vat')::numeric,
  total_amount_ex_tax=(p.tax->>'supply')::numeric,paying_amount_inc_tax=(p.tax->>'total')::numeric,vat_breakdown=p.tax->'parts'
 FROM priced p WHERE item.id=p.id;
 RETURN v_payment;
END;
$$;
DO $$ BEGIN
 IF has_function_privilege('anon','public.process_payment_before_promotion_read_split(uuid,uuid,numeric,text)','EXECUTE') THEN
  RAISE EXCEPTION 'OPERATING_PAYMENT_WRAPPER_ACCESS_INVALID';
 END IF;
END $$;
COMMIT;
