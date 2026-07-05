-- 20260704001000_rpc_store_param_naming_closure.sql
-- Closes the p_restaurant_id → p_store_id parameter-name drift left over
-- from the contract_store_naming series (found by the 2026-07-03 automated
-- REST/RPC rehearsal: app-style p_store_id calls miss these signatures and
-- only succeed through the rpc_compat retry).
--
-- PostgreSQL cannot rename function parameters via CREATE OR REPLACE, so
-- each affected function is recreated from its live definition with the
-- parameter renamed. Mechanical transform, verified safe beforehand:
--   * no function body anywhere calls these with named notation
--     (`p_restaurant_id =>`) — internal calls are positional;
--   * all affected functions carry the default ACL (no custom REVOKEs to
--     preserve across DROP/CREATE);
--   * `p_restaurant_id` appears in bodies only as the parameter reference
--     (audit `'restaurant_id'` jsonb keys and restaurant_id columns have no
--     `p_` prefix and are untouched).
-- Idempotent: environments with nothing left to rename process zero rows.

BEGIN;

DO $rename$
DECLARE
  r record;
BEGIN
  -- Materialize the worklist first so catalog mutation inside the loop
  -- cannot interact with the scan.
  CREATE TEMP TABLE _legacy_param_fns ON COMMIT DROP AS
  SELECT p.oid::regprocedure::text AS identity,
         p.proname,
         pg_get_function_identity_arguments(p.oid) AS idargs,
         pg_get_functiondef(p.oid) AS def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND pg_get_function_identity_arguments(p.oid) LIKE '%p_restaurant_id%';

  FOR r IN SELECT * FROM _legacy_param_fns ORDER BY proname LOOP
    EXECUTE format('DROP FUNCTION public.%I(%s)', r.proname, r.idargs);
    EXECUTE replace(r.def, 'p_restaurant_id', 'p_store_id');
    RAISE NOTICE 'renamed p_restaurant_id -> p_store_id: %', r.proname;
  END LOOP;
END;
$rename$;

-- Post-condition: no public function may still take p_restaurant_id.
DO $verify$
DECLARE
  v_bad text;
BEGIN
  SELECT string_agg(p.proname, ', ') INTO v_bad
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND pg_get_function_identity_arguments(p.oid) LIKE '%p_restaurant_id%';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'p_restaurant_id parameters remain on: %', v_bad;
  END IF;
END;
$verify$;

COMMIT;
