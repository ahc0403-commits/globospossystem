-- Deterministic wall clock for disposable direct-order contract databases.
-- Call inside a rollback transaction, or only in a database that will be
-- deleted after the test run. Never apply this file to production.
DO $guard$
BEGIN
  IF current_database() !~ '^codex_direct_' THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_TEST_REQUIRES_CODEX_DISPOSABLE_DB:%',
      current_database();
  END IF;
END;
$guard$;

DO $test_clock$
DECLARE
  v_definition text;
  v_signature text;
  v_needle text := $needle$  v_local_time := (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::time;$needle$;
  v_installed_marker text := $marker$current_setting('direct_order.test_local_time', true)$marker$;
  v_replacement text := $replacement$  v_local_time := CASE
    WHEN current_database() ~ '^codex_direct_' THEN COALESCE(
      NULLIF(current_setting('direct_order.test_local_time', true), '')::time,
      '12:00'::time
    )
    ELSE (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::time
  END;$replacement$;
BEGIN
  FOREACH v_signature IN ARRAY ARRAY[
    'public.direct_order_public_submit(uuid,text,uuid,jsonb)',
    'public.direct_order_approve_payment(uuid,uuid,numeric,text)'
  ] LOOP
    SELECT pg_get_functiondef(v_signature::regprocedure) INTO v_definition;
    IF position(v_needle IN v_definition) > 0 THEN
      EXECUTE replace(v_definition, v_needle, v_replacement);
    ELSIF position(v_installed_marker IN v_definition) = 0 THEN
      RAISE EXCEPTION 'DIRECT_DELIVERY_TEST_CLOCK_ANCHOR_DRIFT:%',
        v_signature;
    END IF;
  END LOOP;
END;
$test_clock$;
