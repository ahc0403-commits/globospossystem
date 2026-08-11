-- Keep the 22:25 Photo Objet reporting target observable without turning a
-- delayed external scheduler into permanent data loss. Exact-slot identity,
-- interval validation, lease ownership, and six-store completeness remain
-- fail closed; only wall-clock admission deadlines are removed.

CREATE OR REPLACE FUNCTION public.photo_objet_claim_daily_execution(
  p_slot_date_hcm date,
  p_slot_time_hcm time,
  p_owner_token text,
  p_executor_role text
)
RETURNS TABLE (
  lease_acquired boolean,
  execution_status text,
  server_now timestamptz,
  lease_expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now timestamptz := statement_timestamp();
  v_scheduled_at timestamptz;
  v_backup_at timestamptz;
  v_row public.photo_objet_daily_executions%ROWTYPE;
BEGIN
  IF p_slot_date_hcm IS NULL OR p_slot_time_hcm <> TIME '22:00' THEN
    RAISE EXCEPTION 'PHOTO_DAILY_EXECUTION_SLOT_INVALID';
  END IF;
  IF p_owner_token IS NULL OR length(p_owner_token) NOT BETWEEN 3 AND 200 THEN
    RAISE EXCEPTION 'PHOTO_DAILY_EXECUTION_OWNER_INVALID';
  END IF;
  IF p_executor_role NOT IN ('primary', 'backup') THEN
    RAISE EXCEPTION 'PHOTO_DAILY_EXECUTION_ROLE_INVALID';
  END IF;

  v_scheduled_at := (p_slot_date_hcm + p_slot_time_hcm)
    AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_backup_at := v_scheduled_at + interval '1 minute';

  SELECT * INTO v_row
  FROM public.photo_objet_daily_executions execution
  WHERE execution.slot_date_hcm = p_slot_date_hcm
  FOR UPDATE;

  IF FOUND AND v_row.status = 'report_ready' THEN
    RETURN QUERY SELECT false, 'report_ready'::text, v_now, v_row.lease_expires_at;
    RETURN;
  END IF;
  IF v_now < v_scheduled_at
     OR (p_executor_role = 'backup' AND v_now < v_backup_at) THEN
    RETURN QUERY SELECT false, 'waiting'::text, v_now,
      coalesce(v_row.lease_expires_at, v_scheduled_at);
    RETURN;
  END IF;

  IF NOT FOUND THEN
    INSERT INTO public.photo_objet_daily_executions (
      slot_date_hcm, slot_time_hcm, status, owner_token, executor_role,
      lease_expires_at, started_at, heartbeat_at
    ) VALUES (
      p_slot_date_hcm, p_slot_time_hcm, 'running', p_owner_token,
      p_executor_role, v_now + interval '30 seconds', v_now, v_now
    )
    ON CONFLICT (slot_date_hcm) DO NOTHING;
  END IF;

  UPDATE public.photo_objet_daily_executions execution
  SET status = 'running',
      owner_token = p_owner_token,
      executor_role = p_executor_role,
      lease_expires_at = v_now + interval '30 seconds',
      started_at = CASE
        WHEN execution.owner_token = p_owner_token THEN execution.started_at
        ELSE v_now
      END,
      heartbeat_at = v_now,
      failed_at = NULL,
      failure_message = NULL,
      updated_at = v_now
  WHERE execution.slot_date_hcm = p_slot_date_hcm
    AND execution.slot_time_hcm = p_slot_time_hcm
    AND execution.status <> 'report_ready'
    AND (
      execution.owner_token = p_owner_token
      OR execution.status = 'failed'
      OR execution.lease_expires_at <= v_now
    )
  RETURNING execution.* INTO v_row;

  IF FOUND THEN
    RETURN QUERY SELECT true, 'running'::text, v_now, v_row.lease_expires_at;
  ELSE
    SELECT * INTO v_row
    FROM public.photo_objet_daily_executions execution
    WHERE execution.slot_date_hcm = p_slot_date_hcm;
    RETURN QUERY SELECT false, coalesce(v_row.status, 'waiting'), v_now,
      coalesce(v_row.lease_expires_at, v_scheduled_at);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.photo_objet_heartbeat_daily_execution(
  p_slot_date_hcm date,
  p_slot_time_hcm time,
  p_owner_token text
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now timestamptz := statement_timestamp();
  v_expiry timestamptz;
BEGIN
  IF p_slot_date_hcm IS NULL OR p_slot_time_hcm <> TIME '22:00' THEN
    RAISE EXCEPTION 'PHOTO_DAILY_EXECUTION_SLOT_INVALID';
  END IF;
  UPDATE public.photo_objet_daily_executions execution
  SET heartbeat_at = v_now,
      lease_expires_at = v_now + interval '30 seconds',
      updated_at = v_now
  WHERE execution.slot_date_hcm = p_slot_date_hcm
    AND execution.slot_time_hcm = p_slot_time_hcm
    AND execution.owner_token = p_owner_token
    AND execution.status = 'running'
  RETURNING execution.lease_expires_at INTO v_expiry;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PHOTO_DAILY_EXECUTION_LEASE_LOST';
  END IF;
  RETURN v_expiry;
END;
$$;

CREATE OR REPLACE FUNCTION public.photo_objet_finalize_daily_report(
  p_slot_date_hcm date,
  p_slot_time_hcm time,
  p_owner_token text
)
RETURNS TABLE (
  report_status text,
  ready_at timestamptz,
  store_count integer,
  receipt_count integer,
  total_amount bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now timestamptz := statement_timestamp();
  v_scheduled_at timestamptz;
  v_required_stores integer;
  v_valid_runs integer;
  v_receipts integer;
  v_total bigint;
  v_run_ids uuid[];
BEGIN
  IF p_slot_date_hcm IS NULL OR p_slot_time_hcm <> TIME '22:00' THEN
    RAISE EXCEPTION 'PHOTO_REPORT_SLOT_INVALID';
  END IF;
  v_scheduled_at := (p_slot_date_hcm + p_slot_time_hcm)
    AT TIME ZONE 'Asia/Ho_Chi_Minh';
  IF v_now < v_scheduled_at THEN
    RAISE EXCEPTION 'PHOTO_REPORT_READY_TOO_EARLY';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.photo_objet_daily_executions execution
    WHERE execution.slot_date_hcm = p_slot_date_hcm
      AND execution.slot_time_hcm = p_slot_time_hcm
      AND execution.owner_token = p_owner_token
      AND execution.status = 'running'
      AND execution.lease_expires_at > v_now
  ) THEN
    RAISE EXCEPTION 'PHOTO_DAILY_EXECUTION_LEASE_LOST';
  END IF;

  SELECT count(*) INTO v_required_stores
  FROM public.photo_objet_monitoring_policies policy
  JOIN public.restaurants store ON store.id = policy.store_id
  WHERE policy.schedule_version = 'hcm-eod-2200-v4'
    AND policy.is_enabled = true
    AND store.is_active = true
    AND v_scheduled_at >= policy.effective_from
    AND (policy.effective_to IS NULL OR v_scheduled_at < policy.effective_to);
  IF v_required_stores <> 6 THEN
    RAISE EXCEPTION 'PHOTO_REPORT_REQUIRED_STORE_COUNT_INVALID: %', v_required_stores;
  END IF;

  SELECT count(*), array_agg(run.id ORDER BY slot.store_id)
  INTO v_valid_runs, v_run_ids
  FROM public.photo_objet_monitoring_policies policy
  JOIN public.restaurants store ON store.id = policy.store_id AND store.is_active = true
  JOIN public.photo_objet_expected_slots slot
    ON slot.monitoring_policy_id = policy.id
   AND slot.store_id = policy.store_id
   AND slot.slot_date_hcm = p_slot_date_hcm
   AND slot.slot_time_hcm = p_slot_time_hcm
   AND slot.status IN ('collected', 'collected_zero', 'recovered')
  JOIN public.photo_objet_sales_pull_runs run
    ON run.id = slot.successful_run_id
   AND run.store_id = slot.store_id
   AND run.run_source = 'scheduled'
   AND run.status = 'success'
   AND run.slot_date_hcm = p_slot_date_hcm
   AND run.slot_time_hcm = p_slot_time_hcm
   AND run.interval_start_at = p_slot_date_hcm::timestamp
       AT TIME ZONE 'Asia/Ho_Chi_Minh'
   AND run.interval_end_at = v_scheduled_at
   AND run.interval_rows IS NOT NULL
   AND run.finished_at IS NOT NULL
  WHERE policy.schedule_version = 'hcm-eod-2200-v4'
    AND policy.is_enabled = true
    AND v_scheduled_at >= policy.effective_from
    AND (policy.effective_to IS NULL OR v_scheduled_at < policy.effective_to);
  IF v_valid_runs <> v_required_stores THEN
    RAISE EXCEPTION 'PHOTO_REPORT_NOT_READY: %/% valid stores',
      v_valid_runs, v_required_stores;
  END IF;

  SELECT count(*)::integer, coalesce(sum(raw.amount), 0)::bigint
  INTO v_receipts, v_total
  FROM public.photo_objet_sales_raw raw
  JOIN public.photo_objet_monitoring_policies policy ON policy.store_id = raw.store_id
  WHERE policy.schedule_version = 'hcm-eod-2200-v4'
    AND policy.is_enabled = true
    AND v_scheduled_at >= policy.effective_from
    AND (policy.effective_to IS NULL OR v_scheduled_at < policy.effective_to)
    AND raw.sold_at >= p_slot_date_hcm::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'
    AND raw.sold_at < v_scheduled_at;

  UPDATE public.photo_objet_daily_executions execution
  SET status = 'report_ready',
      report_ready_at = v_now,
      store_count = v_required_stores,
      receipt_count = v_receipts,
      total_amount = v_total,
      successful_run_ids = v_run_ids,
      failure_message = NULL,
      updated_at = v_now
  WHERE execution.slot_date_hcm = p_slot_date_hcm
    AND execution.owner_token = p_owner_token;

  RETURN QUERY SELECT 'report_ready'::text, v_now,
    v_required_stores, v_receipts, v_total;
END;
$$;

CREATE OR REPLACE FUNCTION public.photo_objet_sales_export_runs(
  p_sale_date date
)
RETURNS TABLE (
  store_id uuid,
  slot_time_hcm time,
  successful_run_id uuid,
  interval_start_at timestamptz,
  interval_end_at timestamptz,
  interval_rows integer
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
  SELECT slot.store_id, slot.slot_time_hcm, run.id,
    run.interval_start_at, run.interval_end_at, run.interval_rows
  FROM public.photo_objet_expected_slots slot
  JOIN public.photo_objet_sales_pull_runs run
    ON run.id = slot.successful_run_id
   AND run.store_id = slot.store_id
   AND run.run_source = 'scheduled'
   AND run.status = 'success'
   AND run.slot_date_hcm = slot.slot_date_hcm
   AND run.slot_time_hcm = slot.slot_time_hcm
   AND run.interval_start_at = slot.slot_date_hcm::timestamp
       AT TIME ZONE 'Asia/Ho_Chi_Minh'
   AND run.interval_end_at = (slot.slot_date_hcm + slot.slot_time_hcm)
       AT TIME ZONE 'Asia/Ho_Chi_Minh'
   AND run.interval_rows IS NOT NULL
   AND run.finished_at IS NOT NULL
  WHERE slot.slot_date_hcm = p_sale_date
    AND slot.status IN ('collected', 'collected_zero', 'recovered')
    AND public.photo_objet_daily_report_is_ready(p_sale_date)
$$;

REVOKE ALL ON FUNCTION public.photo_objet_claim_daily_execution(date, time, text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.photo_objet_heartbeat_daily_execution(date, time, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.photo_objet_finalize_daily_report(date, time, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.photo_objet_sales_export_runs(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.photo_objet_claim_daily_execution(date, time, text, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.photo_objet_heartbeat_daily_execution(date, time, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.photo_objet_finalize_daily_report(date, time, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.photo_objet_sales_export_runs(date)
  TO authenticated, service_role;

COMMENT ON TABLE public.photo_objet_daily_executions IS
  'One exact 22:00 HCM lease per business date. report_ready_at preserves SLA timing while delayed exact-slot recovery remains admissible.';
COMMENT ON FUNCTION public.photo_objet_claim_daily_execution(date, time, text, text) IS
  'Claims an exact-date 22:00 lease at or after the slot boundary; scheduler delay never converts into permanent data loss.';
