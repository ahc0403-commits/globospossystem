-- Roll back the application to the prior release before removing this RPC.
BEGIN;
DROP FUNCTION IF EXISTS public.get_payroll_hourly_rules(uuid, uuid[]);
COMMIT;
