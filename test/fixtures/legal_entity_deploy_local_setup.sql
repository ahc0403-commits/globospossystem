CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;

CREATE SCHEMA auth;
CREATE SCHEMA test_expected;

CREATE TABLE auth.users (
  id uuid PRIMARY KEY
);

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$ SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

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

CREATE VIEW public.stores AS
SELECT * FROM public.restaurants;

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

CREATE TABLE public.meinvoice_tax_entity_config (
  tax_entity_id uuid PRIMARY KEY REFERENCES public.tax_entity(id),
  integration_status text NOT NULL
);

CREATE TABLE public.users (
  id uuid PRIMARY KEY,
  auth_id uuid REFERENCES auth.users(id),
  is_active boolean NOT NULL,
  role text NOT NULL
);

CREATE TABLE public.audit_logs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_id uuid,
  action text NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid,
  details jsonb
);

INSERT INTO auth.users (id) VALUES (
  '10000000-0000-0000-0000-000000000001'
);
INSERT INTO public.users (id, auth_id, is_active, role) VALUES (
  '20000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  true,
  'super_admin'
);

CREATE OR REPLACE FUNCTION public.is_super_admin()
RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT false $$;

CREATE OR REPLACE FUNCTION public.user_accessible_tax_entities(uuid)
RETURNS TABLE(tax_entity_id uuid) LANGUAGE sql STABLE AS $$ SELECT NULL::uuid WHERE false $$;

CREATE OR REPLACE FUNCTION public.require_admin_actor_for_restaurant(uuid)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN RETURN; END $$;

CREATE OR REPLACE FUNCTION public.admin_create_restaurant(
  text, text, text, text DEFAULT NULL, numeric DEFAULT NULL,
  uuid DEFAULT NULL, text DEFAULT 'direct'
) RETURNS public.stores
LANGUAGE plpgsql
AS $$ BEGIN RAISE EXCEPTION 'old create fixture'; END $$;

CREATE OR REPLACE FUNCTION public.admin_update_restaurant(
  uuid, text, text, text, text DEFAULT NULL, numeric DEFAULT NULL,
  uuid DEFAULT NULL, text DEFAULT 'direct'
) RETURNS public.stores
LANGUAGE plpgsql
AS $$ BEGIN RAISE EXCEPTION 'old update fixture'; END $$;

CREATE OR REPLACE FUNCTION public.sync_restaurant_store_type_from_tax_entity()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;

CREATE OR REPLACE FUNCTION public.sync_stores_after_tax_entity_owner_change()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;

CREATE OR REPLACE FUNCTION public.guard_pending_tax_entity_meinvoice_activation()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;

CREATE TRIGGER trg_sync_restaurant_store_type_from_tax_entity
BEFORE INSERT OR UPDATE OF tax_entity_id, store_type ON public.restaurants
FOR EACH ROW EXECUTE FUNCTION public.sync_restaurant_store_type_from_tax_entity();

CREATE TRIGGER trg_sync_stores_after_tax_entity_owner_change
AFTER UPDATE OF owner_type ON public.tax_entity
FOR EACH ROW EXECUTE FUNCTION public.sync_stores_after_tax_entity_owner_change();

CREATE TRIGGER trg_guard_pending_tax_entity_meinvoice_activation
BEFORE INSERT OR UPDATE OF integration_status, tax_entity_id
ON public.meinvoice_tax_entity_config
FOR EACH ROW EXECUTE FUNCTION public.guard_pending_tax_entity_meinvoice_activation();

INSERT INTO public.tax_entity (
  id, tax_code, name, owner_type, einvoice_provider, data_source, created_at, updated_at
) VALUES (
  '00000000-0000-0000-0000-000000000011',
  'PLACEHOLDER_DEV_000',
  'Development placeholder',
  'internal',
  'meinvoice',
  'VNPT_EPAY',
  '2026-01-01 00:00:00+00',
  '2026-01-02 00:00:00+00'
);

INSERT INTO public.brands (id, code, name, suggested_tax_entity_id) VALUES
  ('77000000-0000-0000-0000-000000000001', 'PHOTO', 'PHOTO OBJET',
   '00000000-0000-0000-0000-000000000011'),
  ('77000000-0000-0000-0000-000000000002', 'OTHER', 'Other brand',
   '00000000-0000-0000-0000-000000000011');

INSERT INTO public.restaurants (
  id, name, address, slug, operation_mode, per_person_charge,
  tax_entity_id, brand_id, store_type, is_active, created_at
)
SELECT
  ('88000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
  'PHOTO store ' || n,
  'Address ' || n,
  'photo-' || n,
  'dine_in',
  n * 1000,
  '00000000-0000-0000-0000-000000000011'::uuid,
  '77000000-0000-0000-0000-000000000001'::uuid,
  'direct',
  true,
  '2026-02-01 00:00:00+00'::timestamptz + n * interval '1 day'
FROM generate_series(1, 7) AS fixture(n);

INSERT INTO public.store_tax_entity_history (
  id, store_id, tax_entity_id, effective_from, effective_to, reason, created_at, created_by
)
SELECT
  ('99000000-0000-0000-0000-' || lpad(r.n::text, 12, '0'))::uuid,
  r.id,
  r.tax_entity_id,
  r.created_at,
  NULL,
  'original assignment ' || r.n,
  r.created_at,
  NULL
FROM (
  SELECT restaurants.*, row_number() OVER (ORDER BY id) AS n
  FROM public.restaurants
) r;

CREATE TABLE test_expected.tax_entity AS TABLE public.tax_entity;
CREATE TABLE test_expected.brands AS TABLE public.brands;
CREATE TABLE test_expected.restaurants AS TABLE public.restaurants;
CREATE TABLE test_expected.history AS TABLE public.store_tax_entity_history;

CREATE TABLE test_expected.object_definitions AS
SELECT p.oid::regprocedure::text AS object_identity,
       'function'::text AS object_kind,
       pg_get_functiondef(p.oid) AS definition
FROM pg_proc p
WHERE p.oid IN (
  to_regprocedure('public.admin_create_restaurant(text,text,text,text,numeric,uuid,text)'),
  to_regprocedure('public.admin_update_restaurant(uuid,text,text,text,text,numeric,uuid,text)'),
  to_regprocedure('public.sync_restaurant_store_type_from_tax_entity()'),
  to_regprocedure('public.sync_stores_after_tax_entity_owner_change()'),
  to_regprocedure('public.guard_pending_tax_entity_meinvoice_activation()')
)
UNION ALL
SELECT format('%I.%I:%I', n.nspname, c.relname, t.tgname),
       'trigger',
       pg_get_triggerdef(t.oid, true)
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT t.tgisinternal
  AND t.tgname IN (
    'trg_sync_restaurant_store_type_from_tax_entity',
    'trg_sync_stores_after_tax_entity_owner_change',
    'trg_guard_pending_tax_entity_meinvoice_activation'
  );
