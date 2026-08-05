DO $preflight$
BEGIN
  IF to_regclass('public.printer_destinations') IS NULL
     OR to_regclass('public.print_jobs') IS NULL THEN
    RAISE EXCEPTION 'PRINTER_HARD_DELETE_TABLES_MISSING';
  END IF;

  IF to_regprocedure(
    'public.admin_delete_printer_destination(uuid,uuid)'
  ) IS NULL THEN
    RAISE EXCEPTION 'PRINTER_HARD_DELETE_RPC_MISSING';
  END IF;
END;
$preflight$;

SELECT 'Printer destination hard-delete preflight passed' AS result;
