BEGIN;

DROP FUNCTION IF EXISTS public.get_bm_menu_exception_history(
  uuid, timestamptz, timestamptz, text, boolean, text, timestamptz, integer, integer
);

DROP INDEX IF EXISTS public.audit_logs_bm_menu_exception_idx;
DROP INDEX IF EXISTS public.orders_bm_staff_meal_history_idx;

COMMIT;
