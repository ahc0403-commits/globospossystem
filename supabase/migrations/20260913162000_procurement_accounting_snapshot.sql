BEGIN;
CREATE FUNCTION public.procurement_order_snapshot(p_store_id uuid,p_order_id uuid,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb; po public.inventory_purchase_orders%rowtype;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 IF NOT COALESCE((actor->>'can_view_prices')::boolean,false) THEN RAISE EXCEPTION 'PROCUREMENT_PRICES_FORBIDDEN'; END IF;
 SELECT * INTO po FROM public.inventory_purchase_orders WHERE id=p_order_id AND restaurant_id=p_store_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_NOT_FOUND'; END IF;
 RETURN jsonb_build_object('contract_version',2,'order',to_jsonb(po),
 'lines',COALESCE((SELECT jsonb_agg(to_jsonb(l)||jsonb_build_object('product_name',p.name) ORDER BY l.id) FROM public.inventory_purchase_order_lines l JOIN public.inventory_products p ON p.id=l.product_id WHERE l.purchase_order_id=po.id),'[]'),
 'receipts',COALESCE((SELECT jsonb_agg(to_jsonb(r)||jsonb_build_object('lines',(
   SELECT jsonb_agg(to_jsonb(l)||jsonb_build_object('returned_quantity_base',COALESCE((SELECT sum(quantity_base) FROM public.inventory_supplier_returns sr WHERE sr.receipt_line_id=l.id),0)) ORDER BY l.id) FROM public.inventory_receipt_lines l WHERE l.receipt_id=r.id)) ORDER BY r.id)
   FROM public.inventory_receipts r WHERE r.purchase_order_id=po.id AND r.status='confirmed'),'[]'),
 'returns',COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.id) FROM public.inventory_supplier_returns r WHERE r.purchase_order_id=po.id),'[]'));
END $$;
REVOKE ALL ON FUNCTION public.procurement_order_snapshot(uuid,uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.procurement_order_snapshot(uuid,uuid,jsonb) TO service_role;
COMMIT;
