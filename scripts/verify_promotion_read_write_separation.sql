DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='promotion-boundaries'
    AND active AND schedule='* * * * *' AND command='select public.run_due_store_promotions();') THEN
    RAISE EXCEPTION 'PROMOTION_SCHEDULER_MISSING';
  END IF;
  IF has_function_privilege('authenticated','public.process_payment_before_promotion_read_split(uuid,uuid,numeric,text)','EXECUTE')
    OR has_function_privilege('anon','public.process_payment(uuid,uuid,numeric,text)','EXECUTE')
    OR has_table_privilege('authenticated','public.promotion_schedule_cursor','SELECT')
    OR has_function_privilege('authenticated','public.run_due_store_promotions()','EXECUTE') THEN
    RAISE EXCEPTION 'PROMOTION_READ_SPLIT_PRIVILEGES_INVALID';
  END IF;
  IF position('PROMOTION_PRICE_CHANGED' IN pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))=0 THEN
    RAISE EXCEPTION 'PROMOTION_PAYMENT_GUARD_MISSING';
  END IF;
END $$;
