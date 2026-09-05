DO $$ BEGIN
  IF to_regprocedure('public.sync_active_order_promotion(uuid,uuid,timestamptz)') IS NULL
    OR to_regclass('public.order_discount_lines') IS NULL
    OR to_regclass('public.pos_live_events') IS NULL THEN
    RAISE EXCEPTION 'PROMOTION_ALLOCATION_LIVE_PREREQUISITE_MISSING';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
    WHERE tgrelid = to_regclass('public.order_discounts')
      AND tgname = 'pos_live_event_trigger' AND NOT tgisinternal
      AND tgenabled = 'O' AND tgtype = 29
      AND tgfoid = to_regprocedure('public.emit_pos_live_event()')
      AND tgargs = convert_to('orders', 'UTF8') || decode('00', 'hex')) THEN
    RAISE EXCEPTION 'PROMOTION_ALLOCATION_PARENT_LIVE_TRIGGER_MISSING';
  END IF;
END $$;
