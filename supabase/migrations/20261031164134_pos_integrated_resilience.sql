-- production-gate: self-verifying
-- Preserve reservation locks and all financial allocation logic. Recompute once
-- per changed order, after the complete SQL statement, instead of once per line.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.order_items'::regclass
  AND tgname='trg_sync_order_promotion' AND NOT tgisinternal
  AND tgfoid='public.trg_sync_order_promotion()'::regprocedure) THEN
  RAISE EXCEPTION 'RESILIENCE_PREDECESSOR_TRIGGER_REQUIRED';
 END IF;
 PERFORM set_config('pos.resilience_allocation_hash',
  md5(pg_get_functiondef('public.sync_active_order_promotion(uuid,uuid,timestamptz)'::regprocedure)),true);
END $$;

CREATE FUNCTION public.sync_changed_order_promotions_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE changed record;
BEGIN
 IF TG_OP='INSERT' THEN
  FOR changed IN SELECT DISTINCT restaurant_id,order_id FROM new_lines
   WHERE order_id IS NOT NULL ORDER BY restaurant_id,order_id LOOP
   PERFORM public.sync_active_order_promotion(changed.order_id,changed.restaurant_id,now());
  END LOOP;
 ELSIF TG_OP='DELETE' THEN
  FOR changed IN SELECT DISTINCT restaurant_id,order_id FROM old_lines
   WHERE order_id IS NOT NULL ORDER BY restaurant_id,order_id LOOP
   PERFORM public.sync_active_order_promotion(changed.order_id,changed.restaurant_id,now());
  END LOOP;
 ELSE
  FOR changed IN
   WITH affected AS MATERIALIZED (
    SELECT n.restaurant_id,n.order_id,o.restaurant_id old_store,o.order_id old_order
    FROM new_lines n FULL JOIN old_lines o USING(id)
    WHERE (n.unit_price,n.quantity,n.status,n.menu_item_id,n.is_service_item,
           n.order_id,n.restaurant_id,n.promotion_quantity_snapshot)
      IS DISTINCT FROM
          (o.unit_price,o.quantity,o.status,o.menu_item_id,o.is_service_item,
           o.order_id,o.restaurant_id,o.promotion_quantity_snapshot)
   )
   SELECT restaurant_id,order_id FROM affected WHERE order_id IS NOT NULL
   UNION SELECT old_store,old_order FROM affected WHERE old_order IS NOT NULL
   ORDER BY 1,2
  LOOP
   PERFORM public.sync_active_order_promotion(changed.order_id,changed.restaurant_id,now());
  END LOOP;
 END IF;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.sync_changed_order_promotions_v1() FROM PUBLIC,anon,authenticated,service_role;
DROP TRIGGER trg_sync_order_promotion ON public.order_items;
CREATE TRIGGER sync_order_promotions_insert AFTER INSERT ON public.order_items
 REFERENCING NEW TABLE AS new_lines FOR EACH STATEMENT
 EXECUTE FUNCTION public.sync_changed_order_promotions_v1();
CREATE TRIGGER sync_order_promotions_delete AFTER DELETE ON public.order_items
 REFERENCING OLD TABLE AS old_lines FOR EACH STATEMENT
 EXECUTE FUNCTION public.sync_changed_order_promotions_v1();
CREATE TRIGGER sync_order_promotions_update AFTER UPDATE ON public.order_items
 REFERENCING OLD TABLE AS old_lines NEW TABLE AS new_lines FOR EACH STATEMENT
 EXECUTE FUNCTION public.sync_changed_order_promotions_v1();

-- One invalidation per store/transaction. Old web clients still receive the
-- same domain/source signal and read committed final quota values after commit.
-- Transaction-local state rolls back together with the event on savepoint abort.
CREATE FUNCTION public.emit_menu_discount_quantity_event_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE row_data jsonb; store uuid; emitted jsonb;
BEGIN
 IF TG_OP='UPDATE' AND NEW.remaining IS NOT DISTINCT FROM OLD.remaining THEN RETURN NEW; END IF;
 row_data:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
 store:=(row_data->>'restaurant_id')::uuid;
 emitted:=coalesce(nullif(current_setting('pos.quota_events',true),''),'{}')::jsonb;
 IF NOT emitted ? store::text THEN
  INSERT INTO public.pos_live_events(restaurant_id,domain,source_table,event_type)
   VALUES(store,'menu','menu_discount_quantities',TG_OP);
  PERFORM set_config('pos.quota_events',(emitted||jsonb_build_object(store::text,true))::text,true);
 END IF;
 RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;
REVOKE ALL ON FUNCTION public.emit_menu_discount_quantity_event_v1() FROM PUBLIC,anon,authenticated,service_role;
DROP TRIGGER pos_live_event_trigger ON public.menu_discount_quantities;
CREATE TRIGGER pos_live_event_trigger AFTER INSERT OR UPDATE OR DELETE
 ON public.menu_discount_quantities FOR EACH ROW EXECUTE FUNCTION public.emit_menu_discount_quantity_event_v1();

DO $$ BEGIN
 IF (SELECT count(*) FROM pg_trigger WHERE tgrelid='public.order_items'::regclass
  AND tgfoid='public.sync_changed_order_promotions_v1()'::regprocedure AND NOT tgisinternal)<>3
 OR EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.order_items'::regclass
  AND tgname='trg_sync_order_promotion' AND NOT tgisinternal)
 OR has_function_privilege('authenticated','public.sync_changed_order_promotions_v1()','EXECUTE')
 OR has_function_privilege('anon','public.emit_menu_discount_quantity_event_v1()','EXECUTE')
 OR md5(pg_get_functiondef('public.sync_active_order_promotion(uuid,uuid,timestamptz)'::regprocedure))
    IS DISTINCT FROM current_setting('pos.resilience_allocation_hash',true) THEN
  RAISE EXCEPTION 'RESILIENCE_TRIGGER_CONTRACT_INVALID';
 END IF;
END $$;
COMMIT;
