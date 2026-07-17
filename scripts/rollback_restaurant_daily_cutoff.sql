\set ON_ERROR_STOP on

DO $$
DECLARE
  v_job_id bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    FOR v_job_id IN
      SELECT jobid
      FROM cron.job
      WHERE jobname = 'restaurant-daily-sales-finalize-2220-hcm'
    LOOP
      PERFORM cron.unschedule(v_job_id);
    END LOOP;
  END IF;
END $$;

DROP TRIGGER IF EXISTS trg_restaurant_cutoff_orders ON public.orders;
DROP TRIGGER IF EXISTS trg_restaurant_cutoff_order_items ON public.order_items;
DROP TRIGGER IF EXISTS trg_restaurant_cutoff_payments ON public.payments;
DROP TRIGGER IF EXISTS trg_restaurant_cutoff_external_sales
  ON public.external_sales;

UPDATE public.restaurant_cutoff_policies
SET is_enabled = false,
    updated_at = statement_timestamp()
WHERE is_enabled = true;

-- Finalization rows and receipt timestamps are retained as audit evidence.
DO $$
DECLARE
  v_bad integer;
BEGIN
  SELECT count(*) INTO v_bad
  FROM pg_trigger
  WHERE tgname LIKE 'trg_restaurant_cutoff_%'
    AND NOT tgisinternal;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_ROLLBACK_TRIGGER_REMAINS: %', v_bad;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.restaurant_cutoff_policies WHERE is_enabled = true
  ) THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_ROLLBACK_POLICY_REMAINS';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (
      SELECT 1 FROM cron.job
      WHERE jobname = 'restaurant-daily-sales-finalize-2220-hcm'
    ) THEN
      RAISE EXCEPTION 'RESTAURANT_CUTOFF_ROLLBACK_SCHEDULE_REMAINS';
    END IF;
  END IF;
END $$;

SELECT 'RESTAURANT_CUTOFF_ROLLBACK_OK' AS result;
