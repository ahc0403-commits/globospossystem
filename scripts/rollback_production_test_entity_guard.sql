\set ON_ERROR_STOP on

DROP TRIGGER IF EXISTS reject_production_test_auth_identity
  ON auth.users;
DROP TRIGGER IF EXISTS reject_production_test_brand
  ON public.brands;
DROP TRIGGER IF EXISTS reject_production_test_restaurant
  ON public.restaurants;

DROP FUNCTION IF EXISTS public.reject_production_test_auth_identity();
DROP FUNCTION IF EXISTS public.reject_production_test_brand();
DROP FUNCTION IF EXISTS public.reject_production_test_restaurant();

DO $$
BEGIN
  IF to_regprocedure('public.reject_production_test_auth_identity()') IS NOT NULL
     OR to_regprocedure('public.reject_production_test_brand()') IS NOT NULL
     OR to_regprocedure('public.reject_production_test_restaurant()') IS NOT NULL THEN
    RAISE EXCEPTION 'PRODUCTION_TEST_ENTITY_GUARD_ROLLBACK_FUNCTION_REMAINS';
  END IF;
END $$;

SELECT 'PRODUCTION_TEST_ENTITY_GUARD_ROLLBACK_OK' AS result;
