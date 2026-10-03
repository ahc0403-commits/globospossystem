CREATE TRIGGER emergency_preserve_started_quantity_trigger
BEFORE INSERT OR UPDATE OF source_quantity,ordered_quantity,kitchen_started_quantity,excused_quantity
ON public.emergency_fulfillment_items FOR EACH ROW
EXECUTE FUNCTION public.emergency_preserve_started_quantity();
DO $$ DECLARE o uuid; work_id uuid; failed boolean:=false;
BEGIN
 o:=hours_test.new_order();
 SELECT id INTO STRICT work_id FROM public.emergency_fulfillment_items WHERE order_id=o LIMIT 1;
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000002',true);
 BEGIN
  PERFORM public.emergency_record_progress(work_id,'kitchen_done',1,gen_random_uuid());
 EXCEPTION WHEN check_violation THEN
  IF SQLERRM NOT LIKE '%emergency_fulfillment_quantity_chain%' THEN RAISE; END IF;
  failed:=true;
 END;
 IF NOT failed THEN RAISE EXCEPTION 'DELIVERY_INDIVIDUAL_PROGRESS_BUG_NOT_REPRODUCED'; END IF;
END $$;
SELECT 'DELIVERY_INDIVIDUAL_PROGRESS_CHAIN_BUG_REPRODUCED' AS result;
