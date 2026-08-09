BEGIN;

-- production-gate: self-verifying

-- A customer-facing tablet is a dedicated, read-only device identity. It may
-- only observe the single payment snapshot explicitly published by a cashier.
ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_account_type_check;
ALTER TABLE public.users
  ADD CONSTRAINT users_account_type_check CHECK (account_type IN (
    'legacy_user', 'master', 'brand_manager', 'store_manager',
    'device_pos', 'device_tablet', 'device_kitchen',
    'device_print_station', 'device_customer_display', 'store_operator'
  ));

ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE public.users
  ADD CONSTRAINT users_role_check CHECK (role IN (
    'super_admin', 'master_admin', 'brand_admin', 'store_admin', 'admin',
    'waiter', 'kitchen', 'cashier', 'print_station', 'customer_display',
    'photo_objet_master', 'photo_objet_store_admin',
    'photo_objet_store_operator'
  ));

ALTER TABLE public.store_fixed_account_requirements
  DROP CONSTRAINT IF EXISTS store_fixed_account_requirements_type_check;
ALTER TABLE public.store_fixed_account_requirements
  ADD CONSTRAINT store_fixed_account_requirements_type_check CHECK (
    account_type IN (
      'brand_manager', 'store_manager', 'device_pos', 'device_tablet',
      'device_kitchen', 'device_print_station', 'device_customer_display',
      'store_operator'
    )
  );

ALTER TABLE public.store_fixed_account_requirements
  DROP CONSTRAINT IF EXISTS store_fixed_account_requirements_role_check;
ALTER TABLE public.store_fixed_account_requirements
  ADD CONSTRAINT store_fixed_account_requirements_role_check CHECK (role IN (
    'brand_admin', 'store_admin', 'cashier', 'kitchen', 'print_station',
    'customer_display', 'photo_objet_master', 'photo_objet_store_operator'
  ));

ALTER TABLE public.store_fixed_account_requirements
  DROP CONSTRAINT IF EXISTS store_fixed_account_requirements_role_type_check;
ALTER TABLE public.store_fixed_account_requirements
  ADD CONSTRAINT store_fixed_account_requirements_role_type_check CHECK (
    (account_type = 'brand_manager'
      AND role IN ('brand_admin', 'photo_objet_master') AND scope = 'brand')
    OR (account_type = 'store_manager'
      AND role = 'store_admin' AND scope = 'store')
    OR (account_type IN ('device_pos', 'device_tablet')
      AND role = 'cashier' AND scope = 'store')
    OR (account_type = 'device_kitchen'
      AND role = 'kitchen' AND scope = 'store')
    OR (account_type = 'device_print_station'
      AND role = 'print_station' AND scope = 'store')
    OR (account_type = 'device_customer_display'
      AND role = 'customer_display' AND scope = 'store')
    OR (account_type = 'store_operator'
      AND role = 'photo_objet_store_operator' AND scope = 'store')
  );

CREATE TABLE public.customer_payment_displays (
  store_id uuid PRIMARY KEY REFERENCES public.restaurants(id) ON DELETE CASCADE,
  order_id uuid REFERENCES public.orders(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'idle'
    CHECK (status IN ('idle', 'showing')),
  payload jsonb,
  shown_by_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  shown_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT customer_payment_displays_state_check CHECK (
    (status = 'idle' AND order_id IS NULL AND payload IS NULL)
    OR (
      status = 'showing'
      AND order_id IS NOT NULL
      AND payload IS NOT NULL
      AND jsonb_typeof(payload) = 'object'
      AND payload ? 'order_id'
      AND payload ? 'items'
      AND payload ? 'total'
      AND payload->>'order_id' = order_id::text
      AND jsonb_typeof(payload->'items') = 'array'
      AND jsonb_typeof(payload->'total') = 'number'
    )
  )
);

ALTER TABLE public.customer_payment_displays ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.customer_payment_displays
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.customer_payment_displays TO authenticated;

CREATE POLICY customer_payment_displays_select_own_store
  ON public.customer_payment_displays
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.auth_id = auth.uid()
        AND u.is_active = true
        AND u.role = 'customer_display'
        AND EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) s(store_id)
          WHERE s.store_id = customer_payment_displays.store_id
        )
    )
  );

CREATE OR REPLACE FUNCTION public.show_customer_payment_display(
  p_store_id uuid,
  p_order_id uuid,
  p_payload jsonb
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) OR (
    v_actor.role <> 'super_admin'
    AND NOT EXISTS (
      SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id = p_store_id
    )
  ) THEN
    RAISE EXCEPTION 'CUSTOMER_DISPLAY_PUBLISH_FORBIDDEN';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.id = p_order_id
      AND o.restaurant_id = p_store_id
      AND o.status = 'serving'
  ) THEN
    RAISE EXCEPTION 'CUSTOMER_DISPLAY_ORDER_UNAVAILABLE';
  END IF;

  IF p_payload IS NULL
     OR jsonb_typeof(p_payload) <> 'object'
     OR p_payload->>'order_id' IS DISTINCT FROM p_order_id::text
     OR jsonb_typeof(p_payload->'items') IS DISTINCT FROM 'array'
     OR jsonb_typeof(p_payload->'total') IS DISTINCT FROM 'number'
     OR (p_payload->>'total')::numeric < 0 THEN
    RAISE EXCEPTION 'CUSTOMER_DISPLAY_PAYLOAD_INVALID';
  END IF;

  INSERT INTO public.customer_payment_displays (
    store_id, order_id, status, payload, shown_by_user_id, shown_at, updated_at
  ) VALUES (
    p_store_id, p_order_id, 'showing', p_payload, v_actor.id, now(), now()
  )
  ON CONFLICT (store_id) DO UPDATE SET
    order_id = EXCLUDED.order_id,
    status = EXCLUDED.status,
    payload = EXCLUDED.payload,
    shown_by_user_id = EXCLUDED.shown_by_user_id,
    shown_at = EXCLUDED.shown_at,
    updated_at = EXCLUDED.updated_at;
