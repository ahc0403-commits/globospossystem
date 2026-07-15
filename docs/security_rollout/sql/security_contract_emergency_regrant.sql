-- EMERGENCY COMPATIBILITY DRAFT: use only if the later Contract release breaks
-- a still-supported old client. This preserves all Expand-created data.
BEGIN;

DO $regrant_guard$
BEGIN
  IF current_setting('app.security_contract_emergency_regrant', true)
       IS DISTINCT FROM 'GLOBOS_SECURITY_COMPATIBILITY_REGRANT' THEN
    RAISE EXCEPTION 'SECURITY_CONTRACT_REGRANT_APPROVAL_REQUIRED';
  END IF;
END;
$regrant_guard$;

GRANT EXECUTE ON FUNCTION public.process_payment(uuid, uuid, numeric, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.attach_payment_proof(uuid, uuid, text, timestamptz)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_payroll_pin(uuid, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.clear_payroll_pin(uuid)
  TO authenticated;

CREATE OR REPLACE VIEW public.store_settings AS
SELECT
  id,
  restaurant_id AS store_id,
  payroll_pin,
  settings_json,
  updated_at
FROM public.restaurant_settings;

ALTER VIEW public.store_settings SET (security_invoker = true);
GRANT SELECT (id, restaurant_id, payroll_pin, settings_json, updated_at)
  ON public.restaurant_settings TO authenticated;

COMMIT;
