BEGIN;

-- production-gate: self-verifying

ALTER TABLE public.printer_endpoints
  DROP CONSTRAINT IF EXISTS printer_endpoints_endpoint_type_check;
ALTER TABLE public.printer_endpoints
  ADD CONSTRAINT printer_endpoints_endpoint_type_check
  CHECK (endpoint_type IN ('usb', 'wired', 'wireless'));

ALTER TABLE public.printer_endpoints
  ALTER COLUMN ip DROP NOT NULL;
ALTER TABLE public.printer_endpoints
  ADD COLUMN IF NOT EXISTS device_name text;

ALTER TABLE public.printer_endpoints
  DROP CONSTRAINT IF EXISTS printer_endpoints_ip_present;
ALTER TABLE public.printer_endpoints
  DROP CONSTRAINT IF EXISTS printer_endpoints_ipv4_valid;
ALTER TABLE public.printer_endpoints
  DROP CONSTRAINT IF EXISTS printer_endpoints_unique;
ALTER TABLE public.printer_endpoints
  DROP CONSTRAINT IF EXISTS printer_endpoints_address_valid;
ALTER TABLE public.printer_endpoints
  ADD CONSTRAINT printer_endpoints_address_valid CHECK (
    (
      endpoint_type IN ('wired', 'wireless')
      AND NULLIF(btrim(ip), '') IS NOT NULL
      AND device_name IS NULL
      AND btrim(ip) ~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
      AND split_part(btrim(ip), '.', 1)::integer BETWEEN 0 AND 255
      AND split_part(btrim(ip), '.', 2)::integer BETWEEN 0 AND 255
      AND split_part(btrim(ip), '.', 3)::integer BETWEEN 0 AND 255
      AND split_part(btrim(ip), '.', 4)::integer BETWEEN 0 AND 255
    )
    OR (
      endpoint_type = 'usb'
      AND ip IS NULL
      AND NULLIF(btrim(device_name), '') IS NOT NULL
    )
  );

CREATE UNIQUE INDEX IF NOT EXISTS printer_endpoints_network_unique
  ON public.printer_endpoints (physical_printer_id, endpoint_type, ip, port)
  WHERE endpoint_type IN ('wired', 'wireless');
CREATE UNIQUE INDEX IF NOT EXISTS printer_endpoints_usb_unique
  ON public.printer_endpoints (physical_printer_id, device_name)
  WHERE endpoint_type = 'usb';

