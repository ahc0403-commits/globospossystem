\set ON_ERROR_STOP on

-- The alert migration may only attach to the already verified direct-order
-- request table and the existing payload-free POS live-event infrastructure.
DO $gate$
BEGIN
  IF to_regclass('public.direct_order_requests') IS NULL
     OR to_regclass('public.pos_live_events') IS NULL
     OR to_regprocedure('public.direct_order_require_actor(uuid,text[])') IS NULL
     OR to_regprocedure('public.emit_pos_live_event()') IS NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_ALERT_DEPENDENCY_MISSING';
  END IF;

  IF to_regprocedure(
    'public.direct_order_arrival_alerts_after(uuid,timestamp with time zone,uuid,integer)'
  ) IS NOT NULL OR EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid = 'public.direct_order_requests'::regclass
      AND trigger_row.tgname = 'direct_order_arrival_live_event'
      AND NOT trigger_row.tgisinternal
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_ALERT_PARTIAL_INSTALLATION_DETECTED';
  END IF;
END;
$gate$;

SELECT 'DIRECT_DELIVERY_ARRIVAL_ALERT_PREFLIGHT_PASS' AS result;
