DO $verify$
DECLARE
  v_alert_definition text;
  v_ingest_definition text;
  v_security_definer boolean;
BEGIN
  IF to_regclass('public.sepay_bank_accounts') IS NULL
     OR to_regclass('public.sepay_transactions') IS NULL
     OR to_regprocedure('public.ingest_sepay_transaction(bigint,text,text,text,text,bigint,text,text,timestamp with time zone,jsonb)') IS NULL
     OR to_regprocedure('public.get_latest_sepay_payment_alert(uuid)') IS NULL THEN
    RAISE EXCEPTION 'SEPAY_ALERTS_VERIFY_OBJECT_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN ('sepay_bank_accounts', 'sepay_transactions')
      AND NOT c.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'SEPAY_ALERTS_VERIFY_RLS_MISSING';
  END IF;

  SELECT pg_get_functiondef(p.oid), p.prosecdef
  INTO v_alert_definition, v_security_definer
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.oid = 'public.get_latest_sepay_payment_alert(uuid)'::regprocedure;

  IF NOT v_security_definer
     OR v_alert_definition NOT LIKE '%AUTH_REQUIRED%'
     OR v_alert_definition NOT LIKE '%STORE_ACCESS_DENIED%'
     OR v_alert_definition LIKE '%raw_payload%' THEN
    RAISE EXCEPTION 'SEPAY_ALERTS_VERIFY_ALERT_SCOPE_INCORRECT';
  END IF;

  SELECT pg_get_functiondef(p.oid)
  INTO v_ingest_definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.oid = 'public.ingest_sepay_transaction(bigint,text,text,text,text,bigint,text,text,timestamp with time zone,jsonb)'::regprocedure;

  IF v_ingest_definition NOT LIKE '%ON CONFLICT (sepay_transaction_id) DO NOTHING%'
     OR v_ingest_definition NOT LIKE '%SEPAY_TRANSACTION_INVALID%' THEN
    RAISE EXCEPTION 'SEPAY_ALERTS_VERIFY_INGEST_INCOMPLETE';
  END IF;

  IF NOT has_function_privilege(
    'authenticated', 'public.get_latest_sepay_payment_alert(uuid)', 'EXECUTE'
  ) OR has_function_privilege(
    'anon', 'public.get_latest_sepay_payment_alert(uuid)', 'EXECUTE'
  ) OR NOT has_function_privilege(
    'service_role',
    'public.ingest_sepay_transaction(bigint,text,text,text,text,bigint,text,text,timestamp with time zone,jsonb)',
    'EXECUTE'
  ) OR has_function_privilege(
    'authenticated',
    'public.ingest_sepay_transaction(bigint,text,text,text,text,bigint,text,text,timestamp with time zone,jsonb)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'SEPAY_ALERTS_VERIFY_GRANTS_INCORRECT';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'sepay_transactions'
      AND t.tgname = 'pos_live_event_trigger'
      AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'SEPAY_ALERTS_VERIFY_LIVE_EVENT_TRIGGER_MISSING';
  END IF;
END;
$verify$;
