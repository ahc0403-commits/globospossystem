-- Admin operations for MISA meInvoice queue.
-- Keeps retry/resolve on the new meinvoice_jobs table; no WeTax writes.

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_retry_meinvoice_job(
  p_job_id uuid,
  p_store_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_job public.meinvoice_jobs%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'MEINVOICE_RETRY_FORBIDDEN';
  END IF;

  IF p_job_id IS NULL OR p_store_id IS NULL THEN
    RAISE EXCEPTION 'MEINVOICE_RETRY_INVALID';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_job
  FROM public.meinvoice_jobs mj
  WHERE mj.id = p_job_id
    AND mj.store_id = p_store_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MEINVOICE_JOB_NOT_FOUND';
  END IF;

  IF v_job.status NOT IN (
    'pending_manual_config',
    'dispatch_paused',
    'failed',
    'manual_action_required'
  ) THEN
    RAISE EXCEPTION 'MEINVOICE_JOB_NOT_RETRYABLE';
  END IF;

  UPDATE public.meinvoice_jobs
  SET status = 'pending',
      dispatch_attempts = 0,
      last_dispatch_at = NULL,
      next_retry_at = NULL,
      error_message = NULL,
      manual_action_type = NULL,
      manual_action_note = NULL,
      updated_at = now()
  WHERE id = v_job.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_retry_meinvoice_job',
    'meinvoice_jobs',
    v_job.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'previous_status', v_job.status,
      'previous_manual_action_type', v_job.manual_action_type,
      'previous_error_message', v_job.error_message
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'job_id', v_job.id,
    'provider', 'meinvoice',
    'status', 'pending'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_mark_resolved_meinvoice_job(
  p_job_id uuid,
  p_store_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_job public.meinvoice_jobs%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'MEINVOICE_RESOLVE_FORBIDDEN';
  END IF;

  IF p_job_id IS NULL OR p_store_id IS NULL THEN
    RAISE EXCEPTION 'MEINVOICE_RESOLVE_INVALID';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_job
  FROM public.meinvoice_jobs mj
  WHERE mj.id = p_job_id
    AND mj.store_id = p_store_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MEINVOICE_JOB_NOT_FOUND';
  END IF;

  IF v_job.status NOT IN ('failed', 'manual_action_required', 'dispatch_paused') THEN
    RAISE EXCEPTION 'MEINVOICE_JOB_NOT_RESOLVABLE';
  END IF;

  UPDATE public.meinvoice_jobs
  SET status = 'resolved',
      manual_action_note = COALESCE(
        NULLIF(v_job.manual_action_note, ''),
        'Marked resolved manually by POS admin after MISA portal review.'
      ),
      updated_at = now()
  WHERE id = v_job.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_mark_resolved_meinvoice_job',
    'meinvoice_jobs',
    v_job.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'previous_status', v_job.status,
      'previous_manual_action_type', v_job.manual_action_type
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'job_id', v_job.id,
    'provider', 'meinvoice',
    'status', 'resolved'
  );
END;
$$;

COMMIT;
