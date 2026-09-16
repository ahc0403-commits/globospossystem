CREATE SCHEMA auth;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;

CREATE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE
AS $$ SELECT NULL::uuid $$;

CREATE TABLE public.restaurants (
  id uuid PRIMARY KEY,
  name text NOT NULL,
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.tables (
  id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL,
  table_number text NOT NULL,
  floor_label text
);

CREATE TABLE public.table_qr_tokens (
  restaurant_id uuid NOT NULL,
  table_id uuid NOT NULL,
  token text NOT NULL,
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.menu_categories (
  id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL,
  name text NOT NULL,
  name_ko text,
  name_vi text,
  name_en text,
  sort_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.menu_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL,
  category_id uuid,
  name text NOT NULL,
  name_ko text,
  name_vi text,
  name_en text,
  paperless_name_vi text,
  description text,
  price numeric NOT NULL,
  is_available boolean NOT NULL DEFAULT true,
  is_visible_public boolean NOT NULL DEFAULT false,
  is_archived boolean NOT NULL DEFAULT false,
  is_combo boolean NOT NULL DEFAULT false,
  sort_order integer NOT NULL DEFAULT 0,
  image_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.store_promotions (
  id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL,
  name text NOT NULL,
  discount_percent numeric NOT NULL,
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL,
  channel text NOT NULL,
  scope text NOT NULL,
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.store_promotion_menu_items (
  promotion_id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  menu_item_id uuid NOT NULL
);

CREATE TABLE public.audit_logs (
  actor_id uuid,
  action text NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid NOT NULL,
  details jsonb NOT NULL
);

CREATE FUNCTION public.require_admin_actor_for_restaurant(uuid)
RETURNS void LANGUAGE sql AS $$ SELECT $$;

CREATE FUNCTION public.combo_drink_choice_count(uuid)
RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 0 $$;

CREATE FUNCTION public.combo_drink_options(uuid)
RETURNS jsonb LANGUAGE sql STABLE AS $$ SELECT '[]'::jsonb $$;

CREATE FUNCTION public.qr_get_menu(text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER
AS $$ SELECT '{}'::jsonb $$;
REVOKE ALL ON FUNCTION public.qr_get_menu(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.qr_get_menu(text)
  TO anon, authenticated, service_role;

CREATE FUNCTION public.admin_create_menu_item_i18n_paperless(
  uuid, uuid, text, text, text, text, numeric, integer, boolean
) RETURNS public.menu_items
LANGUAGE sql SECURITY DEFINER
AS $$ SELECT NULL::public.menu_items $$;
REVOKE ALL ON FUNCTION public.admin_create_menu_item_i18n_paperless(
  uuid, uuid, text, text, text, text, numeric, integer, boolean
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_create_menu_item_i18n_paperless(
  uuid, uuid, text, text, text, text, numeric, integer, boolean
) TO authenticated;

INSERT INTO public.restaurants(id, name)
VALUES ('11111111-1111-4111-8111-111111111111', 'QR fixture');

INSERT INTO public.tables(id, restaurant_id, table_number, floor_label)
VALUES (
  '22222222-2222-4222-8222-222222222222',
  '11111111-1111-4111-8111-111111111111',
  '1',
  '1F'
);

INSERT INTO public.table_qr_tokens(restaurant_id, table_id, token)
VALUES (
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222',
  'fixture-token'
);

INSERT INTO public.menu_categories(
  id, restaurant_id, name, name_ko, name_vi, name_en, sort_order
) VALUES
  (
    '33333333-3333-4333-8333-333333333333',
    '11111111-1111-4111-8111-111111111111',
    '메뉴 TOP7', '메뉴 TOP7', 'TOP7', 'TOP7', 0
  ),
  (
    '44444444-4444-4444-8444-444444444444',
    '11111111-1111-4111-8111-111111111111',
    '신규', '신규', 'Mới', 'New', 1
  );

INSERT INTO public.menu_items(
  id, restaurant_id, category_id, name, name_ko, name_vi, name_en,
  price, is_available, is_visible_public, sort_order
) VALUES (
  '55555555-5555-4555-8555-555555555555',
  '11111111-1111-4111-8111-111111111111',
  '33333333-3333-4333-8333-333333333333',
  'TOP menu', 'TOP menu', 'TOP menu', 'TOP menu',
  50000, true, false, 0
);