CREATE OR REPLACE FUNCTION public.sync_legacy_printer_destination_endpoint()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_physical_printer_id uuid;
BEGIN
  v_physical_printer_id := NEW.physical_printer_id;
  IF v_physical_printer_id IS NULL THEN
    INSERT INTO public.physical_printers (restaurant_id, name, is_active)
    VALUES (NEW.restaurant_id, NEW.name, NEW.is_active)
    RETURNING id INTO v_physical_printer_id;
    NEW.physical_printer_id := v_physical_printer_id;
  ELSE
    UPDATE public.physical_printers
    SET name = NEW.name,
        is_active = NEW.is_active,
        updated_at = now()
    WHERE id = v_physical_printer_id
      AND restaurant_id = NEW.restaurant_id;
  END IF;

  IF TG_OP = 'UPDATE'
     AND (OLD.ip IS DISTINCT FROM NEW.ip OR OLD.port IS DISTINCT FROM NEW.port)
  THEN
    UPDATE public.printer_endpoints
    SET is_active = false,
        updated_at = now()
    WHERE physical_printer_id = v_physical_printer_id
      AND endpoint_type = 'wireless';
  END IF;

  IF NULLIF(btrim(NEW.ip), '') IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.printer_endpoints (
    physical_printer_id, endpoint_type, ip, port, priority, is_active
  )
  VALUES (
    v_physical_printer_id, 'wireless', btrim(NEW.ip), NEW.port, 100,
    NEW.is_active
  )
  ON CONFLICT (physical_printer_id, endpoint_type, ip, port)
    WHERE endpoint_type IN ('wired', 'wireless')
  DO UPDATE SET
    is_active = EXCLUDED.is_active,
    updated_at = now();

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_upsert_printer_destination_v3(
  p_store_id uuid,
  p_destination_id uuid DEFAULT NULL,
  p_name text DEFAULT NULL,
  p_purpose text DEFAULT 'kitchen',
  p_floor_label text DEFAULT NULL,
  p_is_active boolean DEFAULT true,
  p_wired_ip text DEFAULT NULL,
  p_wired_port integer DEFAULT 9100,
  p_wireless_ip text DEFAULT NULL,
  p_wireless_port integer DEFAULT 9100,
  p_usb_printer_name text DEFAULT NULL
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
  v_usb_printer_name text :=
    NULLIF(btrim(COALESCE(p_usb_printer_name, '')), '');
  v_legacy_ip text;
  v_legacy_port integer;
BEGIN
  PERFORM public.require_printer_configuration_actor(p_store_id);

  IF v_name IS NULL THEN RAISE EXCEPTION 'PRINTER_NAME_REQUIRED'; END IF;
  IF v_wired_ip IS NULL
     AND v_wireless_ip IS NULL
     AND v_usb_printer_name IS NULL THEN
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

  -- Legacy destination columns remain populated for old clients. USB-capable
  -- print stations always read the typed endpoint rows below.
  v_legacy_ip := COALESCE(v_wireless_ip, v_wired_ip, '127.0.0.1');
  v_legacy_port := CASE
    WHEN v_wireless_ip IS NOT NULL THEN p_wireless_port
    WHEN v_wired_ip IS NOT NULL THEN p_wired_port
    ELSE 9100
  END;

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

  IF v_usb_printer_name IS NOT NULL THEN
    INSERT INTO public.printer_endpoints (
      physical_printer_id, endpoint_type, device_name, port, priority, is_active
    ) VALUES (
      v_physical_printer_id, 'usb', v_usb_printer_name, 9100, 5, true
    );
  END IF;
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
    auth.uid(), 'admin_upsert_printer_destination_v3',
    'printer_destinations', v_destination.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'physical_printer_id', v_physical_printer_id,
      'has_usb_endpoint', v_usb_printer_name IS NOT NULL,
      'has_wired_endpoint', v_wired_ip IS NOT NULL,
      'has_wireless_endpoint', v_wireless_ip IS NOT NULL,
      'purpose', v_purpose,
      'floor_label', v_floor_label
    )
  );

  RETURN v_destination;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_upsert_printer_destination_v3(
  uuid, uuid, text, text, text, boolean, text, integer, text, integer, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_upsert_printer_destination_v3(
  uuid, uuid, text, text, text, boolean, text, integer, text, integer, text
) TO authenticated, service_role;

DO $$
DECLARE
  v_endpoint_constraint text;
  v_upsert_definition text;
BEGIN
  SELECT pg_catalog.pg_get_constraintdef(constraint_row.oid)
  INTO v_endpoint_constraint
  FROM pg_catalog.pg_constraint constraint_row
  WHERE constraint_row.conrelid = 'public.printer_endpoints'::regclass
    AND constraint_row.conname = 'printer_endpoints_endpoint_type_check';

  IF v_endpoint_constraint NOT LIKE '%usb%' THEN
    RAISE EXCEPTION 'USB_PRINTER_ENDPOINT_CONSTRAINT_VERIFICATION_FAILED';
  END IF;

  SELECT pg_catalog.pg_get_functiondef(
    'public.admin_upsert_printer_destination_v3(uuid,uuid,text,text,text,boolean,text,integer,text,integer,text)'::regprocedure
  ) INTO v_upsert_definition;

  IF v_upsert_definition NOT LIKE '%p_usb_printer_name%'
     OR v_upsert_definition NOT LIKE '%has_usb_endpoint%' THEN
    RAISE EXCEPTION 'USB_PRINTER_UPSERT_VERIFICATION_FAILED';
  END IF;
END;
$$;

COMMIT;
