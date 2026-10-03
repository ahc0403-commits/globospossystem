CREATE TRIGGER capture_mode BEFORE INSERT ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.capture_order_item_fulfillment_mode();
CREATE TRIGGER sync_kds AFTER INSERT OR UPDATE OF quantity,status ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.emergency_sync_order_item();
DO $$ DECLARE o uuid; n integer;
BEGIN
 o:=hours_test.new_order();
 SELECT count(*) INTO n FROM public.emergency_fulfillment_items WHERE order_id=o AND NOT is_cancelled;
 IF n<>8 THEN RAISE EXCEPTION 'BUG_NOT_REPRODUCED: expected 6 foods + 2 fees, got %',n; END IF;
 INSERT INTO hours_test.legacy_order
 SELECT o,md5(jsonb_agg(to_jsonb(i) ORDER BY id)::text) FROM public.order_items i WHERE order_id=o;
 IF EXISTS(SELECT 1 FROM public.direct_order_storefronts WHERE ordering_hours_enforced) THEN
 RAISE EXCEPTION 'PILOT_ALWAYS_OPEN_BUG_NOT_REPRODUCED'; END IF;
END $$;
SELECT 'FEE_AS_WORK_AND_ALWAYS_OPEN_REPRODUCED' AS result;
