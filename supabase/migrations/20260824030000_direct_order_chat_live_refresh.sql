-- Payload-free realtime invalidation for authenticated direct-order staff.
-- Public customers continue to read messages only through the session-bound
-- Edge endpoint; no direct table or Realtime access is granted.
-- production-gate: self-verifying

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.direct_order_messages') IS NULL
     OR to_regclass('public.pos_live_events') IS NULL
     OR to_regprocedure('public.emit_pos_live_event()') IS NULL THEN
    RAISE EXCEPTION 'CHAT_LIVE_REFRESH_PREREQUISITE_MISSING';
  END IF;
END
$$;

DROP TRIGGER IF EXISTS direct_order_chat_live_event
  ON public.direct_order_messages;
CREATE TRIGGER direct_order_chat_live_event
AFTER INSERT ON public.direct_order_messages
FOR EACH ROW
EXECUTE FUNCTION public.emit_pos_live_event('direct_order_chat');

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    JOIN pg_class table_row ON table_row.oid = trigger_row.tgrelid
    JOIN pg_namespace schema_row ON schema_row.oid = table_row.relnamespace
    WHERE schema_row.nspname = 'public'
      AND table_row.relname = 'direct_order_messages'
      AND trigger_row.tgname = 'direct_order_chat_live_event'
      AND NOT trigger_row.tgisinternal
      AND (trigger_row.tgtype & 4) = 4
      AND (trigger_row.tgtype & 1) = 1
      AND (trigger_row.tgtype & 2) = 0
  ) THEN
    RAISE EXCEPTION 'CHAT_LIVE_REFRESH_TRIGGER_MISSING';
  END IF;
END
$$;

COMMIT;
