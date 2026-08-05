BEGIN;

-- Printer configurations are operational records. Removing one cancels its
-- unfinished queue entries while preserving print history with a null
-- destination reference.
CREATE INDEX IF NOT EXISTS print_jobs_destination_id_idx
  ON public.print_jobs (destination_id)
  WHERE destination_id IS NOT NULL;

DO $migration$
DECLARE
  v_constraint_name text;
BEGIN
  SELECT constraint_row.conname
  INTO v_constraint_name
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid = 'public.print_jobs'::regclass
    AND constraint_row.contype = 'f'
    AND constraint_row.confrelid = 'public.printer_destinations'::regclass
    AND constraint_row.conkey = ARRAY[
      (
        SELECT attribute.attnum
        FROM pg_attribute attribute
        WHERE attribute.attrelid = 'public.print_jobs'::regclass
          AND attribute.attname = 'destination_id'
          AND NOT attribute.attisdropped
      )
    ]::smallint[]
  LIMIT 1;

  IF v_constraint_name IS NOT NULL THEN
    EXECUTE format(
      'ALTER TABLE public.print_jobs DROP CONSTRAINT %I',
      v_constraint_name
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint constraint_row
    WHERE constraint_row.conrelid = 'public.print_jobs'::regclass
      AND constraint_row.conname = 'print_jobs_destination_id_fkey'
  ) THEN
    ALTER TABLE public.print_jobs
      ADD CONSTRAINT print_jobs_destination_id_fkey
      FOREIGN KEY (destination_id)
      REFERENCES public.printer_destinations(id)
      ON DELETE SET NULL;
  END IF;
END;
$migration$;

CREATE OR REPLACE FUNCTION public.admin_delete_printer_destination(
  p_store_id uuid,
  p_destination_id uuid
) RETURNS public.printer_destinations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_existing public.printer_destinations%ROWTYPE;
  v_deleted public.printer_destinations%ROWTYPE;
  v_deleted_print_job_count integer := 0;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'PRINTER_STORE_REQUIRED';
  END IF;

  IF p_destination_id IS NULL THEN
    RAISE EXCEPTION 'PRINTER_DESTINATION_REQUIRED';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  SELECT *
  INTO v_existing
  FROM public.printer_destinations
  WHERE id = p_destination_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRINTER_DESTINATION_NOT_FOUND';
  END IF;

  IF v_existing.restaurant_id IS DISTINCT FROM p_store_id THEN
    RAISE EXCEPTION 'PRINTER_DESTINATION_STORE_MISMATCH';
  END IF;

  SELECT count(*)::integer
  INTO v_deleted_print_job_count
  FROM public.print_jobs
  WHERE destination_id = p_destination_id;

  UPDATE public.print_jobs
  SET
    status = 'cancelled',
    last_error = 'PRINTER_DESTINATION_DELETED',
    updated_at = now()
  WHERE destination_id = p_destination_id
    AND status IN ('pending', 'printing', 'failed');

  DELETE FROM public.printer_destinations
  WHERE id = p_destination_id
  RETURNING * INTO v_deleted;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_delete_printer_destination',
    'printer_destinations',
    v_deleted.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'name', v_deleted.name,
      'ip', v_deleted.ip,
      'port', v_deleted.port,
      'purpose', v_deleted.purpose,
      'floor_label', v_deleted.floor_label,
      'hard_deleted', true,
      'retained_print_job_count', v_deleted_print_job_count,
      'deleted_at_utc', now()
    )
  );

  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_delete_printer_destination(uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_printer_destination(uuid, uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.admin_delete_printer_destination(uuid, uuid) IS
  'Admin-only permanent deletion of one store-scoped printer destination. Unfinished jobs are cancelled, print history is retained, and the deletion summary is stored in audit_logs.';

COMMIT;
