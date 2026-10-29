BEGIN;
SET LOCAL request.headers='{"x-test-actor":"20000000-0000-0000-0000-000000000003"}';
SET LOCAL ROLE authenticated;
DO $$ DECLARE sid uuid; response jsonb; scoped jsonb; employee uuid; count_n integer:=0; BEGIN
 FOR sid IN SELECT ('10000000-0000-0000-0000-'||lpad(g::text,12,'0'))::uuid FROM generate_series(1,7)g LOOP
  response:=public.get_financial_input_page('staff',ARRAY[sid]);
  ASSERT (response->>'total_count')::integer=1,'STAFF_COUNT_WRONG';
  ASSERT NOT response->'rows'->0 ? 'bank_account_number','BANK_FIELD_EXPOSED';
  ASSERT (response->'rows'->0->>'photo_policy')::boolean=(sid>'10000000-0000-0000-0000-000000000002'::uuid),'PHOTO_POLICY_LOST';
  employee:=(response->'rows'->0->>'id')::uuid;
  scoped:=public.get_employee_financial_input_page('staff',employee,ARRAY[sid]);
  ASSERT (scoped->>'total_count')::integer=1,'SCOPED_EMPLOYEE_MISSING';
  PERFORM public.admin_record_employee_attendance(sid,employee,'clock_in',now()-interval '2 hours','Fixture missing clock in','2468');
  PERFORM public.admin_record_employee_attendance(sid,employee,'clock_out',now()-interval '1 hour','Fixture missing clock out','2468');
  count_n:=count_n+1;
 END LOOP;
 ASSERT count_n=7,'STORE_COVERAGE_WRONG';
 ASSERT NOT has_table_privilege('authenticated','public.v_financial_payroll_staff','SELECT'),'PRIVATE_VIEW_EXPOSED';
 RAISE NOTICE 'AFTER=PASS staff_read employee_read manual_clock_in_out stores=7 private_view_preserved bank_fields_absent';
END $$;
RESET ROLE;
SET LOCAL request.headers='{"x-test-actor":"20000000-0000-0000-0000-000000000005"}';
SET LOCAL ROLE authenticated;
DO $$ DECLARE sid uuid:='10000000-0000-0000-0000-000000000003'; employee uuid; row_n jsonb; BEGIN
 row_n:=public.get_financial_input_page('staff',ARRAY[sid]);employee:=(row_n->'rows'->0->>'id')::uuid;
 PERFORM public.admin_record_employee_attendance(sid,employee,'clock_in',now()-interval '3 hours','Photo manager fixture','2468');
 BEGIN PERFORM public.admin_record_employee_attendance(sid,employee,'clock_out',now()-interval '2 hours','Wrong PIN fixture','0000'); RAISE EXCEPTION 'BAD_PIN_ALLOWED'; EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DISCOUNT_PIN_REJECTED' THEN RAISE; END IF; END;
 BEGIN PERFORM public.get_financial_input_page('staff',ARRAY['10000000-0000-0000-0000-000000000001'::uuid]); RAISE EXCEPTION 'CROSS_STORE_READ'; EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'FINANCIAL_INPUT_FORBIDDEN' THEN RAISE; END IF; END;
 BEGIN PERFORM public.admin_record_employee_attendance('10000000-0000-0000-0000-000000000001',employee,'clock_in',now()-interval '4 hours','Cross store fixture','2468'); RAISE EXCEPTION 'CROSS_STORE_WRITE'; EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'ATTENDANCE_MANUAL_ENTRY_FORBIDDEN' THEN RAISE; END IF; END;
 RAISE NOTICE 'PHOTO_MANAGER=PASS scoped_manual_entry pin_enforced cross_store_denied';
END $$;
RESET ROLE;
DO $$ BEGIN
 ASSERT EXISTS(SELECT 1 FROM audit_logs WHERE action='attendance_manual_entry' AND actor_id='20000000-0000-0000-0000-000000000005'),'AUTH_AUDIT_ACTOR_WRONG';
 ASSERT NOT EXISTS(SELECT 1 FROM audit_logs WHERE actor_id='20000000-0000-0000-0000-000000000006'),'WORKFORCE_ID_USED_FOR_AUTH_AUDIT';
END $$;
SET LOCAL request.headers='{"x-test-actor":"20000000-0000-0000-0000-000000000002"}';
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 ASSERT public.get_financial_input_page('staff',ARRAY['10000000-0000-0000-0000-000000000001'::uuid])->>'total_count'='0','WORKFORCE_RLS_CHANGED';
END $$;
RESET ROLE;
UPDATE restaurant_settings SET settings_json='{}' WHERE restaurant_id='10000000-0000-0000-0000-000000000003';
SET LOCAL request.headers='{"x-test-actor":"20000000-0000-0000-0000-000000000005"}';
SET LOCAL ROLE authenticated;
DO $$ DECLARE employee uuid; BEGIN
 employee:=(public.get_financial_input_page('staff',ARRAY['10000000-0000-0000-0000-000000000003'::uuid])->'rows'->0->>'id')::uuid;
 BEGIN PERFORM public.admin_record_employee_attendance('10000000-0000-0000-0000-000000000003',employee,'clock_in',now()-interval '5 hours','Missing PIN fixture','2468'); RAISE EXCEPTION 'MISSING_PIN_ALLOWED'; EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DISCOUNT_PIN_NOT_CONFIGURED' THEN RAISE; END IF; END;
 RAISE NOTICE 'PERMISSIONS=PASS worker_rls_preserved auth_audit_actor missing_pin_denied';
END $$;
RESET ROLE;
INSERT INTO store_employees(id,store_id,full_name,employee_number,employment_role,is_active)
SELECT gen_random_uuid(),'10000000-0000-0000-0000-000000000001','Paging fixture','PAGE'||g,'part_timer',true FROM generate_series(1,500)g;
SET LOCAL request.headers='{"x-test-actor":"20000000-0000-0000-0000-000000000003"}';
SET LOCAL ROLE authenticated;
DO $$ DECLARE first_page jsonb; second_page jsonb; started timestamptz:=clock_timestamp(); BEGIN
 first_page:=public.get_financial_input_page('staff',ARRAY['10000000-0000-0000-0000-000000000001'::uuid]);
 ASSERT first_page->>'total_count'='501' AND first_page->>'has_more'='true','FIRST_PAGE_COUNT_WRONG';
 second_page:=public.get_financial_input_page('staff',ARRAY['10000000-0000-0000-0000-000000000001'::uuid],p_cursor=>first_page->'rows'->499->'_cursor',p_expected_revision=>first_page->>'revision');
 ASSERT second_page->>'has_more'='false' AND jsonb_array_length(second_page->'rows')=1 AND second_page->>'revision'=first_page->>'revision','FINAL_PAGE_INCOMPLETE';
 RAISE NOTICE 'PAGING=PASS rows=501 rpc_calls=2 first_bytes=% final_bytes=% local_db_ms=%',octet_length(first_page::text),octet_length(second_page::text),round(extract(epoch FROM clock_timestamp()-started)*1000,3);
END $$;
ROLLBACK;
