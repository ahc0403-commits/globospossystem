-- Synthetic fixture only. Never apply this file to a POS or Office database.
DO $$ BEGIN
  IF current_database() <> 'payroll_test' THEN
    RAISE EXCEPTION 'PAYROLL_TEST_DATABASE_REQUIRED';
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN CREATE ROLE service_role; END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT (current_setting('request.headers', true)::jsonb ->> 'x-test-actor')::uuid
$$;
SET ROLE postgres;
CREATE TABLE public.users (
  id uuid PRIMARY KEY, auth_id uuid, is_active boolean, role text, full_name text
);
CREATE TABLE public.store_employees (
  id uuid PRIMARY KEY, full_name text, employment_role text, employee_number text
);
CREATE TABLE public.attendance_logs (
  id uuid PRIMARY KEY, restaurant_id uuid, user_id uuid, employee_id uuid,
  type text, photo_url text, photo_thumbnail_url text,
  logged_at timestamptz, created_at timestamptz DEFAULT now()
);
CREATE OR REPLACE FUNCTION public.user_accessible_stores(p_actor uuid)
RETURNS TABLE(store_id uuid) LANGUAGE sql STABLE AS $$
  SELECT '10000000-0000-0000-0000-000000000001'::uuid
  WHERE p_actor = '20000000-0000-0000-0000-000000000001'::uuid
$$;
INSERT INTO public.users VALUES
  ('20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', true, 'store_admin', 'Fixture Admin'),
  ('20000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002', true, 'waiter', 'Fixture Waiter');
INSERT INTO public.store_employees VALUES
  ('30000000-0000-0000-0000-000000000001', 'Fixture Employee', 'part_timer', 'T1');
