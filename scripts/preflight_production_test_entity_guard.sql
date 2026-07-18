\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regclass('auth.users') IS NULL
     OR to_regclass('public.users') IS NULL
     OR to_regclass('public.brands') IS NULL
     OR to_regclass('public.restaurants') IS NULL THEN
    RAISE EXCEPTION 'PRODUCTION_TEST_ENTITY_GUARD_PREFLIGHT_RELATION_MISSING';
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
    RAISE EXCEPTION 'PRODUCTION_TEST_ENTITY_GUARD_PREFLIGHT_UNBANNED_IDENTITY';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.users profile
    JOIN auth.users identity ON identity.id = profile.auth_id
    WHERE profile.is_active
      AND (
        lower(coalesce(identity.email, '')) ~ '@[^@]+[.]test$'
        OR lower(coalesce(identity.email, '')) = ANY (ARRAY[
          'office.store@globos.vn',
          'office.brand.kn@globos.vn',
          'office.brand.mk@globos.vn',
          'office.staff@globos.vn',
          'office.super@globos.vn'
        ])
      )
  ) THEN
    RAISE EXCEPTION 'PRODUCTION_TEST_ENTITY_GUARD_PREFLIGHT_ACTIVE_PROFILE';
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
    RAISE EXCEPTION 'PRODUCTION_TEST_ENTITY_GUARD_PREFLIGHT_ACTIVE_TEST_STORE';
  END IF;
END $$;

SELECT 'PRODUCTION_TEST_ENTITY_GUARD_PREFLIGHT_OK' AS result;
