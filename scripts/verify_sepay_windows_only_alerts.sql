DO $$
DECLARE
  v_upsert_definition text;
  v_enqueue_definition text;
  v_non_windows_enabled bigint;
  v_dispatcher_jobs bigint := 0;
BEGIN
  SELECT pg_get_functiondef(
    'public.upsert_sepay_alert_device(uuid,text,text,text,text,text)'::regprocedure
  ) INTO v_upsert_definition;
  SELECT pg_get_functiondef(
    'public.enqueue_sepay_alert_deliveries()'::regprocedure
  ) INTO v_enqueue_definition;

  SELECT count(*)
  INTO v_non_windows_enabled
  FROM public.sepay_alert_devices
  WHERE is_enabled = true
    AND (platform <> 'windows' OR push_provider <> 'polling');

  IF to_regclass('cron.job') IS NOT NULL THEN
    SELECT count(*)
    INTO v_dispatcher_jobs
    FROM cron.job
    WHERE jobname = 'sepay-alert-dispatcher-every-minute';
  END IF;

  IF v_non_windows_enabled <> 0
     OR position('p_platform <> ''windows''' IN v_upsert_definition) = 0
     OR position('p_push_provider <> ''polling''' IN v_upsert_definition) = 0
     OR position('device.platform = ''windows''' IN v_enqueue_definition) = 0
     OR position('device.push_provider = ''polling''' IN v_enqueue_definition) = 0
     OR v_dispatcher_jobs <> 0 THEN
    RAISE EXCEPTION 'SEPAY_WINDOWS_ONLY_ALERTS_VERIFY_FAILED';
  END IF;
END
$$;
