\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_upsert regprocedure :=
    'public.admin_upsert_printer_destination_v2(uuid,uuid,text,text,text,boolean,text,integer,text,integer)'::regprocedure;
BEGIN
  IF to_regclass('public.physical_printers') IS NULL
     OR to_regclass('public.printer_endpoints') IS NULL THEN
    RAISE EXCEPTION 'PRINTER_ENDPOINT_SCHEMA_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'printer_destinations'
      AND column_name = 'physical_printer_id'
      AND is_nullable = 'NO'
  ) THEN
    RAISE EXCEPTION 'PRINTER_DESTINATION_PHYSICAL_LINK_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.printer_destinations destination
    LEFT JOIN public.physical_printers printer
      ON printer.id = destination.physical_printer_id
     AND printer.restaurant_id = destination.restaurant_id
    WHERE printer.id IS NULL
  ) THEN
    RAISE EXCEPTION 'PRINTER_DESTINATION_BACKFILL_INCOMPLETE';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.printer_endpoints endpoint
    LEFT JOIN public.physical_printers printer
      ON printer.id = endpoint.physical_printer_id
    WHERE printer.id IS NULL
       OR endpoint.endpoint_type NOT IN ('wired', 'wireless')
       OR endpoint.port NOT BETWEEN 1 AND 65535
       OR btrim(endpoint.ip) = ''
  ) THEN
    RAISE EXCEPTION 'PRINTER_ENDPOINT_DATA_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE oid = v_upsert
      AND prosecdef
      AND 'search_path=public, auth, pg_catalog' = ANY(proconfig)
  ) OR has_function_privilege('anon', v_upsert, 'EXECUTE')
    OR NOT has_function_privilege('authenticated', v_upsert, 'EXECUTE') THEN
    RAISE EXCEPTION 'PRINTER_ENDPOINT_FUNCTION_SECURITY_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.printer_destinations'::regclass
      AND tgname = 'sync_legacy_printer_destination_endpoint'
      AND NOT tgisinternal
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.printer_destinations'::regclass
      AND tgname = 'cleanup_orphaned_physical_printer'
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'PRINTER_ENDPOINT_TRIGGER_MISSING';
  END IF;

  IF has_table_privilege('anon', 'public.physical_printers', 'SELECT')
     OR has_table_privilege('anon', 'public.printer_endpoints', 'SELECT')
     OR NOT has_table_privilege(
       'authenticated', 'public.physical_printers', 'SELECT'
     )
     OR NOT has_table_privilege(
       'authenticated', 'public.printer_endpoints', 'SELECT'
     ) THEN
    RAISE EXCEPTION 'PRINTER_ENDPOINT_TABLE_PRIVILEGE_INVALID';
  END IF;
END
$verify$;

SELECT 'PRINTER_NETWORK_ENDPOINT_VERIFY_OK' AS result;
