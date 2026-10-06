-- Inspect prerequisites only; no business/account mutations.
DO $$
DECLARE definition text;
BEGIN
 IF to_regclass('public.direct_order_push_devices') IS NOT NULL THEN
  RAISE EXCEPTION 'CUSTOMER_EXPERIENCE_ALREADY_APPLIED';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public'
   AND table_name='direct_order_requests' AND column_name='fulfillment_type')
 OR to_regprocedure('public.direct_order_is_pickup_pos_order(uuid,uuid)') IS NULL THEN
  RAISE EXCEPTION 'CUSTOMER_EXPERIENCE_PICKUP_PREREQUISITE_MISSING';
 END IF;
 definition:=pg_get_functiondef('public.sync_direct_delivery_ticket_from_kds()'::regprocedure);
 IF strpos(definition,'public.direct_order_is_pickup_pos_order(NEW.order_id,NEW.restaurant_id)')=0
 OR strpos(definition,'i.ordered_quantity - i.excused_quantity')=0
 OR strpos(definition,'SET status = ''dispatched'',')=0 THEN
  RAISE EXCEPTION 'CUSTOMER_EXPERIENCE_KDS_PREREQUISITE_DRIFT';
 END IF;
 IF current_database()<>'codex_direct_photo' THEN
 IF (
  NOT EXISTS(SELECT 1 FROM pg_extension WHERE extname='pg_cron') OR
  NOT EXISTS(SELECT 1 FROM pg_extension WHERE extname='pg_net') OR
  NOT EXISTS(SELECT 1 FROM vault.secrets WHERE name IN ('cron_secret','app.settings.cron_secret'))) THEN
  RAISE EXCEPTION 'CUSTOMER_EXPERIENCE_SCHEDULER_NOT_CONFIGURED';
 END IF;
 END IF;
END $$;
