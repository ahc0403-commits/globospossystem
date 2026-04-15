BEGIN;

CREATE OR REPLACE FUNCTION public.admin_retry_einvoice_job(
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
  v_job public.einvoice_jobs%ROWTYPE;
  v_job_store_id uuid;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'EINVOICE_RETRY_FORBIDDEN';
  END IF;

  IF p_job_id IS NULL OR p_store_id IS NULL THEN
    RAISE EXCEPTION 'EINVOICE_RETRY_INVALID';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_job
  FROM public.einvoice_jobs ej
  WHERE ej.id = p_job_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'EINVOICE_JOB_NOT_FOUND';
  END IF;

  SELECT o.restaurant_id
  INTO v_job_store_id
  FROM public.orders o
  WHERE o.id = v_job.order_id
  LIMIT 1;

  IF v_job_store_id IS DISTINCT FROM p_store_id THEN
    RAISE EXCEPTION 'EINVOICE_JOB_STORE_MISMATCH';
  END IF;

  IF v_job.status NOT IN ('failed_terminal', 'stale') THEN
    RAISE EXCEPTION 'EINVOICE_JOB_NOT_RETRYABLE';
  END IF;

  IF COALESCE(v_job.error_classification, '') IN ('duplicate_resolved', 'manual_resolved') THEN
    RAISE EXCEPTION 'EINVOICE_JOB_ALREADY_RESOLVED';
  END IF;

  UPDATE public.einvoice_jobs
  SET status = 'pending',
      dispatch_attempts = 0,
      error_classification = NULL,
      error_message = NULL,
      request_einvoice_retry_count = 0,
      request_einvoice_next_retry_at = NULL,
      updated_at = now()
  WHERE id = v_job.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_retry_einvoice_job',
    'einvoice_jobs',
    v_job.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'previous_status', v_job.status,
      'previous_error_classification', v_job.error_classification,
      'ref_id', v_job.ref_id
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'job_id', v_job.id,
    'ref_id', v_job.ref_id,
    'status', 'pending'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_mark_resolved_einvoice_job(
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
  v_job public.einvoice_jobs%ROWTYPE;
  v_job_store_id uuid;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'EINVOICE_RESOLVE_FORBIDDEN';
  END IF;

  IF p_job_id IS NULL OR p_store_id IS NULL THEN
    RAISE EXCEPTION 'EINVOICE_RESOLVE_INVALID';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_job
  FROM public.einvoice_jobs ej
  WHERE ej.id = p_job_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'EINVOICE_JOB_NOT_FOUND';
  END IF;

  SELECT o.restaurant_id
  INTO v_job_store_id
  FROM public.orders o
  WHERE o.id = v_job.order_id
  LIMIT 1;

  IF v_job_store_id IS DISTINCT FROM p_store_id THEN
    RAISE EXCEPTION 'EINVOICE_JOB_STORE_MISMATCH';
  END IF;

  IF v_job.status NOT IN ('failed_terminal', 'stale') THEN
    RAISE EXCEPTION 'EINVOICE_JOB_NOT_RESOLVABLE';
  END IF;

  IF COALESCE(v_job.error_classification, '') IN ('duplicate_resolved', 'manual_resolved') THEN
    RAISE EXCEPTION 'EINVOICE_JOB_ALREADY_RESOLVED';
  END IF;

  UPDATE public.einvoice_jobs
  SET error_classification = 'manual_resolved',
      updated_at = now()
  WHERE id = v_job.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_mark_resolved_einvoice_job',
    'einvoice_jobs',
    v_job.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'status', v_job.status,
      'previous_error_classification', v_job.error_classification,
      'ref_id', v_job.ref_id
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'job_id', v_job.id,
    'ref_id', v_job.ref_id,
    'error_classification', 'manual_resolved'
  );
END;
$$;

COMMIT;
