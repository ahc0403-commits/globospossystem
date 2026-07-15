DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN BYPASSRLS;
  END IF;
END;
$roles$;

CREATE SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE SCHEMA auth;
CREATE SCHEMA storage;

CREATE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE
AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

CREATE FUNCTION storage.foldername(text) RETURNS text[]
LANGUAGE sql IMMUTABLE
AS $$ SELECT string_to_array($1, '/') $$;

CREATE TABLE public.restaurants (
  id uuid PRIMARY KEY,
  name text NOT NULL,
  address text,
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.orders (
  id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  status text NOT NULL DEFAULT 'served'
);

CREATE TABLE public.users (
  id uuid PRIMARY KEY,
  auth_id uuid NOT NULL UNIQUE,
  restaurant_id uuid REFERENCES public.restaurants(id),
  role text NOT NULL,
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  amount numeric(15,2) NOT NULL,
  method text NOT NULL,
  processed_by uuid,
  proof_required boolean NOT NULL DEFAULT false,
  proof_photo_url text,
  proof_photo_taken_at timestamptz,
  proof_photo_by uuid
);

CREATE TABLE public.einvoice_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id uuid NOT NULL UNIQUE REFERENCES public.payments(id),
  status text NOT NULL DEFAULT 'pending'
);

CREATE TABLE public.audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id uuid,
  action text NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY audit_logs_authenticated_select ON public.audit_logs
FOR SELECT TO authenticated USING (true);

CREATE TABLE public.restaurant_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL UNIQUE REFERENCES public.restaurants(id),
  payroll_pin text,
  settings_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.restaurant_settings TO authenticated;

CREATE TABLE storage.objects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id text NOT NULL,
  name text NOT NULL
);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

CREATE VIEW public.store_settings AS
SELECT id, restaurant_id AS store_id, payroll_pin, settings_json, updated_at
FROM public.restaurant_settings;

CREATE VIEW public.v_store_daily_sales AS SELECT id FROM public.restaurants;
CREATE VIEW public.v_store_attendance_summary AS SELECT id FROM public.restaurants;
CREATE VIEW public.v_inventory_status AS SELECT id FROM public.restaurants;
CREATE VIEW public.v_brand_kpi AS SELECT id FROM public.restaurants;
CREATE VIEW public.v_quality_monitoring AS SELECT id FROM public.restaurants;
CREATE VIEW public.v_qsc_dashboard_summary AS SELECT id FROM public.restaurants;
CREATE VIEW public.v_qsc_store_status AS SELECT id FROM public.restaurants;
CREATE VIEW public.v_qsc_item_status AS SELECT id FROM public.restaurants;
CREATE VIEW public.v_office_qsc_dashboard AS SELECT id FROM public.restaurants;
CREATE VIEW public.v_office_qsc_store_latest AS SELECT id FROM public.restaurants;
CREATE VIEW public.v_office_qsc_issue_queue AS SELECT id FROM public.restaurants;

GRANT SELECT ON public.store_settings TO anon, authenticated, service_role;
GRANT SELECT ON public.v_store_daily_sales TO anon, authenticated, service_role;
GRANT SELECT ON public.v_store_attendance_summary TO anon, authenticated, service_role;
GRANT SELECT ON public.v_inventory_status TO anon, authenticated, service_role;
GRANT SELECT ON public.v_brand_kpi TO anon, authenticated, service_role;
GRANT SELECT ON public.v_quality_monitoring TO anon, authenticated, service_role;
GRANT SELECT ON public.v_qsc_dashboard_summary TO anon, authenticated, service_role;
GRANT SELECT ON public.v_qsc_store_status TO anon, authenticated, service_role;
GRANT SELECT ON public.v_qsc_item_status TO anon, authenticated, service_role;
GRANT SELECT ON public.v_office_qsc_dashboard TO anon, authenticated, service_role;
GRANT SELECT ON public.v_office_qsc_store_latest TO anon, authenticated, service_role;
GRANT SELECT ON public.v_office_qsc_issue_queue TO anon, authenticated, service_role;

CREATE FUNCTION public.get_user_restaurant_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth
AS $$ SELECT restaurant_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1 $$;

CREATE FUNCTION public.get_user_role() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth
AS $$ SELECT role FROM public.users WHERE auth_id = auth.uid() LIMIT 1 $$;

