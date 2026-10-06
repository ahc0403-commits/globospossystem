-- Operational rollback: preserve additive tables/history and customer device data.
-- Redeploy the preceding main revision through deploy_pos_production.sh afterward.
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';
DO $guard$
BEGIN
 IF strpos(pg_get_functiondef('public.sync_direct_delivery_ticket_from_kds()'::regprocedure),
  'PERFORM 1 FROM public.direct_order_requests WHERE id=(SELECT request_id FROM public.direct_order_financials WHERE order_id=NEW.order_id) FOR UPDATE;')=0 THEN
  RAISE EXCEPTION 'CUSTOMER_EXPERIENCE_ROLLBACK_SOURCE_DRIFT';
 END IF;
 IF EXISTS(SELECT 1 FROM pg_extension WHERE extname='pg_cron') THEN
  PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname='direct-order-customer-push-every-minute';
 END IF;
END;
$guard$;
DROP TRIGGER IF EXISTS direct_order_pickup_ready_notice ON public.direct_delivery_fulfillment_tickets;
DROP TRIGGER IF EXISTS direct_order_pickup_conversion_notice ON public.direct_order_requests;
DROP TRIGGER IF EXISTS direct_order_driver_handoff_notice ON public.direct_order_dispatches;
CREATE OR REPLACE FUNCTION public.sync_direct_delivery_ticket_from_kds()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_catalog'
AS $function$
DECLARE
  v_ticket public.direct_delivery_fulfillment_tickets%ROWTYPE;
BEGIN
  IF public.direct_order_is_pickup_pos_order(NEW.order_id,NEW.restaurant_id) THEN
    IF NEW.stage NOT IN ('kitchen_done', 'tray_dispatched') THEN RETURN NEW; END IF;
    SELECT t.* INTO v_ticket FROM public.direct_delivery_fulfillment_tickets t
    JOIN public.direct_order_financials f ON f.request_id = t.request_id
    WHERE f.order_id = NEW.order_id AND f.restaurant_id = NEW.restaurant_id FOR UPDATE OF t;
    IF NOT FOUND OR v_ticket.status IN ('completed', 'cancelled') THEN RETURN NEW; END IF;
    IF NEW.stage = 'tray_dispatched' AND NEW.delta > 0 AND NOT EXISTS (
      SELECT 1 FROM public.emergency_fulfillment_items i WHERE i.order_id = NEW.order_id
        AND NOT i.is_cancelled AND i.tray_dispatched_quantity < i.ordered_quantity - i.excused_quantity
    ) THEN
      UPDATE public.direct_delivery_fulfillment_tickets SET status = 'ready', version = version + 1,
        accepted_at = COALESCE(accepted_at, now()), ready_at = now(), updated_at = now()
      WHERE id = v_ticket.id AND status <> 'ready';
    ELSIF (NEW.stage = 'kitchen_done' AND NEW.delta > 0 AND v_ticket.status = 'pending')
       OR (NEW.delta < 0 AND v_ticket.status = 'ready') THEN
      UPDATE public.direct_delivery_fulfillment_tickets SET status = 'preparing', version = version + 1,
        accepted_at = COALESCE(accepted_at, now()), ready_at = NULL, updated_at = now()
      WHERE id = v_ticket.id;
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.delta <= 0 OR NEW.stage NOT IN ('kitchen_done', 'tray_dispatched') THEN
    RETURN NEW;
  END IF;

  SELECT ticket.* INTO v_ticket
  FROM public.direct_delivery_fulfillment_tickets ticket
  JOIN public.direct_order_financials financial
    ON financial.request_id = ticket.request_id
   AND financial.order_id = NEW.order_id
  FOR UPDATE OF ticket;
  IF NOT FOUND OR v_ticket.status IN ('completed', 'cancelled') THEN
    RETURN NEW;
  END IF;

  IF NEW.stage = 'kitchen_done' AND v_ticket.status = 'pending' THEN
    UPDATE public.direct_delivery_fulfillment_tickets
    SET status = 'preparing',
        version = version + 1,
        accepted_at = COALESCE(accepted_at, now()),
        updated_by = (
          SELECT user_row.auth_id
          FROM public.users user_row
          WHERE user_row.id = NEW.actor_user_id
        ),
        updated_at = now()
    WHERE id = v_ticket.id;
  ELSIF NEW.stage = 'tray_dispatched'
     AND v_ticket.status IN ('pending', 'preparing', 'ready')
     AND NOT EXISTS (
       SELECT 1
       FROM public.emergency_fulfillment_items item
       WHERE item.order_id = NEW.order_id
         AND item.is_cancelled = false
         AND item.tray_dispatched_quantity < item.ordered_quantity
     ) THEN
    UPDATE public.direct_delivery_fulfillment_tickets
    SET status = 'dispatched',
        version = version + 1,
        accepted_at = COALESCE(accepted_at, now()),
        ready_at = COALESCE(ready_at, now()),
        dispatched_at = COALESCE(dispatched_at, now()),
        updated_by = (
          SELECT user_row.auth_id
          FROM public.users user_row
          WHERE user_row.id = NEW.actor_user_id
        ),
        updated_at = now()
    WHERE id = v_ticket.id;
  END IF;
  RETURN NEW;
END;
$function$
;
COMMIT;

