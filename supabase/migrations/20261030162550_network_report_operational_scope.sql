-- production-gate: self-verifying
-- Operational network totals exclude closed stores and the existing non-fiscal
-- sample entity. Individual/archive reports retain their original read contract.
BEGIN;

DO $preflight$
BEGIN
  IF to_regprocedure('public.get_store_revenue_summary(uuid[],date,date)') IS NULL
     OR pg_get_function_result('public.get_store_revenue_summary(uuid[],date,date)'::regprocedure) <> 'jsonb'
     OR NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public'
       AND table_name='restaurants' AND column_name='is_active' AND data_type='boolean')
     OR NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public'
       AND table_name='restaurants' AND column_name='tax_entity_id' AND data_type='uuid') THEN
    RAISE EXCEPTION 'NETWORK_REPORT_PREDECESSOR_CONTRACT_MISSING';
  END IF;
END $preflight$;

CREATE OR REPLACE FUNCTION public.get_network_store_revenue_summary(
  p_store_ids uuid[], p_from_date date, p_to_date date
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path TO public, auth, pg_catalog
AS $function$
DECLARE
  v_result jsonb;
  v_rows jsonb;
  v_excluded jsonb;
BEGIN
  -- Delegate the complete original date/scope/auth/RLS validation and bounded
  -- set-based aggregate. Do not grant broader access or drop historical sales.
  v_result := public.get_store_revenue_summary(p_store_ids,p_from_date,p_to_date);
  WITH eligible AS MATERIALIZED (
    SELECT r.id FROM public.restaurants r
    WHERE r.id=ANY(p_store_ids) AND r.is_active IS TRUE
      AND r.tax_entity_id IS DISTINCT FROM '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid
  )
  SELECT
    COALESCE((SELECT jsonb_agg(item.value ORDER BY item.value->>'store_id')
      FROM jsonb_array_elements(v_result->'rows') item(value)
      JOIN eligible e ON e.id::text=item.value->>'store_id'),'[]'::jsonb),
    COALESCE((SELECT jsonb_agg(requested.id ORDER BY requested.id)
      FROM unnest(p_store_ids) requested(id)
      WHERE NOT EXISTS(SELECT 1 FROM eligible e WHERE e.id=requested.id)),'[]'::jsonb)
  INTO v_rows,v_excluded;
  -- Every requested ID must be returned as a revenue row OR explicitly excluded.
  -- The client rejects truncation, overlaps, duplicates and missing IDs.
  RETURN v_result || jsonb_build_object('rows',v_rows,'excluded_store_ids',v_excluded);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_network_store_revenue_summary(uuid[],date,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_network_store_revenue_summary(uuid[],date,date) TO authenticated;
COMMENT ON FUNCTION public.get_network_store_revenue_summary(uuid[],date,date) IS
  'Operational network scope: active fiscal stores only; explicit excluded IDs; original individual/history aggregate unchanged.';
NOTIFY pgrst, 'reload schema';

DO $verify$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE oid='public.get_network_store_revenue_summary(uuid[],date,date)'::regprocedure
      AND NOT prosecdef AND provolatile='s')
     OR has_function_privilege('anon','public.get_network_store_revenue_summary(uuid[],date,date)','EXECUTE')
     OR NOT has_function_privilege('authenticated','public.get_network_store_revenue_summary(uuid[],date,date)','EXECUTE') THEN
    RAISE EXCEPTION 'NETWORK_REPORT_PERMISSION_CONTRACT_FAILED';
  END IF;
END $verify$;

COMMIT;
