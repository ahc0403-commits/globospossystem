-- Restore the previous application before executing this rollback.
BEGIN;
DO $$ DECLARE v_job bigint; BEGIN
  FOR v_job IN SELECT jobid FROM cron.job WHERE jobname='promotion-boundaries' LOOP
    PERFORM cron.unschedule(v_job);
  END LOOP;
END $$;
DROP FUNCTION public.process_payment(uuid,uuid,numeric,text);
ALTER FUNCTION public.process_payment_before_promotion_read_split(uuid,uuid,numeric,text) RENAME TO process_payment;
GRANT EXECUTE ON FUNCTION public.process_payment(uuid,uuid,numeric,text) TO authenticated,service_role;
-- Keep the private cursor/helper definitions to avoid destructive data cleanup.
COMMIT;
