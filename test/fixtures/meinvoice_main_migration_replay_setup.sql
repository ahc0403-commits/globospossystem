CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;

CREATE SCHEMA auth;
CREATE TABLE auth.users (id uuid PRIMARY KEY);
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid LANGUAGE sql STABLE
AS $$ SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

CREATE TABLE public.users (
  id uuid PRIMARY KEY,
  auth_id uuid REFERENCES auth.users(id),
  restaurant_id uuid,
  role text NOT NULL,
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.system_config (
  key text PRIMARY KEY,
  value text NOT NULL,
  description text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES public.users(id)
);

CREATE TABLE public.tax_entity (
  id uuid PRIMARY KEY,
  tax_code text NOT NULL UNIQUE,
  name text NOT NULL,
  owner_type text NOT NULL,
  einvoice_provider text NOT NULL,
  data_source text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.brands (
  id uuid PRIMARY KEY,
  code text NOT NULL,
  name text NOT NULL,
  suggested_tax_entity_id uuid REFERENCES public.tax_entity(id)
);

CREATE TABLE public.restaurants (
  id uuid PRIMARY KEY,
  name text NOT NULL,
  address text,
  slug text,
  operation_mode text NOT NULL,
  per_person_charge numeric,
  tax_entity_id uuid NOT NULL REFERENCES public.tax_entity(id),
  brand_id uuid NOT NULL REFERENCES public.brands(id),
  store_type text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.users
  ADD CONSTRAINT users_restaurant_id_fkey
  FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id);
CREATE VIEW public.stores AS SELECT * FROM public.restaurants;

CREATE TABLE public.orders (
  id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  status text NOT NULL DEFAULT 'pending',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.payments (
  id uuid PRIMARY KEY,
  order_id uuid NOT NULL REFERENCES public.orders(id),
  method text NOT NULL,
  amount numeric NOT NULL,
  amount_portion numeric,
  is_revenue boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.order_items (
  id uuid PRIMARY KEY,
  order_id uuid NOT NULL REFERENCES public.orders(id),
  item_type text NOT NULL DEFAULT 'standard',
  display_name text,
  label text,
  quantity numeric NOT NULL DEFAULT 1,
  unit_price numeric NOT NULL DEFAULT 0,
  vat_rate numeric NOT NULL DEFAULT 0,
  vat_amount numeric NOT NULL DEFAULT 0,
  total_amount_ex_tax numeric NOT NULL DEFAULT 0,
  paying_amount_inc_tax numeric NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'pending',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.b2b_buyer_cache (
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  buyer_tax_code text NOT NULL,
  tax_id text GENERATED ALWAYS AS (buyer_tax_code) STORED,
  tax_company_name text,
  tax_address text,
  tax_buyer_name text,
  receiver_email text NOT NULL,
  receiver_email_cc text,
  first_used_at timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz NOT NULL DEFAULT now(),
  use_count int NOT NULL DEFAULT 1,
  email_bounce_count int NOT NULL DEFAULT 0,
  last_verified_at timestamptz,
  tax_entity_id uuid REFERENCES public.tax_entity(id),
  PRIMARY KEY (store_id, buyer_tax_code)
);

CREATE TABLE public.einvoice_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_id text NOT NULL UNIQUE,
  order_id uuid NOT NULL REFERENCES public.orders(id),
  status text NOT NULL DEFAULT 'pending',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.audit_logs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_id uuid,
  action text NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid,
  details jsonb
);

CREATE TABLE public.store_tax_entity_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  tax_entity_id uuid NOT NULL REFERENCES public.tax_entity(id),
  effective_from timestamptz NOT NULL,
  effective_to timestamptz,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid
);

CREATE OR REPLACE FUNCTION public.is_super_admin()
RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT false $$;
CREATE OR REPLACE FUNCTION public.user_accessible_stores(uuid)
RETURNS TABLE(store_id uuid) LANGUAGE sql STABLE
AS $$ SELECT NULL::uuid WHERE false $$;
CREATE OR REPLACE FUNCTION public.user_accessible_tax_entities(uuid)
RETURNS TABLE(tax_entity_id uuid) LANGUAGE sql STABLE
AS $$ SELECT NULL::uuid WHERE false $$;
CREATE OR REPLACE FUNCTION public.require_admin_actor_for_restaurant(uuid)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN RETURN; END $$;
CREATE OR REPLACE FUNCTION public.admin_create_restaurant(
  text, text, text, text DEFAULT NULL, numeric DEFAULT NULL,
  uuid DEFAULT NULL, text DEFAULT 'direct'
) RETURNS public.stores LANGUAGE plpgsql
AS $$ BEGIN RAISE EXCEPTION 'legacy fixture'; END $$;
CREATE OR REPLACE FUNCTION public.admin_update_restaurant(
  uuid, text, text, text, text DEFAULT NULL, numeric DEFAULT NULL,
  uuid DEFAULT NULL, text DEFAULT 'direct'
) RETURNS public.stores LANGUAGE plpgsql
AS $$ BEGIN RAISE EXCEPTION 'legacy fixture'; END $$;
CREATE OR REPLACE FUNCTION public.sync_restaurant_store_type_from_tax_entity()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;
CREATE OR REPLACE FUNCTION public.sync_stores_after_tax_entity_owner_change()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;

CREATE TRIGGER trg_sync_restaurant_store_type_from_tax_entity
BEFORE INSERT OR UPDATE OF tax_entity_id, store_type ON public.restaurants
FOR EACH ROW EXECUTE FUNCTION public.sync_restaurant_store_type_from_tax_entity();
CREATE TRIGGER trg_sync_stores_after_tax_entity_owner_change
AFTER UPDATE OF owner_type ON public.tax_entity
FOR EACH ROW EXECUTE FUNCTION public.sync_stores_after_tax_entity_owner_change();

INSERT INTO auth.users (id) VALUES ('10000000-0000-0000-0000-000000000001');
INSERT INTO public.users (id, auth_id, role, is_active)
VALUES (
  '20000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  'super_admin',
  true
);
INSERT INTO public.tax_entity (
  id, tax_code, name, owner_type, einvoice_provider, data_source
) VALUES (
  '00000000-0000-0000-0000-000000000011',
  'PLACEHOLDER_DEV_000',
  'Development placeholder',
  'internal',
  'wetax',
  'VNPT_EPAY'
);
INSERT INTO public.brands (id, code, name, suggested_tax_entity_id) VALUES
  ('77000000-0000-0000-0000-000000000001', 'PHOTO', 'PHOTO OBJET',
   '00000000-0000-0000-0000-000000000011'),
  ('77000000-0000-0000-0000-000000000002', 'OTHER', 'Other brand',
   '00000000-0000-0000-0000-000000000011');
INSERT INTO public.restaurants (
  id, name, address, slug, operation_mode, tax_entity_id, brand_id, store_type
)
SELECT
  ('88000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
  'PHOTO store ' || n,
  'Address ' || n,
  'photo-' || n,
  'standard',
  '00000000-0000-0000-0000-000000000011'::uuid,
  '77000000-0000-0000-0000-000000000001'::uuid,
  'direct'
FROM generate_series(1, 7) fixture(n);
INSERT INTO public.store_tax_entity_history (
  store_id, tax_entity_id, effective_from, reason
)
SELECT id, tax_entity_id, created_at, 'fixture'
FROM public.restaurants;
