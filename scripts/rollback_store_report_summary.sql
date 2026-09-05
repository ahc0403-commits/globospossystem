-- Roll back the application before removing this RPC.
BEGIN;
DROP FUNCTION IF EXISTS public.get_store_report_summary(uuid,date,date);
COMMIT;
