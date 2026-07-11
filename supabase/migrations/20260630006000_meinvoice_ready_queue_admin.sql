-- Admin queue release for MISA meInvoice jobs after seller setup is ready.
-- Moves already-created jobs back to pending only; live dispatch remains gated.

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_release_meinvoice_ready_jobs(
  p_tax_entity_id uuid,
  p_limit int DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_tax_entity public.tax_entity%ROWTYPE;
  v_config public.meinvoice_tax_entity_config%ROWTYPE;
  v_limit int;
  v_released_count int := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'MEINVOICE_RELEASE_FORBIDDEN';
  END IF;

  IF p_tax_entity_id IS NULL THEN
    RAISE EXCEPTION 'MEINVOICE_RELEASE_INVALID';
  END IF;

  v_limit := LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500);

  SELECT *
  INTO v_tax_entity
  FROM public.tax_entity
  WHERE id = p_tax_entity_id
    AND einvoice_provider = 'meinvoice'
    AND tax_code <> 'PLACEHOLDER_DEV_000'
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MEINVOICE_TAX_ENTITY_NOT_FOUND';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.restaurants r
       JOIN public.user_accessible_stores(auth.uid()) s(store_id)
         ON s.store_id = r.id
       WHERE r.tax_entity_id = p_tax_entity_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_config
  FROM public.meinvoice_tax_entity_config
  WHERE tax_entity_id = p_tax_entity_id
  LIMIT 1;

  IF NOT FOUND
     OR v_config.integration_status <> 'active'
     OR NULLIF(trim(v_config.app_id), '') IS NULL
     OR NULLIF(trim(v_config.invoice_series), '') IS NULL THEN
    RAISE EXCEPTION 'MEINVOICE_RELEASE_CONFIG_INCOMPLETE';
  END IF;

  WITH candidates AS (
    SELECT mj.id
    FROM public.meinvoice_jobs mj
    WHERE mj.tax_entity_id = p_tax_entity_id
      AND mj.status IN ('pending_manual_config', 'dispatch_paused')
      AND (
        public.is_super_admin()
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) s(store_id)
          WHERE s.store_id = mj.store_id
        )
      )
    ORDER BY mj.created_at, mj.id
    LIMIT v_limit
    FOR UPDATE
  ),
  updated AS (
    UPDATE public.meinvoice_jobs mj
    SET status = 'pending',
        dispatch_attempts = 0,
        last_dispatch_at = NULL,
        next_retry_at = NULL,
        error_message = NULL,
        manual_action_type = NULL,
        manual_action_note = NULL,
        updated_at = now()
    FROM candidates c
    WHERE mj.id = c.id
    RETURNING mj.id
  )
  SELECT count(*)::int
  INTO v_released_count
  FROM updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_release_meinvoice_ready_jobs',
    'meinvoice_jobs',
    p_tax_entity_id,
    jsonb_build_object(
      'tax_code', v_tax_entity.tax_code,
      'released_count', v_released_count,
      'limit', v_limit,
      'dispatch_gate_changed', false
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'tax_entity_id', p_tax_entity_id,
    'provider', 'meinvoice',
    'released_count', v_released_count,
    'status', 'pending',
    'dispatch_gate_changed', false
  );
END;
$$;

COMMENT ON FUNCTION public.admin_release_meinvoice_ready_jobs(uuid, int) IS
  'Releases configured MISA jobs from setup/paused states back to pending. Does not enable live dispatch.';

REVOKE ALL ON FUNCTION public.admin_release_meinvoice_ready_jobs(uuid, int)
  FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_release_meinvoice_ready_jobs(uuid, int)
  TO authenticated;

COMMIT;
