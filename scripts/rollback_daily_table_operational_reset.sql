\set ON_ERROR_STOP on
BEGIN;
-- Stop automatic expiry without resurrecting orders already closed. Keep
-- ledger, columns, terminal guards and QR closed-order filtering intact.
UPDATE public.table_operational_reset_policies SET is_enabled=false,updated_at=clock_timestamp();
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname='cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname='table-operational-day-reset-0000-hcm';
  END IF;
END; $$;
COMMIT;
SELECT 'DAILY_TABLE_OPERATIONAL_RESET_AUTOMATION_DISABLED';
