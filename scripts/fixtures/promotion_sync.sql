-- Synthetic fixture only; never apply to a POS or Office database.
DO $$ BEGIN
  IF current_database() <> 'promotion_test' THEN
    RAISE EXCEPTION 'PROMOTION_TEST_DATABASE_REQUIRED';
  END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE IF NOT EXISTS auth.users (id uuid PRIMARY KEY);
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
SET ROLE postgres;
CREATE TABLE public.users (
  id uuid PRIMARY KEY, auth_id uuid, is_active boolean, role text
);
CREATE TABLE public.restaurants (
  id uuid PRIMARY KEY, vat_pricing_mode text DEFAULT 'exclusive'
);
CREATE TABLE public.orders (
  id uuid PRIMARY KEY, restaurant_id uuid REFERENCES public.restaurants,
  status text DEFAULT 'serving', order_purpose text DEFAULT 'customer',
  order_source text DEFAULT 'staff'
);
CREATE TABLE public.menu_items (
  id uuid PRIMARY KEY, restaurant_id uuid REFERENCES public.restaurants,
  vat_category text DEFAULT 'food', is_archived boolean DEFAULT false
);
CREATE TABLE public.order_items (
  id uuid PRIMARY KEY, restaurant_id uuid REFERENCES public.restaurants,
  order_id uuid REFERENCES public.orders, menu_item_id uuid REFERENCES public.menu_items,
  unit_price numeric, quantity numeric, status text DEFAULT 'ready',
  item_type text DEFAULT 'menu_item', is_service_item boolean DEFAULT false,
  created_at timestamptz DEFAULT now(), vat_rate numeric, vat_amount numeric,
  total_amount_ex_tax numeric, paying_amount_inc_tax numeric
);
CREATE TABLE public.payments (id uuid PRIMARY KEY);
CREATE TABLE public.audit_logs (
  actor_id uuid, action text, entity_type text, entity_id uuid, details jsonb
);
CREATE FUNCTION public.user_accessible_stores(p_actor uuid)
RETURNS TABLE(store_id uuid) LANGUAGE sql STABLE AS $$
  SELECT '10000000-0000-0000-0000-000000000001'::uuid
  WHERE p_actor IN ('20000000-0000-0000-0000-000000000001'::uuid,
                   '20000000-0000-0000-0000-000000000002'::uuid)
$$;
CREATE FUNCTION public.is_super_admin() RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT auth.uid() = '20000000-0000-0000-0000-000000000003'::uuid
$$;
CREATE FUNCTION public.require_pos_admin_actor_for_store(p_store uuid, p_error text)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN
  IF NOT COALESCE(public.is_super_admin(), false)
     AND NOT (auth.uid() = '20000000-0000-0000-0000-000000000001'::uuid
       AND p_store IN (SELECT public.user_accessible_stores(auth.uid()))) THEN
    RAISE EXCEPTION '%', p_error;
  END IF;
END $$;
-- This fixture tests promotion persistence, not payment settlement. Loading
-- the unchanged scoped wrapper must never masquerade as payment integration.
CREATE FUNCTION public.process_payment(uuid, uuid, numeric, text)
RETURNS public.payments LANGUAGE plpgsql AS $$ BEGIN
  RAISE EXCEPTION 'FIXTURE_PAYMENT_ANCHOR_NOT_IMPLEMENTED';
END $$;
INSERT INTO public.users VALUES
  ('20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', true, 'cashier'),
  ('20000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002', true, 'waiter'),
  ('20000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000003', true, 'super_admin');
INSERT INTO auth.users(id) SELECT id FROM public.users;

CREATE TABLE public.fixture_writes (relation_name text, operation text);
CREATE FUNCTION public.fixture_record_write() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_TABLE_NAME = 'order_discount_lines' AND TG_OP = 'INSERT'
     AND current_setting('fixture.reject_line_insert', true) = 'on' THEN
    RAISE EXCEPTION 'FIXTURE_ALLOCATION_WRITE_FAILED';
  END IF;
  INSERT INTO public.fixture_writes VALUES (TG_TABLE_NAME, TG_OP);
  RETURN COALESCE(NEW, OLD);
END $$;
CREATE FUNCTION public.fixture_assert(p_ok boolean, p_label text)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN
  IF p_ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %', p_label; END IF;
  RAISE NOTICE 'PASS: %', p_label;
END $$;
