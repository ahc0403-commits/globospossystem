-- Production POS must never create or reactivate test identities, fixture
-- brands, or test restaurants. Historical inactive rows remain available for
-- referential integrity and audit evidence.

DO $$
BEGIN
  IF to_regclass('auth.users') IS NULL
     OR to_regclass('public.users') IS NULL
     OR to_regclass('public.brands') IS NULL
     OR to_regclass('public.restaurants') IS NULL THEN
    RAISE EXCEPTION 'PRODUCTION_TEST_ENTITY_GUARD_RELATION_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM auth.users
    WHERE (
      lower(coalesce(email, '')) ~ '@[^@]+[.]test$'
      OR lower(coalesce(email, '')) = ANY (ARRAY[
        'office.store@globos.vn',
        'office.brand.kn@globos.vn',
        'office.brand.mk@globos.vn',
        'office.staff@globos.vn',
        'office.super@globos.vn'
      ])
    )
      AND (banned_until IS NULL OR banned_until <= now())
  ) THEN
    RAISE EXCEPTION 'PRODUCTION_TEST_ENTITY_GUARD_UNBANNED_IDENTITY';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.restaurants restaurant
    LEFT JOIN public.brands brand ON brand.id = restaurant.brand_id
    WHERE restaurant.is_active
      AND (
        lower(coalesce(restaurant.name, '')) ~
          '(^|[^a-z0-9])(test|fixture|smoke|pilot)([^a-z0-9]|$)'
        OR lower(coalesce(restaurant.slug, '')) ~
          '(^|-)(test|fixture|smoke|pilot)(-|$)'
        OR lower(coalesce(brand.name, '')) ~
          '(^|[^a-z0-9])(test|fixture|smoke|pilot)([^a-z0-9]|$)'
        OR lower(coalesce(brand.code, '')) ~
          '(^|[_-])(test|fixture|smoke|pilot)([_-]|$)'
        OR upper(coalesce(brand.code, '')) LIKE 'SMK\_%' ESCAPE '\'
      )
  ) THEN
    RAISE EXCEPTION 'PRODUCTION_TEST_ENTITY_GUARD_ACTIVE_TEST_STORE';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.reject_production_test_auth_identity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, auth, public
AS $$
DECLARE
  v_email text := lower(btrim(coalesce(NEW.email, '')));
BEGIN
  IF v_email ~ '@[^@]+[.]test$'
     OR v_email = ANY (ARRAY[
       'office.store@globos.vn',
       'office.brand.kn@globos.vn',
       'office.brand.mk@globos.vn',
       'office.staff@globos.vn',
       'office.super@globos.vn'
     ]) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'PRODUCTION_TEST_AUTH_IDENTITY_FORBIDDEN';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.reject_production_test_auth_identity()
  FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS reject_production_test_auth_identity
  ON auth.users;
CREATE TRIGGER reject_production_test_auth_identity
BEFORE INSERT OR UPDATE OF email ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.reject_production_test_auth_identity();

CREATE OR REPLACE FUNCTION public.reject_production_test_brand()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_name text := lower(btrim(coalesce(NEW.name, '')));
  v_code text := lower(btrim(coalesce(NEW.code, '')));
BEGIN
  IF v_name ~ '(^|[^a-z0-9])(test|fixture|smoke|pilot)([^a-z0-9]|$)'
     OR v_code ~ '(^|[_-])(test|fixture|smoke|pilot)([_-]|$)'
     OR upper(v_code) LIKE 'SMK\_%' ESCAPE '\' THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'PRODUCTION_TEST_BRAND_FORBIDDEN';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.reject_production_test_brand()
  FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS reject_production_test_brand
  ON public.brands;
CREATE TRIGGER reject_production_test_brand
BEFORE INSERT OR UPDATE OF name, code ON public.brands
FOR EACH ROW
EXECUTE FUNCTION public.reject_production_test_brand();

CREATE OR REPLACE FUNCTION public.reject_production_test_restaurant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_name text := lower(btrim(coalesce(NEW.name, '')));
  v_slug text := lower(btrim(coalesce(NEW.slug, '')));
BEGIN
  IF v_name ~ '(^|[^a-z0-9])(test|fixture|smoke|pilot)([^a-z0-9]|$)'
     OR v_slug ~ '(^|-)(test|fixture|smoke|pilot)(-|$)'
     OR EXISTS (
       SELECT 1
       FROM public.brands brand
       WHERE brand.id = NEW.brand_id
         AND (
           lower(coalesce(brand.name, '')) ~
             '(^|[^a-z0-9])(test|fixture|smoke|pilot)([^a-z0-9]|$)'
           OR lower(coalesce(brand.code, '')) ~
             '(^|[_-])(test|fixture|smoke|pilot)([_-]|$)'
           OR upper(coalesce(brand.code, '')) LIKE 'SMK\_%' ESCAPE '\'
         )
     ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'PRODUCTION_TEST_RESTAURANT_FORBIDDEN';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.reject_production_test_restaurant()
  FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS reject_production_test_restaurant
  ON public.restaurants;
CREATE TRIGGER reject_production_test_restaurant
BEFORE INSERT OR UPDATE OF name, slug, brand_id, is_active
ON public.restaurants
FOR EACH ROW
EXECUTE FUNCTION public.reject_production_test_restaurant();

COMMENT ON FUNCTION public.reject_production_test_auth_identity() IS
  'Production hard guard: rejects .test and POS boundary-test Auth emails.';
COMMENT ON FUNCTION public.reject_production_test_brand() IS
  'Production hard guard: rejects test, fixture, smoke, and pilot brands.';
COMMENT ON FUNCTION public.reject_production_test_restaurant() IS
  'Production hard guard: rejects test, fixture, smoke, and pilot restaurants.';
