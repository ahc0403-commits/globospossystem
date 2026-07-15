-- NON-EXECUTABLE DRAFT: keep outside supabase/migrations until a later release.
-- The operator must explicitly set the guard in the same transaction only after
-- all client-cutover evidence in ../SECURITY_EXPAND_CONTRACT_RUNBOOK.md exists.
BEGIN;

DO $contract_guard$
BEGIN
  IF current_setting('app.security_contract_approved', true)
       IS DISTINCT FROM 'GLOBOS_SECURITY_CONTRACT_APPROVED' THEN
    RAISE EXCEPTION 'SECURITY_CONTRACT_APPROVAL_REQUIRED';
  END IF;

  IF pg_catalog.to_regprocedure('public.process_payment(uuid,uuid,numeric,text,uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.attach_payment_proof_v2(uuid,uuid,text,timestamp with time zone)') IS NULL
     OR pg_catalog.to_regprocedure('public.set_payroll_pin_v2(uuid,text)') IS NULL
     OR pg_catalog.to_regprocedure('public.clear_payroll_pin_v2(uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.verify_payroll_pin(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'SECURITY_CONTRACT_V2_BOUNDARY_MISSING';
  END IF;
END;
$contract_guard$;

REVOKE EXECUTE ON FUNCTION public.process_payment(uuid, uuid, numeric, text)
  FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.attach_payment_proof(uuid, uuid, text, timestamptz)
  FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.set_payroll_pin(uuid, text)
  FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.clear_payroll_pin(uuid)
  FROM authenticated;

CREATE OR REPLACE VIEW public.store_settings AS
SELECT
  id,
  restaurant_id AS store_id,
  NULL::text AS payroll_pin,
  settings_json,
  updated_at
FROM public.restaurant_settings;

ALTER VIEW public.store_settings SET (security_invoker = true);
REVOKE SELECT ON TABLE public.restaurant_settings FROM anon, authenticated;
REVOKE SELECT (payroll_pin) ON public.restaurant_settings FROM authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.restaurant_settings FROM anon, authenticated;
GRANT SELECT (id, restaurant_id, settings_json, updated_at)
  ON public.restaurant_settings TO authenticated;

COMMIT;