END;
$$;

REVOKE ALL ON FUNCTION public.show_customer_payment_display(uuid, uuid, jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.show_customer_payment_display(uuid, uuid, jsonb)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.clear_customer_payment_display(
  p_store_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) OR (
    v_actor.role <> 'super_admin'
    AND NOT EXISTS (
      SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id = p_store_id
    )
  ) THEN
    RAISE EXCEPTION 'CUSTOMER_DISPLAY_CLEAR_FORBIDDEN';
  END IF;

  UPDATE public.customer_payment_displays
  SET order_id = NULL,
      status = 'idle',
      payload = NULL,
      shown_by_user_id = NULL,
      shown_at = NULL,
      updated_at = now()
  WHERE store_id = p_store_id;
END;
$$;

REVOKE ALL ON FUNCTION public.clear_customer_payment_display(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.clear_customer_payment_display(uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.clear_terminal_customer_payment_display()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF NEW.status IN ('completed', 'cancelled')
     AND OLD.status IS DISTINCT FROM NEW.status THEN
    UPDATE public.customer_payment_displays
    SET order_id = NULL,
        status = 'idle',
        payload = NULL,
        shown_by_user_id = NULL,
        shown_at = NULL,
        updated_at = now()
    WHERE store_id = NEW.restaurant_id
      AND order_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER clear_terminal_customer_payment_display
AFTER UPDATE OF status ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.clear_terminal_customer_payment_display();

ALTER TABLE public.customer_payment_displays REPLICA IDENTITY FULL;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'customer_payment_displays'
  ) THEN
    ALTER PUBLICATION supabase_realtime
      ADD TABLE public.customer_payment_displays;
  END IF;
END;
$$;

DO $account$
DECLARE
  v_store_id constant uuid := '8bc9eef5-dcd5-46b1-b931-23f77132322c';
  v_existing public.store_fixed_account_requirements%ROWTYPE;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.restaurants
    WHERE id = v_store_id AND is_active = true
  ) THEN
    RAISE EXCEPTION 'CUSTOMER_DISPLAY_ACCOUNT_STORE_UNAVAILABLE';
  END IF;

  SELECT * INTO v_existing
  FROM public.store_fixed_account_requirements
  WHERE store_id = v_store_id AND account_code = 'bt_customer';

  IF FOUND THEN
    IF v_existing.account_type IS DISTINCT FROM 'device_customer_display'
       OR v_existing.role IS DISTINCT FROM 'customer_display'
       OR v_existing.scope IS DISTINCT FROM 'store' THEN
      RAISE EXCEPTION 'CUSTOMER_DISPLAY_ACCOUNT_REQUIREMENT_CONFLICT';
    END IF;
  ELSE
    INSERT INTO public.store_fixed_account_requirements (
      store_id, account_code, account_type, role, display_name, scope, is_active
    ) VALUES (
      v_store_id, 'bt_customer', 'device_customer_display',
      'customer_display', 'Customer Display', 'store', true
    );
  END IF;
END;
$account$;

DO $verify$
BEGIN
  IF to_regclass('public.customer_payment_displays') IS NULL
     OR to_regprocedure(
       'public.show_customer_payment_display(uuid,uuid,jsonb)'
     ) IS NULL
     OR to_regprocedure(
       'public.clear_customer_payment_display(uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'CUSTOMER_DISPLAY_SCHEMA_VERIFICATION_FAILED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_class
    WHERE oid = 'public.customer_payment_displays'::regclass
      AND relrowsecurity = true
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'customer_payment_displays'
      AND policyname = 'customer_payment_displays_select_own_store'
  ) THEN
    RAISE EXCEPTION 'CUSTOMER_DISPLAY_RLS_VERIFICATION_FAILED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgrelid = 'public.orders'::regclass
      AND tgname = 'clear_terminal_customer_payment_display'
      AND NOT tgisinternal
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'customer_payment_displays'
  ) THEN
    RAISE EXCEPTION 'CUSTOMER_DISPLAY_SYNC_VERIFICATION_FAILED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.store_fixed_account_requirements
    WHERE store_id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'
      AND account_code = 'bt_customer'
      AND account_type = 'device_customer_display'
      AND role = 'customer_display'
      AND scope = 'store'
      AND is_active = true
  ) THEN
    RAISE EXCEPTION 'CUSTOMER_DISPLAY_ACCOUNT_VERIFICATION_FAILED';
  END IF;
END;
$verify$;

COMMIT;
