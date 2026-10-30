-- Synthetic fixture, never run on an application database.
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
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

ALTER TABLE public.menu_items ADD COLUMN catalog_parent_id uuid, ADD COLUMN size_parent_id uuid,
 ADD COLUMN effective_vat_rate numeric DEFAULT 8, ADD COLUMN price numeric DEFAULT 100,
 ADD COLUMN menu_option_key text, ADD COLUMN choice_definition jsonb NOT NULL DEFAULT '{}';
ALTER TABLE public.order_items ADD COLUMN vat_profile_snapshot jsonb;
CREATE FUNCTION public.require_admin_actor_for_restaurant(uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN PERFORM public.require_pos_admin_actor_for_store($1,'ADMIN_MUTATION_FORBIDDEN'); END $$;
CREATE TABLE public.pos_live_events(id bigserial,restaurant_id uuid,domain text,source_table text,event_type text);
ALTER TABLE public.restaurants ADD COLUMN name text DEFAULT 'Fixture store', ADD COLUMN is_active boolean DEFAULT true;
ALTER TABLE public.menu_items ADD COLUMN name text DEFAULT 'Fixture menu', ADD COLUMN name_ko text,
 ADD COLUMN name_vi text, ADD COLUMN name_en text, ADD COLUMN description text, ADD COLUMN image_url text,
 ADD COLUMN category_id uuid, ADD COLUMN is_available boolean DEFAULT true,
 ADD COLUMN is_visible_public boolean DEFAULT true, ADD COLUMN is_combo boolean DEFAULT false,
 ADD COLUMN sort_order integer DEFAULT 0;
CREATE TABLE public.menu_categories(id uuid PRIMARY KEY,restaurant_id uuid,name text,name_ko text,name_vi text,name_en text,sort_order integer,is_active boolean);
CREATE TABLE public.tables(id uuid PRIMARY KEY,restaurant_id uuid,table_number text,floor_label text);
CREATE TABLE public.table_qr_tokens(token text,restaurant_id uuid,table_id uuid,is_active boolean);
CREATE FUNCTION public.combo_drink_choice_count(uuid) RETURNS integer LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'FIXTURE_COMBOS_NOT_IMPLEMENTED'; END $$;
CREATE FUNCTION public.combo_drink_options(uuid) RETURNS jsonb LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'FIXTURE_COMBOS_NOT_IMPLEMENTED'; END $$;
CREATE FUNCTION public.menu_choice_snapshot(jsonb,text,text) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'FIXTURE_REGISTERED_CHOICES_NOT_IMPLEMENTED'; END $$;
