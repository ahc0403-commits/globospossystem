BEGIN;

CREATE TABLE IF NOT EXISTS public.physical_printers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  name text NOT NULL,
  model text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT physical_printers_name_present CHECK (btrim(name) <> '')
);

CREATE TABLE IF NOT EXISTS public.printer_endpoints (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  physical_printer_id uuid NOT NULL
    REFERENCES public.physical_printers(id) ON DELETE CASCADE,
  endpoint_type text NOT NULL
    CHECK (endpoint_type IN ('wired', 'wireless')),
  ip text NOT NULL,
  port integer NOT NULL DEFAULT 9100,
  priority integer NOT NULL DEFAULT 100,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT printer_endpoints_ip_present CHECK (btrim(ip) <> ''),
  CONSTRAINT printer_endpoints_ipv4_valid CHECK (
    CASE
      WHEN btrim(ip) ~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' THEN
        split_part(btrim(ip), '.', 1)::integer BETWEEN 0 AND 255
        AND split_part(btrim(ip), '.', 2)::integer BETWEEN 0 AND 255
        AND split_part(btrim(ip), '.', 3)::integer BETWEEN 0 AND 255
        AND split_part(btrim(ip), '.', 4)::integer BETWEEN 0 AND 255
      ELSE false
    END
  ),
  CONSTRAINT printer_endpoints_port_range CHECK (port BETWEEN 1 AND 65535),
  CONSTRAINT printer_endpoints_priority_nonnegative CHECK (priority >= 0),
  CONSTRAINT printer_endpoints_unique
    UNIQUE (physical_printer_id, endpoint_type, ip, port)
);

CREATE INDEX IF NOT EXISTS physical_printers_store_active
  ON public.physical_printers (restaurant_id, is_active, name);

CREATE INDEX IF NOT EXISTS printer_endpoints_candidate_order
  ON public.printer_endpoints (
    physical_printer_id, is_active, priority, endpoint_type
  );

ALTER TABLE public.physical_printers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.printer_endpoints ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS physical_printers_store_read ON public.physical_printers;
CREATE POLICY physical_printers_store_read
  ON public.physical_printers
  FOR SELECT
  TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) accessible(store_id)
      WHERE accessible.store_id = physical_printers.restaurant_id
    )
  );

DROP POLICY IF EXISTS printer_endpoints_store_read ON public.printer_endpoints;
CREATE POLICY printer_endpoints_store_read
  ON public.printer_endpoints
  FOR SELECT
  TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.physical_printers printer
      JOIN public.user_accessible_stores(auth.uid()) accessible(store_id)
        ON accessible.store_id = printer.restaurant_id
      WHERE printer.id = printer_endpoints.physical_printer_id
    )
  );

REVOKE ALL ON public.physical_printers FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.printer_endpoints FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.physical_printers TO authenticated;
GRANT SELECT ON public.printer_endpoints TO authenticated;
GRANT ALL ON public.physical_printers TO service_role;
GRANT ALL ON public.printer_endpoints TO service_role;

ALTER TABLE public.printer_destinations
  ADD COLUMN IF NOT EXISTS physical_printer_id uuid
  REFERENCES public.physical_printers(id) ON DELETE RESTRICT;

CREATE TEMP TABLE printer_endpoint_backfill (
  physical_printer_id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL,
  ip text NOT NULL,
  port integer NOT NULL,
  name text NOT NULL
) ON COMMIT DROP;

INSERT INTO printer_endpoint_backfill (
  physical_printer_id, restaurant_id, ip, port, name
)
SELECT
  gen_random_uuid(),
  restaurant_id,
  btrim(ip),
  port,
  min(btrim(name))
FROM public.printer_destinations
WHERE physical_printer_id IS NULL
GROUP BY restaurant_id, btrim(ip), port;

INSERT INTO public.physical_printers (id, restaurant_id, name)
SELECT physical_printer_id, restaurant_id, name
FROM printer_endpoint_backfill
ON CONFLICT (id) DO NOTHING;

-- The pre-existing single-address workflow was the Wi-Fi printer workflow.
-- Preserve it as a wireless endpoint; wired addresses must be entered from
-- the printer's wired-network status sheet rather than inferred.
INSERT INTO public.printer_endpoints (
  physical_printer_id, endpoint_type, ip, port, priority
)
SELECT physical_printer_id, 'wireless', ip, port, 100
FROM printer_endpoint_backfill
ON CONFLICT (physical_printer_id, endpoint_type, ip, port) DO NOTHING;

UPDATE public.printer_destinations destination
SET physical_printer_id = backfill.physical_printer_id
FROM printer_endpoint_backfill backfill
WHERE destination.physical_printer_id IS NULL
  AND destination.restaurant_id = backfill.restaurant_id
  AND btrim(destination.ip) = backfill.ip
  AND destination.port = backfill.port;

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

  INSERT INTO public.printer_endpoints (
    physical_printer_id, endpoint_type, ip, port, priority, is_active
  )
  VALUES (
    v_physical_printer_id, 'wireless', btrim(NEW.ip), NEW.port, 100,
    NEW.is_active
  )
  ON CONFLICT (physical_printer_id, endpoint_type, ip, port)
  DO UPDATE SET
    is_active = EXCLUDED.is_active,
    updated_at = now();

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_legacy_printer_destination_endpoint
  ON public.printer_destinations;
CREATE TRIGGER sync_legacy_printer_destination_endpoint
BEFORE INSERT OR UPDATE OF name, ip, port, is_active, physical_printer_id
ON public.printer_destinations
FOR EACH ROW
EXECUTE FUNCTION public.sync_legacy_printer_destination_endpoint();

ALTER TABLE public.printer_destinations
  ALTER COLUMN physical_printer_id SET NOT NULL;

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
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

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

REVOKE ALL ON FUNCTION public.admin_upsert_printer_destination_v2(
  uuid, uuid, text, text, text, boolean, text, integer, text, integer
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_upsert_printer_destination_v2(
  uuid, uuid, text, text, text, boolean, text, integer, text, integer
) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.cleanup_orphaned_physical_printer()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.printer_destinations destination
    WHERE destination.physical_printer_id = OLD.physical_printer_id
  ) THEN
    DELETE FROM public.physical_printers
    WHERE id = OLD.physical_printer_id;
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS cleanup_orphaned_physical_printer
  ON public.printer_destinations;
CREATE TRIGGER cleanup_orphaned_physical_printer
AFTER DELETE ON public.printer_destinations
FOR EACH ROW
EXECUTE FUNCTION public.cleanup_orphaned_physical_printer();

COMMIT;
