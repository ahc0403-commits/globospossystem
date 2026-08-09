BEGIN;

-- The always-on native print station must not reuse an administrator,
-- cashier, or kitchen identity. This role is store-scoped and can only run
-- the durable print queue through the existing guarded RPCs.
ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_account_type_check;
ALTER TABLE public.users
  ADD CONSTRAINT users_account_type_check CHECK (account_type IN (
    'legacy_user', 'master', 'brand_manager', 'store_manager',
    'device_pos', 'device_tablet', 'device_kitchen',
    'device_print_station', 'store_operator'
  ));

ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE public.users
  ADD CONSTRAINT users_role_check CHECK (role IN (
    'super_admin', 'master_admin', 'brand_admin', 'store_admin', 'admin',
    'waiter', 'kitchen', 'cashier', 'print_station',
    'photo_objet_master', 'photo_objet_store_admin',
    'photo_objet_store_operator'
  ));

ALTER TABLE public.store_fixed_account_requirements
  DROP CONSTRAINT IF EXISTS store_fixed_account_requirements_type_check;
ALTER TABLE public.store_fixed_account_requirements
  ADD CONSTRAINT store_fixed_account_requirements_type_check CHECK (
    account_type IN (
      'brand_manager', 'store_manager', 'device_pos', 'device_tablet',
      'device_kitchen', 'device_print_station', 'store_operator'
    )
  );

ALTER TABLE public.store_fixed_account_requirements
  DROP CONSTRAINT IF EXISTS store_fixed_account_requirements_role_check;
ALTER TABLE public.store_fixed_account_requirements
  ADD CONSTRAINT store_fixed_account_requirements_role_check CHECK (role IN (
    'brand_admin', 'store_admin', 'cashier', 'kitchen', 'print_station',
    'photo_objet_master', 'photo_objet_store_operator'
  ));

ALTER TABLE public.store_fixed_account_requirements
  DROP CONSTRAINT IF EXISTS store_fixed_account_requirements_role_type_check;
ALTER TABLE public.store_fixed_account_requirements
  ADD CONSTRAINT store_fixed_account_requirements_role_type_check CHECK (
    (account_type = 'brand_manager'
      AND role IN ('brand_admin', 'photo_objet_master')
      AND scope = 'brand')
    OR (account_type = 'store_manager'
      AND role = 'store_admin' AND scope = 'store')
    OR (account_type IN ('device_pos', 'device_tablet')
      AND role = 'cashier' AND scope = 'store')
    OR (account_type = 'device_kitchen'
      AND role = 'kitchen' AND scope = 'store')
    OR (account_type = 'device_print_station'
      AND role = 'print_station' AND scope = 'store')
    OR (account_type = 'store_operator'
      AND role = 'photo_objet_store_operator' AND scope = 'store')
  );

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
        'print_station',
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
  'Authorizes store-scoped native print agents, including the dedicated print_station role.';

DO $account$
DECLARE
  v_store_id constant uuid := '8bc9eef5-dcd5-46b1-b931-23f77132322c';
  v_existing public.store_fixed_account_requirements%ROWTYPE;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.restaurants
    WHERE id = v_store_id
      AND is_active = true
  ) THEN
    RAISE EXCEPTION 'PRINT_STATION_ACCOUNT_STORE_UNAVAILABLE';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.store_fixed_account_requirements
  WHERE store_id = v_store_id
    AND account_code = 'print';

  IF FOUND THEN
    IF v_existing.account_type IS DISTINCT FROM 'device_print_station'
       OR v_existing.role IS DISTINCT FROM 'print_station'
       OR v_existing.scope IS DISTINCT FROM 'store' THEN
      RAISE EXCEPTION 'PRINT_STATION_ACCOUNT_REQUIREMENT_CONFLICT';
    END IF;
  ELSE
    INSERT INTO public.store_fixed_account_requirements (
      store_id,
      account_code,
      account_type,
      role,
      display_name,
      scope,
      is_active
    ) VALUES (
      v_store_id,
      'print',
      'device_print_station',
      'print_station',
      'Print Station',
      'store',
      true
    );
  END IF;
END;
$account$;

COMMIT;
