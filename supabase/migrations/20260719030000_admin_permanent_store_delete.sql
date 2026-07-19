-- Super Admin permanent deletion for inactive stores.
--
-- Soft deactivation remains the normal closure path because it preserves tax
-- and sales history. Permanent deletion is intentionally limited to inactive
-- stores, requires an exact slug confirmation, and refuses any store that is
-- still attached to an operational user or access grant.

DO $$
BEGIN
  IF to_regclass('public.restaurants') IS NULL
     OR to_regclass('public.users') IS NULL
     OR to_regclass('public.user_store_access') IS NULL
     OR to_regclass('public.audit_logs') IS NULL THEN
    RAISE EXCEPTION 'STORE_PURGE_RELATION_MISSING';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public._purge_inactive_store_data(
  p_store_id uuid,
  p_confirmation_slug text,
  p_actor_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_store public.restaurants%ROWTYPE;
  v_order_count bigint;
  v_payment_count bigint;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_PURGE_STORE_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_store
  FROM public.restaurants
  WHERE id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_PURGE_NOT_FOUND';
  END IF;

  IF v_store.is_active THEN
    RAISE EXCEPTION 'STORE_PURGE_REQUIRES_INACTIVE';
  END IF;

  IF btrim(coalesce(p_confirmation_slug, '')) <> v_store.slug THEN
    RAISE EXCEPTION 'STORE_PURGE_CONFIRMATION_MISMATCH';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.users
    WHERE restaurant_id = p_store_id
       OR primary_store_id = p_store_id
  ) OR EXISTS (
    SELECT 1
    FROM public.user_store_access
    WHERE store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'STORE_PURGE_HAS_ACCOUNTS';
  END IF;

  SELECT count(*) INTO v_order_count
  FROM public.orders
  WHERE restaurant_id = p_store_id;

  SELECT count(*) INTO v_payment_count
  FROM public.payments
  WHERE restaurant_id = p_store_id;

  -- Delete non-cascading descendants before their store-scoped parents.
  DELETE FROM public.einvoice_events event
  USING public.einvoice_jobs job, public.orders store_order
  WHERE event.job_id = job.id
    AND job.order_id = store_order.id
    AND store_order.restaurant_id = p_store_id;

  DELETE FROM public.einvoice_jobs job
  USING public.orders store_order
  WHERE job.order_id = store_order.id
    AND store_order.restaurant_id = p_store_id;

  DELETE FROM public.meinvoice_job_events event
  USING public.meinvoice_jobs job
  WHERE event.job_id = job.id
    AND job.store_id = p_store_id;

  DELETE FROM public.meinvoice_jobs
  WHERE store_id = p_store_id;

  DELETE FROM public.office_qc_followups
  WHERE restaurant_id = p_store_id;

  DELETE FROM public.office_payroll_reviews
  WHERE restaurant_id = p_store_id;

  DELETE FROM public.inventory_receipt_confirmation_attempts
  WHERE restaurant_id = p_store_id;

  DELETE FROM public.office_purchases
  WHERE restaurant_id = p_store_id;

  DELETE FROM public.photo_objet_expected_slots
  WHERE store_id = p_store_id;

  DELETE FROM public.photo_objet_monitoring_policies
  WHERE store_id = p_store_id;

  DELETE FROM public.employee_office_sync_outbox outbox
  USING public.store_employees employee
  WHERE outbox.employee_id = employee.id
    AND employee.store_id = p_store_id;

  DELETE FROM public.attendance_logs
  WHERE restaurant_id = p_store_id;

  DELETE FROM public.store_employees
  WHERE store_id = p_store_id;

  DELETE FROM public.store_fixed_account_requirements
  WHERE store_id = p_store_id;

  DELETE FROM public.store_employee_number_sequences
  WHERE store_id = p_store_id;

  DELETE FROM public.b2b_buyer_cache
  WHERE store_id = p_store_id;

  DELETE FROM public.store_tax_entity_history
  WHERE store_id = p_store_id;

  DELETE FROM public.restaurants
  WHERE id = p_store_id;

  INSERT INTO public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  ) VALUES (
    p_actor_id,
    'admin_purge_inactive_store',
    'restaurants',
    p_store_id,
    jsonb_build_object(
      'name', v_store.name,
      'slug', v_store.slug,
      'orders_deleted', v_order_count,
      'payments_deleted', v_payment_count,
      'deleted_at', now()
    )
  );

  RETURN jsonb_build_object(
    'store_id', p_store_id,
    'name', v_store.name,
    'slug', v_store.slug,
    'orders_deleted', v_order_count,
    'payments_deleted', v_payment_count
  );
END;
$$;

REVOKE ALL ON FUNCTION public._purge_inactive_store_data(uuid, text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_purge_inactive_store(
  p_store_id uuid,
  p_confirmation_slug text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'STORE_PURGE_FORBIDDEN';
  END IF;

  RETURN public._purge_inactive_store_data(
    p_store_id,
    p_confirmation_slug,
    auth.uid()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_purge_inactive_store(uuid, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_purge_inactive_store(uuid, text)
  TO authenticated;

COMMENT ON FUNCTION public.admin_purge_inactive_store(uuid, text) IS
  'Super Admin only: irreversibly purges one inactive store after exact slug confirmation; refuses stores with linked accounts or access grants.';

-- One-time production cleanup authorized on 2026-07-19. The guards freeze the
-- reviewed production shape: seven real active stores and 23 inactive legacy,
-- smoke, fixture, pilot, or test stores with no operational account links.
DO $$
DECLARE
  v_store record;
  v_active_count integer;
  v_inactive_count integer;
BEGIN
  SELECT count(*) FILTER (WHERE is_active),
         count(*) FILTER (WHERE NOT is_active)
  INTO v_active_count, v_inactive_count
  FROM public.restaurants;

  IF v_active_count <> 7 OR v_inactive_count <> 23 THEN
    RAISE EXCEPTION
      'STORE_PURGE_REVIEWED_SHAPE_MISMATCH active=% inactive=%',
      v_active_count,
      v_inactive_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.restaurants
    WHERE id = '0446a7e2-97d3-6a53-929c-c1849a3d12c3'::uuid
      AND slug = 'smoke-in-saigon-bowl-2'
      AND NOT is_active
  ) THEN
    RAISE EXCEPTION 'STORE_PURGE_REVIEWED_TARGET_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.users account
    JOIN public.restaurants store
      ON store.id IN (account.restaurant_id, account.primary_store_id)
    WHERE NOT store.is_active
  ) OR EXISTS (
    SELECT 1
    FROM public.user_store_access access
    JOIN public.restaurants store ON store.id = access.store_id
    WHERE NOT store.is_active
  ) THEN
    RAISE EXCEPTION 'STORE_PURGE_REVIEWED_INACTIVE_STORE_HAS_ACCOUNTS';
  END IF;

  FOR v_store IN
    SELECT id, slug
    FROM public.restaurants
    WHERE NOT is_active
    ORDER BY id
  LOOP
    PERFORM public._purge_inactive_store_data(
      v_store.id,
      v_store.slug,
      NULL
    );
  END LOOP;
END $$;
