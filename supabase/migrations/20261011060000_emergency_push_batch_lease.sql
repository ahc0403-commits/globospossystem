BEGIN;
ALTER TABLE public.emergency_push_deliveries ADD COLUMN IF NOT EXISTS claim_id uuid,
  ADD COLUMN IF NOT EXISTS claim_expires_at timestamptz;
CREATE OR REPLACE FUNCTION public.claim_emergency_push_batch(p_claim_id uuid, p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public,auth,pg_catalog AS $$
DECLARE v_rows jsonb;v_more boolean;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'EMERGENCY_PUSH_SERVICE_REQUIRED'; END IF;
  IF p_claim_id IS NULL OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 50 THEN RAISE EXCEPTION 'EMERGENCY_PUSH_BATCH_INVALID'; END IF;
  WITH candidate AS MATERIALIZED (
    SELECT id,created_at FROM public.emergency_push_deliveries WHERE
      ((status IN ('pending','failed') AND next_attempt_at<=now()) OR (status='sending' AND claim_expires_at<now()))
      AND attempt_count<10 ORDER BY created_at,id LIMIT p_limit+1 FOR UPDATE SKIP LOCKED
  ), selected AS (SELECT id FROM candidate ORDER BY created_at,id LIMIT p_limit), updated AS (
    UPDATE public.emergency_push_deliveries d SET status='sending',claim_id=p_claim_id,
    claim_expires_at=now()+interval '90 seconds',attempt_count=d.attempt_count+1,updated_at=now()
    FROM selected c WHERE c.id=d.id RETURNING d.*
  ) SELECT COALESCE(jsonb_agg(to_jsonb(updated) ORDER BY created_at,id),'[]'),(SELECT count(*) FROM candidate)>p_limit
    INTO v_rows,v_more FROM updated;
  RETURN jsonb_build_object('rows',v_rows,'has_more',v_more);
END $$;
CREATE OR REPLACE FUNCTION public.complete_emergency_push_batch(p_claim_id uuid,p_results jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public,auth,pg_catalog AS $$
DECLARE v_count integer;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'EMERGENCY_PUSH_SERVICE_REQUIRED'; END IF;
  IF p_claim_id IS NULL OR jsonb_typeof(p_results) IS DISTINCT FROM 'array' OR jsonb_array_length(p_results)>50
    OR (SELECT count(DISTINCT r->>'id') FROM jsonb_array_elements(p_results) r)<>jsonb_array_length(p_results)
    THEN RAISE EXCEPTION 'EMERGENCY_PUSH_BATCH_INVALID'; END IF;
  WITH result AS (SELECT * FROM jsonb_to_recordset(p_results) AS r(id uuid,accepted boolean,
    permanent boolean,deferred boolean,provider_message_id text,error text,retry_seconds integer)),
  updated AS (
    UPDATE public.emergency_push_deliveries d SET status=CASE WHEN r.accepted THEN 'sent'
      WHEN r.permanent THEN 'cancelled' WHEN r.deferred THEN 'pending' ELSE 'failed' END,
      attempt_count=d.attempt_count-CASE WHEN r.deferred THEN 1 ELSE 0 END,
      provider_message_id=r.provider_message_id,last_error=left(r.error,1000),
      next_attempt_at=now()+make_interval(secs=>LEAST(GREATEST(COALESCE(r.retry_seconds,30),5),3600)),
      claim_id=NULL,claim_expires_at=NULL,updated_at=now()
    FROM result r WHERE d.id=r.id AND d.claim_id=p_claim_id AND d.status='sending'
      AND d.claim_expires_at>now() RETURNING d.device_id,d.push_token,r.permanent,r.error
  ), disabled AS (
    UPDATE public.emergency_web_push_devices device SET is_enabled=false,updated_at=now()
    FROM updated u WHERE u.permanent AND u.error='FCM_UNREGISTERED' AND device.id=u.device_id AND device.token=u.push_token RETURNING device.id
  ) SELECT count(*) INTO v_count FROM updated;
  RETURN v_count;
END $$;
-- During a rolling deployment, a legacy worker must not finish a new owned claim.
CREATE OR REPLACE FUNCTION public.complete_emergency_push_delivery(
  p_delivery_id uuid,
  p_accepted boolean,
  p_provider_message_id text DEFAULT NULL,
  p_error text DEFAULT NULL,
  p_retry_after_seconds integer DEFAULT 30
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'EMERGENCY_PUSH_SERVICE_REQUIRED';
  END IF;
  UPDATE public.emergency_push_deliveries
  SET status = CASE WHEN p_accepted THEN 'sent' ELSE 'failed' END,
      provider_message_id = p_provider_message_id,
      last_error = CASE WHEN p_accepted THEN NULL ELSE p_error END,
      next_attempt_at = CASE WHEN p_accepted THEN next_attempt_at
        ELSE now() + make_interval(secs => LEAST(
          GREATEST(COALESCE(p_retry_after_seconds, 30), 5), 3600
        )) END,
      updated_at = now()
  WHERE id = p_delivery_id AND claim_id IS NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.claim_emergency_push_batch(uuid,integer),public.complete_emergency_push_batch(uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.claim_emergency_push_batch(uuid,integer),public.complete_emergency_push_batch(uuid,jsonb) TO service_role;
COMMIT;
