DO $verify$
DECLARE
  v_upsert regprocedure := to_regprocedure(
    'public.upsert_sepay_alert_device(uuid,text,text,text,text,text)'
  );
  v_ack regprocedure := to_regprocedure(
    'public.ack_sepay_alert_delivery(uuid,text,text)'
  );
  v_enqueue regprocedure := to_regprocedure(
    'public.enqueue_sepay_alert_deliveries()'
  );
  v_claim regprocedure := to_regprocedure(
    'public.claim_sepay_alert_deliveries(integer)'
  );
  v_complete regprocedure := to_regprocedure(
    'public.complete_sepay_alert_delivery(uuid,boolean,text,text,integer)'
  );
  v_upsert_definition text;
  v_ack_definition text;
  v_enqueue_definition text;
  v_claim_definition text;
  v_all_security_definer boolean;
  v_cron_job_exists boolean;
BEGIN
  IF to_regclass('public.sepay_alert_devices') IS NULL
     OR to_regclass('public.sepay_alert_deliveries') IS NULL THEN
    RAISE EXCEPTION 'SEPAY_ALERT_LEDGER_VERIFY_FAILED: tables missing';
  END IF;

  IF NOT EXISTS (
       SELECT 1
       FROM pg_class table_row
       JOIN pg_namespace schema_row ON schema_row.oid = table_row.relnamespace
       WHERE schema_row.nspname = 'public'
         AND table_row.relname = 'sepay_alert_devices'
         AND table_row.relrowsecurity
     )
     OR NOT EXISTS (
       SELECT 1
       FROM pg_class table_row
       JOIN pg_namespace schema_row ON schema_row.oid = table_row.relnamespace
       WHERE schema_row.nspname = 'public'
         AND table_row.relname = 'sepay_alert_deliveries'
         AND table_row.relrowsecurity
     ) THEN
    RAISE EXCEPTION 'SEPAY_ALERT_LEDGER_VERIFY_FAILED: RLS disabled';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint constraint_row
    WHERE constraint_row.conrelid = 'public.sepay_alert_deliveries'::regclass
      AND constraint_row.contype = 'u'
      AND pg_get_constraintdef(constraint_row.oid) =
        'UNIQUE (transaction_id, device_id)'
  ) THEN
    RAISE EXCEPTION 'SEPAY_ALERT_LEDGER_VERIFY_FAILED: dedupe constraint missing';
  END IF;

  IF v_upsert IS NULL OR v_ack IS NULL OR v_enqueue IS NULL
     OR v_claim IS NULL OR v_complete IS NULL THEN
    RAISE EXCEPTION 'SEPAY_ALERT_LEDGER_VERIFY_FAILED: function missing';
  END IF;

  SELECT bool_and(procedure_row.prosecdef)
  INTO v_all_security_definer
  FROM pg_proc procedure_row
  WHERE procedure_row.oid IN (
    v_upsert, v_ack, v_enqueue, v_claim, v_complete
  );

  IF NOT COALESCE(v_all_security_definer, false) THEN
    RAISE EXCEPTION 'SEPAY_ALERT_LEDGER_VERIFY_FAILED: invoker function found';
  END IF;

  SELECT pg_get_functiondef(v_upsert), pg_get_functiondef(v_ack),
         pg_get_functiondef(v_enqueue), pg_get_functiondef(v_claim)
  INTO v_upsert_definition, v_ack_definition,
       v_enqueue_definition, v_claim_definition;

  IF position('user_accessible_stores(auth.uid())' IN v_upsert_definition) = 0
     OR position('device.user_id = auth.uid()' IN v_ack_definition) = 0
     OR position('NEW.transfer_type <> ''in''' IN v_enqueue_definition) = 0
     OR position('NEW.resolution_status <> ''matched''' IN v_enqueue_definition) = 0
     OR position('ON CONFLICT (transaction_id, device_id) DO NOTHING'
       IN v_enqueue_definition) = 0
     OR position('FOR UPDATE OF delivery SKIP LOCKED' IN v_claim_definition) = 0
     OR position('device.push_provider = ''fcm''' IN v_claim_definition) = 0
     OR position('delivery.updated_at <= now() - interval ''5 minutes'''
       IN v_claim_definition) = 0 THEN
    RAISE EXCEPTION 'SEPAY_ALERT_LEDGER_VERIFY_FAILED: isolation/retry mismatch';
  END IF;

  IF NOT has_function_privilege('authenticated', v_upsert, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_ack, 'EXECUTE')
     OR has_function_privilege('anon', v_upsert, 'EXECUTE')
     OR has_function_privilege('anon', v_ack, 'EXECUTE')
     OR has_function_privilege('authenticated', v_claim, 'EXECUTE')
     OR has_function_privilege('authenticated', v_complete, 'EXECUTE')
     OR has_function_privilege('anon', v_claim, 'EXECUTE')
     OR has_function_privilege('anon', v_complete, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_claim, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_complete, 'EXECUTE') THEN
    RAISE EXCEPTION 'SEPAY_ALERT_LEDGER_VERIFY_FAILED: grants mismatch';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid = 'public.sepay_transactions'::regclass
      AND trigger_row.tgname = 'sepay_alert_delivery_enqueue_trigger'
      AND NOT trigger_row.tgisinternal
      AND trigger_row.tgenabled <> 'D'
  ) THEN
    RAISE EXCEPTION 'SEPAY_ALERT_LEDGER_VERIFY_FAILED: trigger missing';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    EXECUTE $sql$
      SELECT EXISTS (
        SELECT 1 FROM cron.job
        WHERE jobname = 'sepay-alert-dispatcher-every-minute'
      )
    $sql$ INTO v_cron_job_exists;

    IF NOT v_cron_job_exists THEN
      RAISE EXCEPTION 'SEPAY_ALERT_LEDGER_VERIFY_FAILED: cron job missing';
    END IF;
  END IF;
END;
$verify$;
