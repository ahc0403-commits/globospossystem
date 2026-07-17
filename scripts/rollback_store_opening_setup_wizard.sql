BEGIN;

DROP FUNCTION IF EXISTS public.admin_get_store_opening_readiness(uuid);
DROP FUNCTION IF EXISTS public.admin_apply_store_opening_config(uuid, jsonb, jsonb);
DROP FUNCTION IF EXISTS public.admin_validate_store_opening_config(uuid, jsonb, jsonb);
DROP FUNCTION IF EXISTS public.store_opening_private_ipv4(text);
DROP INDEX IF EXISTS public.printer_destinations_active_route_unique;

-- Restore the exact pre-feature queue actor set. No table, destination, order,
-- payment, or print-job data is mutated by rollback.
CREATE OR REPLACE FUNCTION public.print_routing_actor_can_run(
  p_store_id uuid
) RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.auth_id = auth.uid()
      AND u.is_active = true
      AND u.role IN ('kitchen', 'admin', 'store_admin', 'super_admin')
      AND (
        public.is_super_admin()
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) s(store_id)
          WHERE s.store_id = p_store_id
        )
      )
  );
$$;

COMMIT;

SELECT 'STORE_SETUP_ROLLBACK_OK' AS result;
