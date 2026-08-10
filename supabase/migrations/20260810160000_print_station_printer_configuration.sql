BEGIN;

-- Administrators retain their existing printer configuration access. A
-- dedicated print-station identity may configure only its assigned store.
CREATE OR REPLACE FUNCTION public.require_printer_configuration_actor(
  p_store_id uuid
) RETURNS public.users
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'PRINTER_STORE_REQUIRED';
  END IF;

  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = true
  LIMIT 1;

  IF v_actor.role = 'print_station'
     AND v_actor.account_type = 'device_print_station'
     AND EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) scoped(store_id)
       WHERE scoped.store_id = p_store_id
     )
  THEN
    RETURN v_actor;
  END IF;

  RETURN public.require_admin_actor_for_restaurant(p_store_id);
END;
$$;

REVOKE ALL ON FUNCTION public.require_printer_configuration_actor(uuid)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.require_printer_configuration_actor(uuid) IS
  'Authorizes existing admin actors and store-scoped device_print_station actors to configure printers for one accessible store.';

CREATE OR REPLACE FUNCTION public.admin_upsert_printer_destination_v2(
  p_store_id uuid,
  p_destination_id uuid DEFAULT NULL,
  p_name text DEFAULT NULL,
  p_purpose text DEFAULT 'kitchen',
  p_floor_label text DEFAULT NULL,
  p_is_active boolean DEFAULT true,
  p_wired_ip text DEFAULT NULL,
  p_wired_port integer DEFAULT 9100,
  p_wireless_ip text DEFAULT NULL,
  p_wireless_port integer DEFAULT 9100
) RETURNS public.printer_destinations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_destination public.printer_destinations%ROWTYPE;
  v_physical_printer_id uuid;
  v_name text := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_purpose text := lower(NULLIF(btrim(COALESCE(p_purpose, '')), ''));
  v_floor_label text := NULLIF(upper(btrim(COALESCE(p_floor_label, ''))), '');
  v_wired_ip text := NULLIF(btrim(COALESCE(p_wired_ip, '')), '');
  v_wireless_ip text := NULLIF(btrim(COALESCE(p_wireless_ip, '')), '');
  v_legacy_ip text;
  v_legacy_port integer;
BEGIN
  PERFORM public.require_printer_configuration_actor(p_store_id);

  IF v_name IS NULL THEN RAISE EXCEPTION 'PRINTER_NAME_REQUIRED'; END IF;
  IF v_wired_ip IS NULL AND v_wireless_ip IS NULL THEN
    RAISE EXCEPTION 'PRINTER_ENDPOINT_REQUIRED';
  END IF;
  IF v_purpose NOT IN ('kitchen', 'floor', 'tray', 'receipt') THEN
    RAISE EXCEPTION 'PRINTER_PURPOSE_INVALID';
  END IF;
  IF v_purpose = 'floor' AND v_floor_label IS NULL THEN
    RAISE EXCEPTION 'PRINTER_FLOOR_LABEL_REQUIRED';
  END IF;
  IF (v_wired_ip IS NOT NULL
      AND (p_wired_port IS NULL OR p_wired_port NOT BETWEEN 1 AND 65535))
     OR (v_wireless_ip IS NOT NULL
         AND (p_wireless_port IS NULL
              OR p_wireless_port NOT BETWEEN 1 AND 65535)) THEN
    RAISE EXCEPTION 'PRINTER_PORT_INVALID';
  END IF;
  IF v_purpose <> 'floor' THEN v_floor_label := NULL; END IF;

  v_legacy_ip := COALESCE(v_wireless_ip, v_wired_ip);
  v_legacy_port := CASE
    WHEN v_wireless_ip IS NOT NULL THEN p_wireless_port ELSE p_wired_port END;

  IF p_destination_id IS NULL THEN
    INSERT INTO public.physical_printers (restaurant_id, name, is_active)
    VALUES (p_store_id, v_name, COALESCE(p_is_active, true))
    RETURNING id INTO v_physical_printer_id;

    INSERT INTO public.printer_destinations (
      restaurant_id, name, ip, port, purpose, floor_label, is_active,
      physical_printer_id
    ) VALUES (
      p_store_id, v_name, v_legacy_ip, v_legacy_port, v_purpose,
      v_floor_label, COALESCE(p_is_active, true), v_physical_printer_id
    ) RETURNING * INTO v_destination;
  ELSE
    SELECT * INTO v_destination
    FROM public.printer_destinations
    WHERE id = p_destination_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'PRINTER_DESTINATION_NOT_FOUND'; END IF;
    IF v_destination.restaurant_id IS DISTINCT FROM p_store_id THEN
      RAISE EXCEPTION 'PRINTER_DESTINATION_STORE_MISMATCH';
    END IF;
    v_physical_printer_id := v_destination.physical_printer_id;

    UPDATE public.printer_destinations
    SET name = v_name,
        ip = v_legacy_ip,
        port = v_legacy_port,
        purpose = v_purpose,
        floor_label = v_floor_label,
        is_active = COALESCE(p_is_active, true),
        updated_at = now()
    WHERE id = p_destination_id
    RETURNING * INTO v_destination;
  END IF;

  UPDATE public.physical_printers
  SET name = v_name,
      is_active = COALESCE(p_is_active, true),
      updated_at = now()
  WHERE id = v_physical_printer_id;

  DELETE FROM public.printer_endpoints
  WHERE physical_printer_id = v_physical_printer_id;

  IF v_wired_ip IS NOT NULL THEN
    INSERT INTO public.printer_endpoints (
      physical_printer_id, endpoint_type, ip, port, priority, is_active
    ) VALUES (
      v_physical_printer_id, 'wired', v_wired_ip, p_wired_port, 10, true
    );
  END IF;
  IF v_wireless_ip IS NOT NULL THEN
    INSERT INTO public.printer_endpoints (
      physical_printer_id, endpoint_type, ip, port, priority, is_active
    ) VALUES (
      v_physical_printer_id, 'wireless', v_wireless_ip,
      p_wireless_port, 20, true
    );
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'admin_upsert_printer_destination_v2',
    'printer_destinations', v_destination.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'physical_printer_id', v_physical_printer_id,
      'has_wired_endpoint', v_wired_ip IS NOT NULL,
      'has_wireless_endpoint', v_wireless_ip IS NOT NULL,
      'purpose', v_purpose,
      'floor_label', v_floor_label
    )
  );

  RETURN v_destination;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_printer_destination(
  p_store_id uuid,
  p_destination_id uuid
) RETURNS public.printer_destinations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_existing public.printer_destinations%ROWTYPE;
  v_deleted public.printer_destinations%ROWTYPE;
  v_deleted_print_job_count integer := 0;
