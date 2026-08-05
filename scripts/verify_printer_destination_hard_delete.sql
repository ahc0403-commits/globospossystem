DO $verify$
DECLARE
  v_delete_action "char";
  v_definition text;
BEGIN
  SELECT constraint_row.confdeltype
  INTO v_delete_action
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid = 'public.print_jobs'::regclass
    AND constraint_row.conname = 'print_jobs_destination_id_fkey';

  IF v_delete_action IS DISTINCT FROM 'n'::"char" THEN
    RAISE EXCEPTION 'PRINTER_HARD_DELETE_SET_NULL_MISSING';
  END IF;

  IF to_regclass('public.print_jobs_destination_id_idx') IS NULL THEN
    RAISE EXCEPTION 'PRINTER_HARD_DELETE_INDEX_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.admin_delete_printer_destination(uuid,uuid)'::regprocedure
  ) INTO v_definition;

  IF position('DELETE FROM public.printer_destinations' IN v_definition) = 0
     OR position('hard_deleted' IN v_definition) = 0
     OR position('PRINTER_DESTINATION_DELETED' IN v_definition) = 0
     OR position('SET is_active = false' IN v_definition) > 0 THEN
    RAISE EXCEPTION 'PRINTER_HARD_DELETE_RPC_INVALID';
  END IF;
END;
$verify$;

SELECT 'Printer destination hard-delete verification passed' AS result;
