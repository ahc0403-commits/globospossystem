-- Reopening restores the same identity to preparation, requiring new handover
-- and field evidence. Suspending/resuming trading remains a separate transition.
-- production-gate: self-verifying
BEGIN;
CREATE TABLE public.store_reopening_events (
 id uuid PRIMARY KEY,restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
 previous_revision bigint NOT NULL,reason text NOT NULL,actor_id uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX store_reopening_events_store ON public.store_reopening_events(restaurant_id,created_at DESC);
ALTER TABLE public.store_reopening_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.store_reopening_events FROM PUBLIC,anon,authenticated;
CREATE TRIGGER store_reopening_events_immutable BEFORE UPDATE ON public.store_reopening_events FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE FUNCTION public.admin_prepare_store_reopening_v1(p_id uuid,p_store uuid,p_expected_revision bigint,p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE lifecycle store_lifecycle; prior store_reopening_events;
BEGIN
 PERFORM require_brand_admin_v1();
 IF p_id IS NULL OR length(btrim(coalesce(p_reason,''))) NOT BETWEEN 5 AND 1000 THEN RAISE EXCEPTION 'STORE_REOPEN_REASON_REQUIRED'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('store-opening:'||p_store,0));
 SELECT * INTO prior FROM store_reopening_events WHERE id=p_id;
 IF FOUND THEN
  IF prior.restaurant_id<>p_store OR prior.previous_revision<>p_expected_revision OR prior.reason<>btrim(p_reason) OR prior.actor_id<>auth.uid() THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF;
  RETURN admin_get_store_lifecycle_v1(p_store);
 END IF;
 SELECT * INTO lifecycle FROM store_lifecycle WHERE restaurant_id=p_store FOR UPDATE;
 IF NOT FOUND OR lifecycle.state<>'closed' OR lifecycle.revision<>p_expected_revision THEN RAISE EXCEPTION 'LIFECYCLE_CHANGED'; END IF;
 PERFORM 1 FROM restaurants WHERE id=p_store FOR UPDATE;
 INSERT INTO store_reopening_events VALUES(p_id,p_store,p_expected_revision,btrim(p_reason),auth.uid(),now());
 UPDATE store_lifecycle SET state='preparing',revision=revision+1,activated_source_hash=NULL,changed_by=auth.uid(),changed_at=now() WHERE restaurant_id=p_store;
 UPDATE restaurants SET is_active=true WHERE id=p_store;
 UPDATE user_store_access access SET is_active=true,updated_at=now() FROM users u WHERE access.user_id=u.id AND access.store_id=p_store AND u.is_active
 AND EXISTS(SELECT 1 FROM store_fixed_account_requirements req WHERE req.store_id=p_store AND req.provisioned_user_id=u.id AND req.is_active AND req.account_code=u.fixed_account_code AND req.role=u.role);
 PERFORM store_refresh_closed_claims_v1(p_store);
 RETURN admin_get_store_lifecycle_v1(p_store);
END $$;
DO $$ DECLARE d text; BEGIN
 d:=pg_get_functiondef('public.store_operational_source_v1(uuid)'::regprocedure);
 d:=replace(d,'''workflow'',store_workflow_source(p_store)', '''reopening'',(SELECT max(created_at) FROM store_reopening_events WHERE restaurant_id=p_store),''workflow'',store_workflow_source(p_store)'); EXECUTE d;
 d:=pg_get_functiondef('public.admin_get_store_lifecycle_before_operational(uuid)'::regprocedure);
 d:=replace(d,'h.account_snapshot=accounts)', 'h.account_snapshot=accounts AND h.created_at>=coalesce((SELECT max(created_at) FROM store_reopening_events WHERE restaurant_id=p_store_id),''-infinity''::timestamptz))'); EXECUTE d;
END $$;
REVOKE ALL ON FUNCTION public.admin_prepare_store_reopening_v1(uuid,uuid,bigint,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_prepare_store_reopening_v1(uuid,uuid,bigint,text) TO authenticated;
COMMIT;
