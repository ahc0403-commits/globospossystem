-- Deliberry retired by the owner on 2026-10-05. Historical rows stay readable.
BEGIN;

CREATE OR REPLACE FUNCTION public.reject_retired_deliberry_writes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  -- external_sales is shared infrastructure: block only Deliberry records.
  IF TG_TABLE_NAME = 'external_sales' THEN
    IF TG_OP = 'TRUNCATE' THEN
      IF EXISTS (SELECT 1 FROM public.external_sales
                 WHERE lower(btrim(source_system)) = 'deliberry') THEN
        RAISE EXCEPTION 'DELIBERRY_INTEGRATION_RETIRED';
      END IF;
      RETURN NULL;
    END IF;
    IF TG_OP <> 'INSERT' AND
       lower(btrim(to_jsonb(OLD)->>'source_system')) = 'deliberry' THEN
      RAISE EXCEPTION 'DELIBERRY_INTEGRATION_RETIRED';
    END IF;
    IF TG_OP <> 'DELETE' AND
       lower(btrim(to_jsonb(NEW)->>'source_system')) = 'deliberry' THEN
      RAISE EXCEPTION 'DELIBERRY_INTEGRATION_RETIRED';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'DELIBERRY_INTEGRATION_RETIRED';
END;
$$;
REVOKE ALL ON FUNCTION public.reject_retired_deliberry_writes()
  FROM PUBLIC, anon, authenticated, service_role;

DO $retire_tables$
DECLARE table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'external_sales', 'delivery_settlements', 'delivery_settlement_items',
    'deliberry_operational_orders', 'deliberry_operational_order_events'
  ] LOOP
    IF to_regclass('public.' || table_name) IS NULL THEN CONTINUE; END IF;
    EXECUTE format('DROP TRIGGER IF EXISTS trg_deliberry_retired_write ON public.%I', table_name);
    EXECUTE format('CREATE TRIGGER trg_deliberry_retired_write BEFORE INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.reject_retired_deliberry_writes()', table_name);
    EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_deliberry_retired_write', table_name);
    EXECUTE format('DROP TRIGGER IF EXISTS trg_deliberry_retired_truncate ON public.%I', table_name);
    EXECUTE format('CREATE TRIGGER trg_deliberry_retired_truncate BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION public.reject_retired_deliberry_writes()', table_name);
    EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_deliberry_retired_truncate', table_name);
    IF table_name <> 'external_sales' THEN
      EXECUTE format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.%I FROM PUBLIC, anon, authenticated, service_role', table_name);
    END IF;
  END LOOP;
END;
$retire_tables$;

-- Read-only history/reconciliation functions and SELECT grants remain intact.
DO $retire_rpcs$
DECLARE rpc record;
BEGIN
  FOR rpc IN
    SELECT p.oid::regprocedure AS signature FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = ANY(ARRAY[
      'apply_deliberry_operational_order_event',
      'receive_deliberry_operational_order',
      'accept_deliberry_operational_order',
      'reject_deliberry_operational_order',
      'mark_deliberry_operational_order_ready',
      'get_deliberry_operational_order_events_for_retry',
      'mark_deliberry_operational_event_processed',
      'mark_deliberry_operational_event_failed',
      'reprocess_deliberry_operational_order_event',
      'confirm_delivery_settlement_received'
    ])
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated, service_role', rpc.signature);
  END LOOP;
END;
$retire_rpcs$;

-- Also close schedules created outside repository migrations. Do not print commands.
DO $retire_cron$
DECLARE job record;
BEGIN
  IF to_regclass('cron.job') IS NULL THEN RETURN; END IF;
  FOR job IN
    SELECT jobid FROM cron.job
    WHERE concat_ws(' ', jobname, command) ~* 'deliberry|generate[-_]settlement|generate_delivery_settlement'
  LOOP
    PERFORM cron.unschedule(job.jobid);
  END LOOP;
END;
$retire_cron$;

COMMENT ON FUNCTION public.reject_retired_deliberry_writes() IS
  'Deliberry permanently retired on 2026-10-05 by owner decision; history is read-only. Reactivation requires a new owner decision and migration.';

COMMIT;
