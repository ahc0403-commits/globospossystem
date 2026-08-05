DO $verify$
DECLARE
  v_definition text;
  v_security_definer boolean;
  v_trigger_count integer;
BEGIN
  IF to_regclass('public.pos_live_events') IS NULL
     OR to_regprocedure('public.emit_pos_live_event()') IS NULL THEN
    RAISE EXCEPTION 'POS_LIVE_EVENTS_VERIFY_OBJECT_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'pos_live_events'
      AND c.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'POS_LIVE_EVENTS_VERIFY_RLS_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'pos_live_events'
  ) THEN
    RAISE EXCEPTION 'POS_LIVE_EVENTS_VERIFY_REALTIME_PUBLICATION_MISSING';
  END IF;

  SELECT pg_get_functiondef(p.oid), p.prosecdef
  INTO v_definition, v_security_definer
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.oid = 'public.emit_pos_live_event()'::regprocedure;

  IF NOT v_security_definer
     OR v_definition NOT LIKE '%pos_live_events%'
     OR v_definition NOT LIKE '%restaurant_id%'
     OR v_definition NOT LIKE '%TG_OP%' THEN
    RAISE EXCEPTION 'POS_LIVE_EVENTS_VERIFY_EMITTER_INCOMPLETE';
  END IF;

  SELECT count(*) INTO v_trigger_count
  FROM pg_trigger t
  JOIN pg_proc p ON p.oid = t.tgfoid
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE NOT t.tgisinternal
    AND t.tgname = 'pos_live_event_trigger'
    AND n.nspname = 'public'
    AND p.proname = 'emit_pos_live_event';

  IF v_trigger_count < 70 THEN
    RAISE EXCEPTION 'POS_LIVE_EVENTS_VERIFY_DOMAIN_TRIGGERS_INCOMPLETE:%', v_trigger_count;
  END IF;

  IF NOT has_table_privilege('authenticated', 'public.pos_live_events', 'SELECT')
     OR NOT has_table_privilege('anon', 'public.pos_live_events', 'SELECT')
     OR has_table_privilege('authenticated', 'public.pos_live_events', 'INSERT') THEN
    RAISE EXCEPTION 'POS_LIVE_EVENTS_VERIFY_GRANTS_INCORRECT';
  END IF;
END;
$verify$;
