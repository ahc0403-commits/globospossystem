-- Route admin printer destination tests through the same print_jobs queue that
-- the native print station processes for order tickets.

BEGIN;

ALTER TABLE public.print_jobs
  ALTER COLUMN order_id DROP NOT NULL;

COMMENT ON COLUMN public.print_jobs.order_id IS
  'Order id for operational tickets; NULL only for printer destination test jobs.';

CREATE OR REPLACE FUNCTION public.admin_enqueue_printer_test_job(
  p_store_id uuid,
  p_destination_id uuid
) RETURNS public.print_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_destination public.printer_destinations%ROWTYPE;
  v_job public.print_jobs%ROWTYPE;
  v_ticket text;
  v_floor_label text;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'PRINTER_STORE_REQUIRED';
  END IF;

  IF p_destination_id IS NULL THEN
    RAISE EXCEPTION 'PRINTER_DESTINATION_REQUIRED';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  SELECT *
  INTO v_destination
  FROM public.printer_destinations
  WHERE id = p_destination_id
    AND restaurant_id = p_store_id
    AND is_active = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRINTER_DESTINATION_NOT_FOUND';
  END IF;

  v_ticket := v_destination.purpose;
  v_floor_label := COALESCE(NULLIF(v_destination.floor_label, ''), 'TEST');

  INSERT INTO public.print_jobs (
    restaurant_id,
    order_id,
    copy_type,
    batch_no,
    destination_id,
    payload,
    status,
    last_error
  )
  VALUES (
    p_store_id,
    NULL,
    v_ticket,
    1,
    v_destination.id,
    jsonb_build_object(
      'ticket', v_ticket,
      'floor_label', v_floor_label,
      'table_number', v_destination.name,
      'ticket_code', 'TEST',
      'batch_no', 1,
      'printed_reason', 'test_print',
      'at', to_char(now() AT TIME ZONE 'Asia/Ho_Chi_Minh', 'YYYY-MM-DD"T"HH24:MI:SS"+07:00"'),
      'items', jsonb_build_array(
        jsonb_build_object(
          'label', 'Printer route test',
          'qty', 1,
          'notes', NULL,
          'supplemental', false
        )
      ),
      'order_notes', 'Print destination test'
    ),
    'pending',
    NULL
  )
  RETURNING * INTO v_job;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_enqueue_printer_test_job',
    'print_jobs',
    v_job.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'destination_id', v_destination.id,
      'purpose', v_destination.purpose,
      'updated_at_utc', now()
    )
  );

  RETURN v_job;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_enqueue_printer_test_job(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_enqueue_printer_test_job(uuid, uuid)
  TO authenticated, service_role;

COMMIT;