BEGIN
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'PRINTER_STORE_REQUIRED'; END IF;
  IF p_destination_id IS NULL THEN
    RAISE EXCEPTION 'PRINTER_DESTINATION_REQUIRED';
  END IF;

  PERFORM public.require_printer_configuration_actor(p_store_id);

  SELECT * INTO v_existing
  FROM public.printer_destinations
  WHERE id = p_destination_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PRINTER_DESTINATION_NOT_FOUND'; END IF;
  IF v_existing.restaurant_id IS DISTINCT FROM p_store_id THEN
    RAISE EXCEPTION 'PRINTER_DESTINATION_STORE_MISMATCH';
  END IF;

  SELECT count(*)::integer INTO v_deleted_print_job_count
  FROM public.print_jobs
  WHERE destination_id = p_destination_id;

  UPDATE public.print_jobs
  SET status = 'cancelled',
      last_error = 'PRINTER_DESTINATION_DELETED',
      updated_at = now()
  WHERE destination_id = p_destination_id
    AND status IN ('pending', 'printing', 'failed');

  DELETE FROM public.printer_destinations
  WHERE id = p_destination_id
  RETURNING * INTO v_deleted;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'admin_delete_printer_destination',
    'printer_destinations', v_deleted.id,
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

CREATE OR REPLACE FUNCTION public.admin_enqueue_printer_test_job(
  p_store_id uuid,
  p_destination_id uuid
) RETURNS public.print_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_destination public.printer_destinations%ROWTYPE;
  v_job public.print_jobs%ROWTYPE;
  v_ticket text;
  v_floor_label text;
BEGIN
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'PRINTER_STORE_REQUIRED'; END IF;
  IF p_destination_id IS NULL THEN
    RAISE EXCEPTION 'PRINTER_DESTINATION_REQUIRED';
  END IF;

  PERFORM public.require_printer_configuration_actor(p_store_id);

  SELECT * INTO v_destination
  FROM public.printer_destinations
  WHERE id = p_destination_id
    AND restaurant_id = p_store_id
    AND is_active = true
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PRINTER_DESTINATION_NOT_FOUND'; END IF;

  v_ticket := v_destination.purpose;
  v_floor_label := COALESCE(NULLIF(v_destination.floor_label, ''), 'TEST');

  INSERT INTO public.print_jobs (
    restaurant_id, order_id, copy_type, batch_no, destination_id,
    payload, status, last_error
  ) VALUES (
    p_store_id, NULL, v_ticket, 1, v_destination.id,
    jsonb_build_object(
      'ticket', v_ticket,
      'floor_label', v_floor_label,
      'table_number', v_destination.name,
      'ticket_code', 'TEST',
      'batch_no', 1,
      'printed_reason', 'test_print',
      'at', to_char(
        now() AT TIME ZONE 'Asia/Ho_Chi_Minh',
        'YYYY-MM-DD"T"HH24:MI:SS"+07:00"'
      ),
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
    'pending', NULL
  ) RETURNING * INTO v_job;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'admin_enqueue_printer_test_job',
    'print_jobs', v_job.id,
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

REVOKE ALL ON FUNCTION public.admin_upsert_printer_destination_v2(
  uuid, uuid, text, text, text, boolean, text, integer, text, integer
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_delete_printer_destination(uuid, uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_enqueue_printer_test_job(uuid, uuid)
  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.admin_upsert_printer_destination_v2(
  uuid, uuid, text, text, text, boolean, text, integer, text, integer
) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_printer_destination(uuid, uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_enqueue_printer_test_job(uuid, uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.admin_delete_printer_destination(uuid, uuid) IS
  'Admin or same-store print-station permanent deletion. Unfinished jobs are cancelled, print history is retained, and the deletion is audited.';

COMMIT;
