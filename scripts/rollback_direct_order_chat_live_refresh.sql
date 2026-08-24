\set ON_ERROR_STOP on

BEGIN;

DROP TRIGGER IF EXISTS direct_order_chat_live_event
  ON public.direct_order_messages;

COMMIT;
