-- Carry the payer in immutable print/digital snapshots and isolate old agents.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';
CREATE FUNCTION public.direct_order_enrich_recipient_print() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE context jsonb;
BEGIN
 SELECT jsonb_build_object('delivery_payment_mode',f.delivery_payment_mode,
 'delivery_policy_version',r.delivery_policy_version,'receipt_payload_version',2)
 INTO context FROM public.direct_order_financials f JOIN public.direct_order_requests r ON r.id=f.request_id
 WHERE f.order_id=NEW.order_id AND f.restaurant_id=NEW.restaurant_id;
 IF context IS NOT NULL THEN NEW.payload:=NEW.payload||context; END IF;
 RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_enrich_recipient_print() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER zzzzzz_direct_order_recipient_print BEFORE INSERT ON public.print_jobs
 FOR EACH ROW EXECUTE FUNCTION public.direct_order_enrich_recipient_print();
CREATE FUNCTION public.direct_order_enrich_recipient_digital() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE context jsonb;
BEGIN
 IF NEW.combined_payment_group_id IS NOT NULL THEN RETURN NEW; END IF;
 SELECT jsonb_build_object('delivery_payment_mode',f.delivery_payment_mode,'delivery_policy_version',r.delivery_policy_version)
 INTO context FROM public.direct_order_financials f JOIN public.direct_order_requests r ON r.id=f.request_id
 WHERE f.order_id=NEW.order_id AND f.restaurant_id=NEW.restaurant_id;
 IF context IS NOT NULL THEN NEW.snapshot:=NEW.snapshot||context; END IF;
 RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_enrich_recipient_digital() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER zzzzzz_direct_order_recipient_digital BEFORE INSERT ON public.digital_receipts
 FOR EACH ROW EXECUTE FUNCTION public.direct_order_enrich_recipient_digital();

ALTER FUNCTION public.direct_order_receipt_packing_context(uuid,uuid) RENAME TO direct_order_packing_before_recipient;
REVOKE ALL ON FUNCTION public.direct_order_packing_before_recipient(uuid,uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_receipt_packing_context(p_store_id uuid,p_order_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE v jsonb;context jsonb;
BEGIN
 v:=public.direct_order_packing_before_recipient($1,$2);
 SELECT jsonb_build_object('delivery_payment_mode',f.delivery_payment_mode,'delivery_policy_version',r.delivery_policy_version)
 INTO context FROM public.direct_order_financials f JOIN public.direct_order_requests r ON r.id=f.request_id
 WHERE f.order_id=$2 AND f.restaurant_id=$1;
 RETURN CASE WHEN context IS NULL THEN v ELSE v||context END;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_receipt_packing_context(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_receipt_packing_context(uuid,uuid) TO authenticated,service_role;

-- Upgrade only unsent jobs against their financial source. Issued snapshots stay immutable.
UPDATE public.print_jobs j SET payload=j.payload||jsonb_build_object(
 'delivery_payment_mode',f.delivery_payment_mode,'delivery_policy_version',r.delivery_policy_version,'receipt_payload_version',2)
FROM public.direct_order_financials f JOIN public.direct_order_requests r ON r.id=f.request_id
WHERE j.order_id=f.order_id AND j.restaurant_id=f.restaurant_id AND j.status IN ('pending','failed');

-- Old clients cannot interpret the new payer wording. They can still print legacy/non-direct jobs.
CREATE OR REPLACE FUNCTION public.claim_print_jobs(p_store_id uuid,p_limit int DEFAULT 10) RETURNS SETOF public.print_jobs
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
BEGIN
 IF NOT public.print_routing_actor_can_run($1) THEN RAISE EXCEPTION 'PRINT_CLAIM_FORBIDDEN'; END IF;
 RETURN QUERY WITH candidates AS(
 SELECT id FROM public.print_jobs WHERE restaurant_id=$1 AND status IN ('pending','failed')
 AND destination_id IS NOT NULL AND next_retry_at<=now() AND attempts<10 AND emergency_held_at IS NULL
 AND COALESCE((payload->>'receipt_payload_version')::integer,1)<2
 ORDER BY created_at,id LIMIT least(greatest(COALESCE($2,10),1),50) FOR UPDATE SKIP LOCKED)
 UPDATE public.print_jobs j SET status='printing',claimed_by=auth.uid(),attempts=attempts+1,updated_at=now()
 FROM candidates c WHERE j.id=c.id RETURNING j.*;
END; $$;
CREATE FUNCTION public.claim_print_jobs_v2(p_store_id uuid,p_limit int DEFAULT 10) RETURNS SETOF public.print_jobs
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
BEGIN
 IF NOT public.print_routing_actor_can_run($1) THEN RAISE EXCEPTION 'PRINT_CLAIM_FORBIDDEN'; END IF;
 RETURN QUERY WITH candidates AS(
 SELECT id FROM public.print_jobs WHERE restaurant_id=$1 AND status IN ('pending','failed')
 AND destination_id IS NOT NULL AND next_retry_at<=now() AND attempts<10 AND emergency_held_at IS NULL
 AND COALESCE((payload->>'receipt_payload_version')::integer,1)<=2
 ORDER BY created_at,id LIMIT least(greatest(COALESCE($2,10),1),50) FOR UPDATE SKIP LOCKED)
 UPDATE public.print_jobs j SET status='printing',claimed_by=auth.uid(),attempts=attempts+1,updated_at=now()
 FROM candidates c WHERE j.id=c.id RETURNING j.*;
END; $$;
REVOKE ALL ON FUNCTION public.claim_print_jobs_v2(uuid,int) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.claim_print_jobs_v2(uuid,int) TO authenticated,service_role;

DO $verify$
BEGIN
 IF has_function_privilege('anon','public.claim_print_jobs_v2(uuid,integer)','EXECUTE')
 OR NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='zzzzzz_direct_order_recipient_print' AND tgenabled='O')
 OR NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='zzzzzz_direct_order_recipient_digital' AND tgenabled='O')
 THEN RAISE EXCEPTION 'DIRECT_ORDER_RECIPIENT_RECEIPT_DRIFT'; END IF;
END; $verify$;
COMMIT;
