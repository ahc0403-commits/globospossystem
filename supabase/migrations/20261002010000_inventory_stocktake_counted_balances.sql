-- Completed initial counts establish dated stock availability without replaying adjustments.
BEGIN;
CREATE OR REPLACE FUNCTION public.inventory_stock_at(p_item_id uuid,p_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE c public.inventory_stock_checkpoints%ROWTYPE; q numeric; known boolean:=true; origin text:='tracked'; registered timestamptz; unknown_history boolean:=false; counted_anchor boolean:=false;
BEGIN
 SELECT * INTO c FROM public.inventory_stock_checkpoints WHERE ingredient_id=p_item_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_LEDGER_MISSING'; END IF;
 SELECT created_at INTO registered FROM public.inventory_items WHERE id=p_item_id;
 q:=c.opening_stock;
 IF p_at<c.tracked_from THEN
  origin:='legacy_reconstructed';
  unknown_history:=EXISTS(SELECT 1 FROM public.inventory_transactions t
   WHERE t.ingredient_id=p_item_id AND t.created_at>=p_at AND t.created_at<c.tracked_from AND t.effective_at IS NULL);
  -- An explicit initial count can predate registration. Its adjustment is
  -- already in the movement ledger; only the availability check changes.
  counted_anchor:=EXISTS(
   SELECT 1 FROM public.inventory_stock_audit_sessions s
   JOIN public.inventory_stock_audit_lines l ON l.session_id=s.id
   JOIN public.inventory_products p ON p.id=l.product_id
   WHERE s.restaurant_id=c.restaurant_id AND p.inventory_item_id=p_item_id
    AND s.status='completed' AND s.template_version=2 AND l.status='counted'
    AND l.actual_quantity_base IS NOT NULL AND s.effective_at<=p_at
    AND s.count_snapshot @> jsonb_build_array(jsonb_build_object('product_id',p.id,'inventory_item_id',p_item_id)));
  known:=(registered<=p_at OR counted_anchor) AND NOT unknown_history;
  IF registered>p_at AND counted_anchor THEN origin:='counted_anchor'; END IF;
  SELECT q-coalesce(sum(quantity_g),0) INTO q FROM public.inventory_transactions
   WHERE ingredient_id=p_item_id AND created_at<c.tracked_from AND effective_at>p_at;
  SELECT q+coalesce(sum(quantity_base),0) INTO q FROM public.inventory_stock_movements WHERE ingredient_id=p_item_id AND effective_at<=p_at;
 ELSE
  SELECT q+coalesce(sum(quantity_base),0) INTO q FROM public.inventory_stock_movements WHERE ingredient_id=p_item_id AND effective_at<=p_at;
 END IF;
 IF NOT known THEN q:=NULL; origin:='unavailable'; END IF;
 RETURN jsonb_build_object('quantity',q,'source',origin,'tracked_from',c.tracked_from,'unverified_history',unknown_history);
END $$;

CREATE FUNCTION public.get_inventory_stock_audit_balances(p_store_id uuid,p_business_date date DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE day date; reference timestamptz; rows jsonb; moment timestamptz:=now();
BEGIN
 IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_FORBIDDEN'; END IF;
 day:=coalesce(p_business_date,(SELECT max(count_business_date) FROM public.inventory_stock_audit_sessions
  WHERE restaurant_id=p_store_id AND status='completed' AND template_version=2),(moment AT TIME ZONE 'Asia/Ho_Chi_Minh')::date);
 SELECT max(effective_at) INTO reference FROM public.inventory_stock_audit_sessions
  WHERE restaurant_id=p_store_id AND count_business_date=day AND status='completed' AND template_version=2;
 IF reference IS NULL THEN reference:=least((day+time '23:59:59') AT TIME ZONE 'Asia/Ho_Chi_Minh',moment); END IF;
 IF day>(moment AT TIME ZONE 'Asia/Ho_Chi_Minh')::date THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_REFERENCE_TIME_NOT_REACHED'; END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'product_id',p.id,'product_code',p.product_code,'product_name',p.name,'base_unit',p.base_unit,
  'system_quantity_base',stock.value->'quantity','baseline_source',stock.value->>'source',
  'actual_quantity_base',counted.actual_quantity_base,'variance_quantity_base',(stock.value->>'quantity')::numeric-counted.actual_quantity_base,
  'session_id',counted.session_id) ORDER BY p.product_code),'[]'::jsonb) INTO rows
 FROM public.inventory_products p JOIN public.inventory_items i ON i.id=p.inventory_item_id AND i.restaurant_id=p_store_id AND i.is_active
 CROSS JOIN LATERAL (SELECT public.inventory_stock_at(i.id,reference) AS value) stock
 LEFT JOIN LATERAL (
  SELECT l.actual_quantity_base,s.id AS session_id
  FROM public.inventory_stock_audit_sessions s JOIN public.inventory_stock_audit_lines l ON l.session_id=s.id
  WHERE s.restaurant_id=p_store_id AND s.count_business_date=day AND s.effective_at=reference
   AND s.status='completed' AND s.template_version=2 AND l.product_id=p.id AND l.status='counted'
   AND s.count_snapshot @> jsonb_build_array(jsonb_build_object('product_id',p.id,'inventory_item_id',i.id))
  ORDER BY s.completed_at DESC,s.id DESC LIMIT 1
 ) counted ON true
 WHERE p.restaurant_id=p_store_id AND p.is_active;
 RETURN jsonb_build_object('store_id',p_store_id,'business_date',day,'effective_at',reference,'rows',rows);
END $$;
REVOKE ALL ON FUNCTION public.get_inventory_stock_audit_balances(uuid,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_stock_audit_balances(uuid,date) TO authenticated,service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;
