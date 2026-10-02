BEGIN;
DROP FUNCTION IF EXISTS public.get_inventory_stock_audit_balances(uuid,date);
CREATE OR REPLACE FUNCTION public.inventory_stock_at(p_item_id uuid,p_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE c public.inventory_stock_checkpoints%ROWTYPE; q numeric; known boolean:=true; origin text:='tracked'; registered timestamptz; unknown_history boolean:=false;
BEGIN
 SELECT * INTO c FROM public.inventory_stock_checkpoints WHERE ingredient_id=p_item_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_LEDGER_MISSING'; END IF;
 SELECT created_at INTO registered FROM public.inventory_items WHERE id=p_item_id;
 q:=c.opening_stock;
 IF p_at<c.tracked_from THEN
  origin:='legacy_reconstructed';
  unknown_history:=EXISTS(SELECT 1 FROM public.inventory_transactions t
   WHERE t.ingredient_id=p_item_id AND t.created_at>=p_at AND t.created_at<c.tracked_from AND t.effective_at IS NULL);
  known:=registered<=p_at AND NOT unknown_history;
  SELECT q-coalesce(sum(quantity_g),0) INTO q FROM public.inventory_transactions
   WHERE ingredient_id=p_item_id AND created_at<c.tracked_from AND effective_at>p_at;
  SELECT q+coalesce(sum(quantity_base),0) INTO q FROM public.inventory_stock_movements WHERE ingredient_id=p_item_id AND effective_at<=p_at;
 ELSE
  SELECT q+coalesce(sum(quantity_base),0) INTO q FROM public.inventory_stock_movements WHERE ingredient_id=p_item_id AND effective_at<=p_at;
 END IF;
 IF NOT known THEN q:=NULL; origin:='unavailable'; END IF;
 RETURN jsonb_build_object('quantity',q,'source',origin,'tracked_from',c.tracked_from,'unverified_history',unknown_history);
END $$;
NOTIFY pgrst, 'reload schema';
COMMIT;
