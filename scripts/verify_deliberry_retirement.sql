DO $$
DECLARE table_name text; target_role text; rpc record;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'external_sales', 'delivery_settlements', 'delivery_settlement_items',
    'deliberry_operational_orders', 'deliberry_operational_order_events'
  ] LOOP
    IF to_regclass('public.' || table_name) IS NULL THEN CONTINUE; END IF;
    IF (SELECT count(*) FROM pg_trigger
        WHERE tgrelid = to_regclass('public.' || table_name)
          AND tgname IN ('trg_deliberry_retired_write', 'trg_deliberry_retired_truncate')
          AND tgenabled = 'A'
          AND tgfoid = 'public.reject_retired_deliberry_writes()'::regprocedure) <> 2 THEN
      RAISE EXCEPTION 'DELIBERRY_RETIREMENT_GUARD_MISSING:%', table_name;
    END IF;
    IF table_name <> 'external_sales' THEN
      FOREACH target_role IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
        IF has_table_privilege(target_role, 'public.' || table_name, 'INSERT,UPDATE,DELETE,TRUNCATE') THEN
          RAISE EXCEPTION 'DELIBERRY_RETIREMENT_WRITE_GRANT_REMAINS:%:%', table_name, target_role;
        END IF;
      END LOOP;
    END IF;
  END LOOP;
  FOR rpc IN
    SELECT p.oid, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname=ANY(ARRAY[
      'apply_deliberry_operational_order_event', 'receive_deliberry_operational_order',
      'accept_deliberry_operational_order', 'reject_deliberry_operational_order',
      'mark_deliberry_operational_order_ready', 'get_deliberry_operational_order_events_for_retry',
      'mark_deliberry_operational_event_processed', 'mark_deliberry_operational_event_failed',
      'reprocess_deliberry_operational_order_event', 'confirm_delivery_settlement_received'
    ])
  LOOP
    FOREACH target_role IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
      IF has_function_privilege(target_role, rpc.oid, 'EXECUTE') THEN
        RAISE EXCEPTION 'DELIBERRY_RETIREMENT_RPC_GRANT_REMAINS:%:%', rpc.proname, target_role;
      END IF;
    END LOOP;
  END LOOP;
  IF to_regclass('cron.job') IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM cron.job
      WHERE concat_ws(' ', jobname, command) ~* 'deliberry|generate[-_]settlement|generate_delivery_settlement'
    ) THEN
      RAISE EXCEPTION 'DELIBERRY_RETIREMENT_CRON_REMAINS';
    END IF;
  END IF;
END;
$$;
SELECT 'DELIBERRY_RETIREMENT_VERIFY_OK' AS result;
