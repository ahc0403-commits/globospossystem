BEGIN;

-- The designated Windows cashier PC is also the store print agent. The queue
-- is still store-scoped and claim/complete remain SECURITY DEFINER RPCs; this
-- only allows an authenticated cashier for an accessible store to run them.
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
      AND u.role IN (
        'cashier',
        'kitchen',
        'admin',
        'store_admin',
        'super_admin'
      )
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

REVOKE ALL ON FUNCTION public.print_routing_actor_can_run(uuid)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.print_routing_actor_can_run(uuid) IS
  'Authorizes store-scoped native print agents, including the designated Windows cashier.';

COMMIT;
