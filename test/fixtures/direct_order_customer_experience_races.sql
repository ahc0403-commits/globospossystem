-- Two real transactions deliberately overlap request and customer-session writes.
-- Disposable database only; no production/customer data or push tokens.
DO $$ BEGIN IF current_database()<>'codex_direct_photo' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF; END $$;
CREATE SCHEMA feedback_race;
CREATE FUNCTION feedback_race.request_id() RETURNS uuid LANGUAGE sql AS $$
 SELECT (fixture->>'request_id')::uuid FROM fallback_test.races WHERE operation='dispatch'
$$;
CREATE FUNCTION feedback_race.staff_event() RETURNS void LANGUAGE plpgsql AS $$
DECLARE rid uuid:=feedback_race.request_id(); i integer:=0;
BEGIN
 PERFORM 1 FROM public.direct_order_requests WHERE id=rid FOR UPDATE;
 PERFORM pg_advisory_xact_lock(8675309); -- observable transaction latch
 -- Wait until the customer holds last_seen_at's session lock and is blocked
 -- on this request. This exposes the old cycle deterministically.
 WHILE NOT EXISTS(SELECT 1 FROM pg_stat_activity
   WHERE application_name='direct-customer-session-race' AND wait_event='transactionid') LOOP
  PERFORM pg_sleep(0.05); i:=i+1;
  IF i>100 THEN RAISE EXCEPTION 'CUSTOMER_SESSION_RACE_DID_NOT_OVERLAP'; END IF;
 END LOOP;
 PERFORM public.direct_order_enqueue_customer_event(rid,'driver_handoff');
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_customer_events WHERE request_id=rid AND event_kind='driver_handoff') THEN
  RAISE EXCEPTION 'CUSTOMER_SESSION_RACE_EVENT_MISSING';
 END IF;
END $$;
CREATE FUNCTION feedback_race.customer_activity() RETURNS void LANGUAGE plpgsql AS $$
DECLARE rid uuid:=feedback_race.request_id(); sid uuid; secret text; i integer:=0;
BEGIN
 SELECT r.session_id,s.secret_hash INTO sid,secret FROM public.direct_order_requests r
 JOIN public.direct_order_sessions s ON s.id=r.session_id WHERE r.id=rid;
 WHILE NOT EXISTS(SELECT 1 FROM pg_locks WHERE locktype='advisory' AND objid=8675309 AND granted) LOOP
  PERFORM pg_sleep(0.05); i:=i+1;
  IF i>100 THEN RAISE EXCEPTION 'CUSTOMER_SESSION_STAFF_LATCH_MISSING'; END IF;
 END LOOP;
 PERFORM public.direct_order_validate_session(sid,secret);
 PERFORM 1 FROM public.direct_order_requests WHERE id=rid FOR UPDATE;
END $$;
