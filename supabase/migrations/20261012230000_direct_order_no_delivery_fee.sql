BEGIN;
-- production-gate: self-verifying
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';

-- A courier cost is not a POS sale. Keep historical foreign keys, but a new
-- fee-free order must not manufacture an order item merely to fill this field.
ALTER TABLE public.direct_order_financials ALTER COLUMN delivery_fee_item_id DROP NOT NULL;

CREATE FUNCTION public.pos_is_delivery_fee_item(p_item_type text,p_menu_item_id uuid,p_display_name text,p_label text)
RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path=pg_catalog AS $$
 SELECT COALESCE(p_item_type='service_charge' AND p_menu_item_id IS NULL AND
  (lower(btrim(COALESCE(p_display_name,''))) IN ('phí giao hàng','delivery fee','배송비') OR
   lower(btrim(COALESCE(p_label,''))) IN ('phí giao hàng','delivery fee','배송비')),false);
$$;
REVOKE ALL ON FUNCTION public.pos_is_delivery_fee_item(text,uuid,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pos_is_delivery_fee_item(text,uuid,text,text) TO authenticated,service_role;

CREATE FUNCTION public.reject_pos_delivery_fee_item() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_catalog AS $$
BEGIN
 IF public.pos_is_delivery_fee_item(NEW.item_type,NEW.menu_item_id,NEW.display_name,NEW.label) THEN
  IF TG_OP='INSERT' THEN RAISE EXCEPTION 'DELIVERY_FEE_DISABLED'; END IF;
  IF ROW(NEW.item_type,NEW.menu_item_id,NEW.display_name,NEW.label,NEW.quantity,NEW.unit_price,
    NEW.total_amount_ex_tax,NEW.vat_rate,NEW.vat_amount,NEW.paying_amount_inc_tax)
   IS DISTINCT FROM ROW(OLD.item_type,OLD.menu_item_id,OLD.display_name,OLD.label,OLD.quantity,OLD.unit_price,
    OLD.total_amount_ex_tax,OLD.vat_rate,OLD.vat_amount,OLD.paying_amount_inc_tax)
  THEN RAISE EXCEPTION 'DELIVERY_FEE_DISABLED'; END IF;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.reject_pos_delivery_fee_item() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER reject_pos_delivery_fee_item BEFORE INSERT OR UPDATE ON public.order_items
 FOR EACH ROW EXECUTE FUNCTION public.reject_pos_delivery_fee_item();

CREATE FUNCTION public.reject_new_direct_order_delivery_fee() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_catalog AS $$
BEGIN
 IF TG_TABLE_NAME='direct_order_quotes' THEN
  IF NEW.delivery_fee_total<>0 OR NEW.delivery_fee_pretax<>0 OR NEW.delivery_fee_vat<>0 THEN
   IF TG_OP='INSERT' THEN RAISE EXCEPTION 'DELIVERY_FEE_DISABLED'; END IF;
   IF ROW(NEW.delivery_fee_total,NEW.delivery_fee_pretax,NEW.delivery_fee_vat)
    IS DISTINCT FROM ROW(OLD.delivery_fee_total,OLD.delivery_fee_pretax,OLD.delivery_fee_vat)
   THEN RAISE EXCEPTION 'DELIVERY_FEE_DISABLED'; END IF;
  END IF;
 ELSIF TG_TABLE_NAME='direct_order_payment_charges' THEN
  IF NEW.kind='delivery' THEN RAISE EXCEPTION 'DELIVERY_FEE_DISABLED'; END IF;
 ELSIF TG_TABLE_NAME='direct_order_financials' THEN
  IF NEW.delivery_fee_total<>0 OR NEW.delivery_fee_item_id IS NOT NULL THEN RAISE EXCEPTION 'DELIVERY_FEE_DISABLED'; END IF;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.reject_new_direct_order_delivery_fee() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER reject_new_direct_order_delivery_fee_quote BEFORE INSERT OR UPDATE ON public.direct_order_quotes
 FOR EACH ROW EXECUTE FUNCTION public.reject_new_direct_order_delivery_fee();
CREATE TRIGGER reject_new_direct_order_delivery_fee_charge BEFORE INSERT ON public.direct_order_payment_charges
 FOR EACH ROW EXECUTE FUNCTION public.reject_new_direct_order_delivery_fee();
CREATE TRIGGER reject_new_direct_order_delivery_fee_financial BEFORE INSERT ON public.direct_order_financials
 FOR EACH ROW EXECUTE FUNCTION public.reject_new_direct_order_delivery_fee();

DO $payment$ DECLARE d text; fee_block text; BEGIN
 SELECT pg_get_functiondef('public.direct_order_approve_payment(uuid,uuid,numeric,text)'::regprocedure) INTO d;
 fee_block:=$old$  INSERT INTO public.order_items(
    restaurant_id, order_id, menu_item_id, item_type, label,
    display_name, unit_price, quantity, status,
    vat_rate, vat_amount, total_amount_ex_tax, paying_amount_inc_tax,
    is_service_item, fulfillment_mode_snapshot
  ) VALUES (
    p_store_id, v_order.id, NULL, 'service_charge', 'Phí giao hàng',
    'Phí giao hàng', v_quote.delivery_fee_pretax, 1, 'served',
    v_quote.delivery_fee_vat_rate, v_quote.delivery_fee_vat,
    v_quote.delivery_fee_pretax, v_quote.delivery_fee_total,
    false, 'pos_print'
  ) RETURNING * INTO v_delivery_item;$old$;
 IF strpos(d,fee_block)=0 OR strpos(d,'v_delivery_item.id, v_quote.menu_total')=0
  OR strpos(d,'  INSERT INTO public.orders(')=0 THEN RAISE EXCEPTION 'NO_DELIVERY_FEE_APPROVAL_ANCHOR_DRIFT'; END IF;
 d:=replace(d,fee_block,'  -- No delivery fee item is created, including a zero-value placeholder.');
 d:=replace(d,'  v_delivery_item public.order_items%ROWTYPE;'||chr(10),'');
 d:=replace(d,'v_delivery_item.id, v_quote.menu_total','NULL::uuid, v_quote.menu_total');
 d:=replace(d,'  INSERT INTO public.orders(',$new$  IF v_quote.delivery_fee_total IS DISTINCT FROM 0::numeric THEN
    RAISE EXCEPTION 'DELIVERY_FEE_DISABLED';
  END IF;

  INSERT INTO public.orders($new$);
 EXECUTE d;
END $payment$;

-- Supplemental receipt processing is for food payments only. Reject a delivery
-- charge before recording money, and remove its former order/item writer.
DO $receipt$ DECLARE d text; a integer; b integer; anchor text; f record; n integer:=0; BEGIN
 -- Reviewed wrapper versions can delegate to a private predecessor. Patch the
 -- actual writer rather than assuming that the public entry point owns it.
 FOR f IN WITH definitions AS MATERIALIZED (
  SELECT pg_get_functiondef(p.oid) AS definition FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
  WHERE ns.nspname='public' AND p.prokind='f' AND p.proname LIKE 'direct_order_%'
 ) SELECT definition FROM definitions WHERE strpos(definition,' IF c.kind=''delivery'' AND ')>0 AND strpos(definition,'''Phí giao hàng''')>0 LOOP
  d:=f.definition;anchor:=' IF m.id IS DISTINCT FROM (SELECT x.id';
  a:=strpos(d,' IF c.kind=''delivery'' AND ');
  b:=strpos(d,' ELSIF c.kind IS DISTINCT FROM ''delivery'' AND ');
  IF b<=a OR strpos(d,anchor)=0 THEN RAISE EXCEPTION 'NO_DELIVERY_FEE_RECEIPT_ANCHOR_DRIFT'; END IF;
  d:=substr(d,1,a-1)||' IF'||substr(d,b+length(' ELSIF'));
  d:=replace(d,anchor,$new$ IF c.kind='delivery' THEN RAISE EXCEPTION 'DELIVERY_FEE_DISABLED'; END IF;
 IF m.id IS DISTINCT FROM (SELECT x.id$new$);
  EXECUTE d;n:=n+1;
 END LOOP;
 IF n=0 THEN RAISE EXCEPTION 'NO_DELIVERY_FEE_RECEIPT_WRITER_MISSING'; END IF;
END $receipt$;

CREATE OR REPLACE FUNCTION public.direct_order_post_delivery_advance(p_request_id uuid,p_store_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE amount numeric;
BEGIN
 SELECT greatest(0,COALESCE((SELECT sum(x.amount) FROM public.direct_order_payment_receipts x
  JOIN public.direct_order_payment_charges c ON c.id=x.charge_id WHERE x.request_id=$1 AND x.restaurant_id=$2 AND c.kind='delivery'),0)
  -COALESCE((SELECT sum(c.amount) FROM public.direct_order_payment_charges c WHERE c.request_id=$1 AND c.restaurant_id=$2 AND c.kind='delivery' AND c.payment_id IS NOT NULL),0)
  -COALESCE((SELECT sum(unposted_amount-overpayment_amount) FROM public.direct_order_refund_records WHERE request_id=$1 AND restaurant_id=$2),0)) INTO amount;
 IF amount>0 THEN RAISE EXCEPTION 'DELIVERY_FEE_DISABLED'; END IF;
END $$;
REVOKE ALL ON FUNCTION public.direct_order_post_delivery_advance(uuid,uuid) FROM PUBLIC,anon,authenticated;

DO $verify$ BEGIN
 IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='direct_order_financials'
  AND column_name='delivery_fee_item_id' AND is_nullable<>'YES')
 OR strpos(pg_get_functiondef('public.direct_order_approve_payment(uuid,uuid,numeric,text)'::regprocedure),'v_delivery_item')>0
 OR strpos(pg_get_functiondef('public.direct_order_record_receipt(uuid,uuid,uuid,uuid,numeric,text)'::regprocedure),'''Phí giao hàng''')>0
 OR strpos(pg_get_functiondef('public.direct_order_post_delivery_advance(uuid,uuid)'::regprocedure),'INSERT INTO public.orders')>0
 OR NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.order_items'::regclass AND tgname='reject_pos_delivery_fee_item' AND NOT tgisinternal)
 OR NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.direct_order_quotes'::regclass AND tgname='reject_new_direct_order_delivery_fee_quote' AND NOT tgisinternal)
 OR NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.direct_order_payment_charges'::regclass AND tgname='reject_new_direct_order_delivery_fee_charge' AND NOT tgisinternal)
 THEN RAISE EXCEPTION 'NO_DELIVERY_FEE_CONTRACT_DRIFT'; END IF;
END $verify$;
COMMIT;
