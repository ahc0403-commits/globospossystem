BEGIN;

SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';

DO $guard$
BEGIN
  IF to_regprocedure(
       'public.emergency_enrich_start_ready_orders(jsonb)'
     ) IS NULL
     OR to_regprocedure(
       'public.emergency_enrich_start_ready_orders_pre_500_scale(jsonb)'
     ) IS NULL THEN
    RAISE EXCEPTION 'KDS_SET_ENRICHMENT_ROLLBACK_STATE_INVALID';
  END IF;
END;
$guard$;

DROP FUNCTION public.emergency_enrich_start_ready_orders(jsonb);
ALTER FUNCTION
  public.emergency_enrich_start_ready_orders_pre_500_scale(jsonb)
  RENAME TO emergency_enrich_start_ready_orders;
REVOKE ALL ON FUNCTION public.emergency_enrich_start_ready_orders(jsonb)
  FROM PUBLIC, anon, authenticated;

COMMIT;
