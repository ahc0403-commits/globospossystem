BEGIN;
SET LOCAL request.headers='{"x-test-actor":"20000000-0000-0000-0000-000000000003"}';
SET LOCAL ROLE authenticated;
DO $$ DECLARE sid uuid; failures integer:=0; BEGIN
 FOR sid IN SELECT ('10000000-0000-0000-0000-'||lpad(g::text,12,'0'))::uuid FROM generate_series(1,7)g LOOP
  BEGIN PERFORM public.get_financial_input_page('staff',ARRAY[sid]); RAISE EXCEPTION 'EXPECTED_STAFF_ERROR';
  EXCEPTION WHEN insufficient_privilege THEN
   IF SQLERRM NOT LIKE '%v_financial_payroll_staff%' THEN RAISE; END IF;
   failures:=failures+1; END;
 END LOOP;
 ASSERT failures=7,'STAFF_ERROR_NOT_REPRODUCED';
 RAISE NOTICE 'BEFORE=REPRODUCED permission_denied_private_view stores=7';
END $$;
ROLLBACK;
