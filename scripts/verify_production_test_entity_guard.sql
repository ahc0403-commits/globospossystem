\set ON_ERROR_STOP on

DO $$
DECLARE
  v_trigger_count integer;
BEGIN
  SELECT count(*) INTO v_trigger_count
  FROM pg_trigger trigger_info
  WHERE NOT trigger_info.tgisinternal
    AND trigger_info.tgenabled <> 'D'
    AND (trigger_info.tgrelid, trigger_info.tgname) IN (
      ('auth.users'::regclass, 'reject_production_test_auth_identity'),
      ('public.brands'::regclass, 'reject_production_test_brand'),
      ('public.restaurants'::regclass, 'reject_production_test_restaurant')
    );
  IF v_trigger_count <> 3 THEN
    RAISE EXCEPTION 'PRODUCTION_TEST_ENTITY_GUARD_VERIFY_TRIGGER_COUNT: %',
      v_trigger_count;
  END IF;

  IF to_regprocedure('public.reject_production_test_auth_identity()') IS NULL
     OR to_regprocedure('public.reject_production_test_brand()') IS NULL
     OR to_regprocedure('public.reject_production_test_restaurant()') IS NULL THEN
    RAISE EXCEPTION 'PRODUCTION_TEST_ENTITY_GUARD_VERIFY_FUNCTION_MISSING';
  END IF;

  IF has_function_privilege(
       'anon', 'public.reject_production_test_auth_identity()', 'EXECUTE'
     )
     OR has_function_privilege(
       'authenticated', 'public.reject_production_test_auth_identity()', 'EXECUTE'
     )
     OR has_function_privilege(
       'service_role', 'public.reject_production_test_auth_identity()', 'EXECUTE'
     )
     OR has_function_privilege(
       'anon', 'public.reject_production_test_brand()', 'EXECUTE'
     )
     OR has_function_privilege(
       'authenticated', 'public.reject_production_test_brand()', 'EXECUTE'
     )
     OR has_function_privilege(
       'service_role', 'public.reject_production_test_brand()', 'EXECUTE'
     )
     OR has_function_privilege(
       'anon', 'public.reject_production_test_restaurant()', 'EXECUTE'
     )
     OR has_function_privilege(
       'authenticated', 'public.reject_production_test_restaurant()', 'EXECUTE'
     )
     OR has_function_privilege(
       'service_role', 'public.reject_production_test_restaurant()', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'PRODUCTION_TEST_ENTITY_GUARD_VERIFY_FUNCTION_ACL';
  END IF;

  BEGIN
    INSERT INTO auth.users (id, email)
    VALUES (
      '00000000-0000-0000-0000-00000000e101',
      'guard-probe@globos.test'
    );
    RAISE EXCEPTION 'PRODUCTION_TEST_ENTITY_GUARD_ACCEPTED_TEST_AUTH';
  EXCEPTION
    WHEN check_violation THEN
      IF SQLERRM <> 'PRODUCTION_TEST_AUTH_IDENTITY_FORBIDDEN' THEN
        RAISE;
      END IF;
  END;

  BEGIN
    INSERT INTO auth.users (id, email)
    VALUES (
      '00000000-0000-0000-0000-00000000e102',
      'office.super@globos.vn'
    );
    RAISE EXCEPTION 'PRODUCTION_TEST_ENTITY_GUARD_ACCEPTED_BOUNDARY_AUTH';
  EXCEPTION
    WHEN check_violation THEN
      IF SQLERRM <> 'PRODUCTION_TEST_AUTH_IDENTITY_FORBIDDEN' THEN
        RAISE;
      END IF;
  END;

  BEGIN
    INSERT INTO public.brands (id, code, name)
    VALUES (
      '00000000-0000-0000-0000-00000000e103',
      'SMK_GUARD_PROBE',
      'Guard probe brand'
    );
    RAISE EXCEPTION 'PRODUCTION_TEST_ENTITY_GUARD_ACCEPTED_TEST_BRAND';
  EXCEPTION
    WHEN check_violation THEN
      IF SQLERRM <> 'PRODUCTION_TEST_BRAND_FORBIDDEN' THEN
        RAISE;
      END IF;
  END;

  BEGIN
    INSERT INTO public.restaurants (id, name, slug)
    VALUES (
      '00000000-0000-0000-0000-00000000e104',
      'Guard Fixture Restaurant',
      'guard-fixture-restaurant'
    );
    RAISE EXCEPTION 'PRODUCTION_TEST_ENTITY_GUARD_ACCEPTED_TEST_RESTAURANT';
  EXCEPTION
    WHEN check_violation THEN
      IF SQLERRM <> 'PRODUCTION_TEST_RESTAURANT_FORBIDDEN' THEN
        RAISE;
      END IF;
  END;

  IF EXISTS (
    SELECT 1 FROM auth.users
    WHERE id IN (
      '00000000-0000-0000-0000-00000000e101',
      '00000000-0000-0000-0000-00000000e102'
    )
  )
     OR EXISTS (
       SELECT 1 FROM public.brands
       WHERE id = '00000000-0000-0000-0000-00000000e103'
     )
     OR EXISTS (
       SELECT 1 FROM public.restaurants
       WHERE id = '00000000-0000-0000-0000-00000000e104'
     ) THEN
    RAISE EXCEPTION 'PRODUCTION_TEST_ENTITY_GUARD_VERIFY_PROBE_PERSISTED';
  END IF;
END $$;

SELECT 'PRODUCTION_TEST_ENTITY_GUARD_VERIFY_OK' AS result;
