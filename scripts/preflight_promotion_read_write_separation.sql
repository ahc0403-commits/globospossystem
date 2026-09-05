DO $$ BEGIN
  IF to_regprocedure('public.sync_active_order_promotion(uuid,uuid,timestamptz)') IS NULL
    OR to_regprocedure('public.process_payment(uuid,uuid,numeric,text)') IS NULL
    OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_cron') THEN
    RAISE EXCEPTION 'PROMOTION_READ_SPLIT_PREREQUISITE_MISSING';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='public.order_discounts'::regclass
    AND tgname='pos_live_event_trigger' AND NOT tgisinternal AND tgenabled='O') THEN
    RAISE EXCEPTION 'PROMOTION_READ_SPLIT_LIVE_FEED_MISSING';
  END IF;
END $$;
