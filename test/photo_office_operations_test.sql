do $$ declare page jsonb; saved jsonb; again jsonb; versions jsonb;
 a uuid:='20000000-0000-0000-0000-000000000001'; b uuid:='20000000-0000-0000-0000-000000000002';
 item uuid:='50000000-0000-0000-0000-000000000001'; actor uuid:='60000000-0000-0000-0000-000000000001'; req uuid:='70000000-0000-4000-8000-000000000001';
begin
 assert not has_function_privilege('authenticated','public.office_photo_stock_count(uuid,uuid,numeric,bigint,uuid,uuid,text,numeric,numeric)','execute');
 assert not has_function_privilege('anon','public.office_photo_stock_page(uuid[],uuid)','execute');
 assert has_function_privilege('service_role','public.office_photo_stock_page(uuid[],uuid)','execute');
 page:=public.office_photo_stock_page(array[a,b]);
 assert jsonb_array_length(page->'rows')=2,'Pen is excluded';
 assert (page->'rows'->0->>'quantity')::numeric=0.5,'decimal current_stock, not quantity';
 assert (page->'rows'->1->>'quantity')::numeric=1.9;
 page:=public.office_photo_inventory_page(a);
 assert jsonb_array_length(page->'rows')=1 and page->'rows'->0->>'name'='Tissue','existing inventory route must also exclude Pen';
 page:=public.office_photo_operations_report(array[a,b],'2026-10-01','2026-10-15',array[a,b],array[a,b],array[a,b],array[a,b]);
 assert (page->'rows'->0->'inventory'->>'items')::integer=1,'existing report must share tracked POS inventory';
 assert (page->'rows'->1->'inventory'->>'items')::integer=1;

 begin perform public.office_photo_stock_page(array['20000000-0000-0000-0000-000000000003'::uuid]);raise exception 'expected denial';exception when insufficient_privilege then null;end;
 begin perform public.office_photo_on_shift(array['20000000-0000-0000-0000-000000000003'::uuid]);raise exception 'expected shift scope denial';exception when insufficient_privilege then null;end;
 begin perform public.office_photo_stock_page(null);raise exception 'expected null scope denial';exception when insufficient_privilege then null;end;
 saved:=public.office_photo_stock_count(a,item,1.9,0,req,actor,'Fixture count',2,8);
 again:=public.office_photo_stock_count(a,item,1.9,0,req,actor,'Fixture count',2,8);
 assert saved=again and (saved->>'revision')::integer=1;
 assert (select count(*)=1 from public.inventory_transactions),'one transaction after retry';
 assert (select count(*)=1 from public.inventory_physical_counts),'one count after retry';
 assert (select count(*)=1 from public.office_photo_inventory_requests where office_actor_id=actor),'Office provenance';
 begin perform public.office_photo_stock_count(a,item,3,0,gen_random_uuid(),actor,'Stale',2,8);raise exception 'expected conflict';exception when serialization_failure then null;end;
 begin perform public.office_photo_stock_count(a,item,2,1,req,actor,'Changed',2,8);raise exception 'expected request reuse denial';exception when invalid_parameter_value then null;end;
 begin perform public.office_photo_stock_count(a,item,1.2345,1,gen_random_uuid(),actor,'Precision',2,8);raise exception 'expected precision denial';exception when invalid_parameter_value then null;end;
 page:=public.office_photo_payroll_batch(array[a],'2026-10-01','2026-10-15');
 assert jsonb_array_length(page->'inputs')=1;
 assert page->'inputs'->0->'staff'->0->>'photo_policy'='true';
 assert (page->'inputs'->0->'staff'->0->'pay_policies'->0->>'standard_monthly_minutes')::integer=12480;
 versions:=page->'source_version';
 update public.employee_hourly_pay_rules set hourly_rate=25000 where store_id=a;
 begin perform public.office_photo_payroll_batch(array[a],'2026-10-01','2026-10-15',null,null,versions);raise exception 'expected changed source';exception when serialization_failure then null;end;
 page:=public.office_photo_pay_policy(a,(date_trunc('month',current_date)+interval '2 months')::date,12000,actor,'Future basis');
 assert jsonb_array_length(page)=2,'prior payroll policy preserved';
 assert (page->0->>'standard_monthly_minutes')::integer=12000;
 begin perform public.office_photo_pay_policy(a,date '2020-01-01',12000,actor,'Backdate');raise exception 'expected past-policy denial';exception when raise_exception then assert sqlerrm='PHOTO_PAY_POLICY_INVALID';end;
end $$;
-- Bounded payroll pages: 61 employees, one set query per page, no per-person RPC.
insert into public.store_employees(id,store_id,employee_number,full_name,employment_role,is_active)
select ('10000000-0000-0000-0001-'||lpad(n::text,12,'0'))::uuid,'20000000-0000-0000-0000-000000000001','S'||n,'Scale fixture','full_time',true from generate_series(1,60)n;
do $$declare p jsonb;cursor uuid;counted integer:=0;calls integer:=0;version jsonb;begin
 loop
  p:=public.office_photo_payroll_batch(array['20000000-0000-0000-0000-000000000001'::uuid],'2026-10-01','2026-10-15',cursor,null,version);
  version:=p->'source_version';calls:=calls+1;counted:=counted+jsonb_array_length(p->'inputs');
  assert jsonb_array_length(p->'inputs')<=25;
  exit when not (p->>'has_more')::boolean;
  cursor:=(p->'inputs'->(jsonb_array_length(p->'inputs')-1)->>'employee_id')::uuid;
 end loop;
 assert counted=61 and calls=3;
 raise notice 'Payroll scale fixture: employees=%, source RPC calls=%, max page=25',counted,calls;
end $$;

-- Employees who left still receive a period preview when they have work records.
insert into public.store_employees(id,store_id,employee_number,full_name,employment_role,is_active) values
('10000000-0000-0000-0002-000000000001','20000000-0000-0000-0000-000000000001','LEFT1','Former fixture','full_time',false),
('10000000-0000-0000-0002-000000000002','20000000-0000-0000-0000-000000000001','LEFT2','No work fixture','full_time',false);
insert into public.attendance_logs(id,restaurant_id,employee_id,type,logged_at) values
(gen_random_uuid(),'20000000-0000-0000-0000-000000000001','10000000-0000-0000-0002-000000000001','clock_in','2026-10-05T02:00:00Z'),
(gen_random_uuid(),'20000000-0000-0000-0000-000000000001','10000000-0000-0000-0002-000000000001','clock_out','2026-10-05T10:00:00Z');
do $$declare p jsonb;begin
 p:=public.office_photo_payroll_batch(array['20000000-0000-0000-0000-000000000001'::uuid],'2026-10-01','2026-10-15',null,'10000000-0000-0000-0002-000000000001');
 assert jsonb_array_length(p->'inputs')=1 and jsonb_array_length(p->'inputs'->0->'logs')=2,'former employee work must remain in the payroll period';
 p:=public.office_photo_payroll_batch(array['20000000-0000-0000-0000-000000000001'::uuid],'2026-09-01','2026-09-30',null,'10000000-0000-0000-0002-000000000001');
 assert jsonb_array_length(p->'inputs')=0,'do not pull former staff without work in the selected period';
 p:=public.office_photo_payroll_batch(array['20000000-0000-0000-0000-000000000001'::uuid],'2026-10-01','2026-10-15',null,'10000000-0000-0000-0002-000000000002');
 assert jsonb_array_length(p->'inputs')=0,'inactive staff without records stay excluded';
end$$;