CREATE FUNCTION public.get_user_store_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth
AS $$ SELECT public.get_user_restaurant_id() $$;

CREATE FUNCTION public.has_any_role(text[]) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth
AS $$ SELECT COALESCE(public.get_user_role() = ANY($1), false) $$;

CREATE FUNCTION public.is_super_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth
AS $$ SELECT COALESCE(public.get_user_role() = 'super_admin', false) $$;

CREATE FUNCTION public.user_accessible_stores(p_auth_id uuid)
RETURNS TABLE(store_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth
AS $$
  SELECT restaurant_id
  FROM public.users
  WHERE auth_id = p_auth_id AND is_active = true AND restaurant_id IS NOT NULL
$$;

CREATE FUNCTION public.require_admin_actor_for_restaurant(p_store_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.users
    WHERE auth_id = auth.uid() AND is_active = true
      AND role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
      AND (role = 'super_admin' OR restaurant_id = p_store_id)
  ) THEN
    RAISE EXCEPTION 'ADMIN_ACTOR_FORBIDDEN';
  END IF;
END;
$$;

CREATE FUNCTION public.process_payment(
  p_order_id uuid,
  p_store_id uuid,
  p_amount numeric,
  p_method text
) RETURNS public.payments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth
AS $$
DECLARE
  v_payment public.payments%ROWTYPE;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.users
    WHERE auth_id = auth.uid() AND is_active = true
      AND restaurant_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN';
  END IF;
  INSERT INTO public.payments (
    order_id, restaurant_id, amount, method, processed_by
  ) VALUES (
    p_order_id, p_store_id, p_amount, p_method, auth.uid()
  ) RETURNING * INTO v_payment;
  INSERT INTO public.einvoice_jobs (payment_id) VALUES (v_payment.id);
  RETURN v_payment;
END;
$$;

CREATE FUNCTION public.attach_payment_proof(
  p_payment_id uuid,
  p_store_id uuid,
  p_proof_photo_url text,
  p_taken_at timestamptz DEFAULT now()
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth
AS $$
BEGIN
  UPDATE public.payments
  SET proof_required = true,
      proof_photo_url = p_proof_photo_url,
      proof_photo_taken_at = p_taken_at
  WHERE id = p_payment_id AND restaurant_id = p_store_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE FUNCTION public.set_payroll_pin(p_store_id uuid, p_payroll_pin text)
RETURNS public.restaurant_settings
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth
AS $$
DECLARE v_result public.restaurant_settings%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);
  INSERT INTO public.restaurant_settings (restaurant_id, payroll_pin)
  VALUES (p_store_id, p_payroll_pin)
  ON CONFLICT (restaurant_id) DO UPDATE
    SET payroll_pin = EXCLUDED.payroll_pin, updated_at = now()
  RETURNING * INTO v_result;
  RETURN v_result;
END;
$$;

CREATE FUNCTION public.clear_payroll_pin(p_store_id uuid)
RETURNS public.restaurant_settings
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth
AS $$
DECLARE v_result public.restaurant_settings%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);
  INSERT INTO public.restaurant_settings (restaurant_id, payroll_pin)
  VALUES (p_store_id, NULL)
  ON CONFLICT (restaurant_id) DO UPDATE
    SET payroll_pin = NULL, updated_at = now()
  RETURNING * INTO v_result;
  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.process_payment(uuid, uuid, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.attach_payment_proof(uuid, uuid, text, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_payroll_pin(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.clear_payroll_pin(uuid) TO authenticated;

INSERT INTO public.restaurants (id, name, address, is_active) VALUES
  ('11111111-1111-1111-1111-111111111111', 'Store A', 'Address A', true),
  ('22222222-2222-2222-2222-222222222222', 'Store B', 'Address B', true);

INSERT INTO public.users (id, auth_id, restaurant_id, role, is_active) VALUES (
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  '11111111-1111-1111-1111-111111111111',
  'store_admin',
  true
);

INSERT INTO public.orders (id, restaurant_id) VALUES
  ('30000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111'),
  ('30000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111'),
  ('30000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111'),
  ('30000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111');

SELECT set_config(
  'request.jwt.claim.sub',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  false
);
