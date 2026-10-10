BEGIN;
-- Does not enable or schedule MISA. A publish with an uncertain outcome is
-- parked for portal reconciliation; it is never silently published again.
ALTER TABLE public.meinvoice_jobs ADD COLUMN IF NOT EXISTS dispatch_claim_id uuid,
  ADD COLUMN IF NOT EXISTS dispatch_claim_expires_at timestamptz;
CREATE TABLE IF NOT EXISTS public.meinvoice_token_refresh_leases(
  tax_entity_id uuid PRIMARY KEY REFERENCES public.tax_entity(id),
  owner_id uuid NOT NULL, expires_at timestamptz NOT NULL
);
ALTER TABLE public.meinvoice_token_refresh_leases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.meinvoice_token_refresh_leases FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.meinvoice_token_refresh_leases TO service_role;
CREATE OR REPLACE FUNCTION public.claim_meinvoice_jobs(p_claim_id uuid,p_limit integer DEFAULT 50,p_tax_entity_id uuid DEFAULT NULL)
RETURNS SETOF public.meinvoice_jobs LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'MEINVOICE_SERVICE_REQUIRED'; END IF;
  IF p_claim_id IS NULL OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 50 THEN RAISE EXCEPTION 'MEINVOICE_BATCH_INVALID'; END IF;
  -- A worker may have sent a publish before crashing. Preserve evidence and
  -- require operator/provider reconciliation instead of reclaiming this write.
  WITH expired AS (
    UPDATE public.meinvoice_jobs SET status='manual_action_required',manual_action_type='misa_portal_review',
      error_message='DISPATCH_OUTCOME_UNKNOWN',dispatch_claim_id=NULL,dispatch_claim_expires_at=NULL,updated_at=now()
    WHERE status='pending' AND dispatch_claim_expires_at<now() RETURNING id,dispatch_attempts
  ) INSERT INTO public.meinvoice_job_events(job_id,event_type,description,retry_count)
    SELECT id,'dispatch_outcome_unknown','Expired publish ownership requires portal reconciliation',dispatch_attempts FROM expired;
  RETURN QUERY WITH candidate AS (
    SELECT id FROM public.meinvoice_jobs WHERE status='pending' AND dispatch_claim_id IS NULL
      AND (p_tax_entity_id IS NULL OR tax_entity_id=p_tax_entity_id)
      ORDER BY created_at,id LIMIT p_limit FOR UPDATE SKIP LOCKED
  ) UPDATE public.meinvoice_jobs j SET dispatch_claim_id=p_claim_id,dispatch_claim_expires_at=now()+interval '90 seconds',
    dispatch_attempts=j.dispatch_attempts+1,last_dispatch_at=now(),updated_at=now()
    FROM candidate c WHERE j.id=c.id RETURNING j.*;
END $$;
CREATE OR REPLACE FUNCTION public.complete_meinvoice_batch(p_claim_id uuid,p_results jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE v_count integer;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'MEINVOICE_SERVICE_REQUIRED'; END IF;
  IF p_claim_id IS NULL OR jsonb_typeof(p_results) IS DISTINCT FROM 'array' OR jsonb_array_length(p_results)>50
    OR (SELECT count(DISTINCT r->>'id') FROM jsonb_array_elements(p_results) r)<>jsonb_array_length(p_results)
    OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_results) r WHERE r->>'status' NOT IN
      ('pending','dispatch_paused','failed','valid_invoice','manual_action_required')) THEN RAISE EXCEPTION 'MEINVOICE_BATCH_INVALID'; END IF;
  WITH result AS (SELECT * FROM jsonb_to_recordset(p_results) r(id uuid,status text,error_message text,
    misa_ref_id text,transaction_id text,invoice_series text,invoice_number text,tax_authority_code text,
    search_code text,event_type text,metadata jsonb)), updated AS (
    UPDATE public.meinvoice_jobs j SET status=r.status,
      dispatch_attempts=j.dispatch_attempts-CASE WHEN r.status='pending' THEN 1 ELSE 0 END,
      error_message=left(r.error_message,1000),
      misa_ref_id=COALESCE(r.misa_ref_id,j.misa_ref_id),transaction_id=COALESCE(r.transaction_id,j.transaction_id),
      invoice_series=COALESCE(r.invoice_series,j.invoice_series),invoice_number=COALESCE(r.invoice_number,j.invoice_number),
      tax_authority_code=COALESCE(r.tax_authority_code,j.tax_authority_code),search_code=COALESCE(r.search_code,j.search_code),
      manual_action_type=CASE WHEN r.status='manual_action_required' THEN 'misa_portal_review' ELSE j.manual_action_type END,
      sent_at=CASE WHEN r.status='valid_invoice' THEN now() ELSE j.sent_at END,
      dispatch_claim_id=NULL,dispatch_claim_expires_at=NULL,updated_at=now()
    FROM result r WHERE j.id=r.id AND j.dispatch_claim_id=p_claim_id AND j.dispatch_claim_expires_at>now() AND j.status='pending'
      RETURNING j.id,j.dispatch_attempts,r.event_type,r.error_message,r.metadata
  ), logged AS (
    INSERT INTO public.meinvoice_job_events(job_id,event_type,description,retry_count,metadata)
    SELECT id,COALESCE(event_type,'dispatch_completed'),left(error_message,1000),dispatch_attempts,COALESCE(metadata,'{}') FROM updated RETURNING id
  ) SELECT count(*) INTO v_count FROM updated;
  RETURN v_count;
END $$;
CREATE OR REPLACE FUNCTION public.claim_meinvoice_token_refresh(p_tax_entity_id uuid,p_owner_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE v_id uuid;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'MEINVOICE_SERVICE_REQUIRED'; END IF;
  INSERT INTO public.meinvoice_token_refresh_leases VALUES(p_tax_entity_id,p_owner_id,now()+interval '30 seconds')
  ON CONFLICT(tax_entity_id) DO UPDATE SET owner_id=EXCLUDED.owner_id,expires_at=EXCLUDED.expires_at
    WHERE meinvoice_token_refresh_leases.expires_at<now() RETURNING tax_entity_id INTO v_id;
  RETURN v_id IS NOT NULL;
END $$;
REVOKE ALL ON FUNCTION public.claim_meinvoice_jobs(uuid,integer,uuid),public.complete_meinvoice_batch(uuid,jsonb),public.claim_meinvoice_token_refresh(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.claim_meinvoice_jobs(uuid,integer,uuid),public.complete_meinvoice_batch(uuid,jsonb),public.claim_meinvoice_token_refresh(uuid,uuid) TO service_role;
COMMIT;
