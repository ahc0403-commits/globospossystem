begin;
insert into restaurants select ('77000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'77000000-0000-0000-0000-000000000001',true from generate_series(102,151)n;
insert into store_employees select ('88000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,('77000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'FIXTURE-'||n,'Fixture','000000123','Fixture bank','INVALID-TEST-4567','2026-09-01','2026-10-01',now(),true from generate_series(102,151)n;
insert into inventory_items select gen_random_uuid(),id,'Fixture item',2.5,'box',3,now(),true from restaurants;
insert into photo_objet_sales select gen_random_uuid(),id,'2026-10-20',100,2,now() from restaurants cross join generate_series(1,3);
insert into daily_closings select gen_random_uuid(),id,'2026-10-20',120,180,now() from restaurants;
insert into orders select gen_random_uuid(),id,'completed','2026-10-20 10:00+07' from restaurants cross join generate_series(1,2);
insert into payment_adjustments select gen_random_uuid(),id,'void',7,'2026-10-20 11:00+07' from restaurants;
insert into payment_adjustments select gen_random_uuid(),id,'refund',9,'2026-10-20 11:00+07' from restaurants;
insert into attendance_logs select gen_random_uuid(),store_id,id,'clock_in','2026-10-20 09:00+07' from store_employees;
insert into payroll_records select gen_random_uuid(),id,'2026-10-01','2026-10-20',70,'confirmed',now() from restaurants;
insert into payroll_records select gen_random_uuid(),id,'2026-10-01','2026-10-20',5000,'draft',now() from restaurants;
do $$declare ids uuid[];r jsonb;p jsonb;begin
 select array_agg(id order by id) into ids from restaurants;
 r:=office_photo_operations_report(ids,'2026-10-01','2026-10-20',ids,ids,ids,ids);
 if jsonb_array_length(r->'rows')<>50 or (r#>>'{rows,0,finance,sales}')::numeric<>300
 or (r#>>'{rows,0,finance,cash}')::numeric<>120 or (r#>>'{rows,0,finance,orders}')::int<>2
 or (r#>>'{rows,0,finance,void_amount}')::numeric<>7 or (r#>>'{rows,0,payroll,total}')::numeric<>70
 or (r#>>'{rows,0,inventory,low_stock}')::int<>1 or (r#>>'{rows,0,attendance,working}')::int<>1 then raise exception 'AGGREGATE_MISMATCH';end if;
 r:=office_photo_operations_report(ids[1:2],'2026-10-01','2026-10-20',ids[1:1],ids[2:2],'{}','{}');
 if r#>'{rows,0,attendance}'<>'null'::jsonb or r#>'{rows,1,finance}'<>'null'::jsonb or r#>'{rows,1,payroll}'<>'null'::jsonb then raise exception 'DOMAIN_SCOPE_LEAK';end if;
 r:=office_photo_operations_report(ids[1:1],'2026-10-19','2026-10-20',ids[1:1],ids[1:1],ids[1:1],ids[1:1]);
 if r#>'{rows,0,payroll,total}'<>'null'::jsonb then raise exception 'PAYROLL_PERIOD_NOT_EXACT';end if;
 p:=office_photo_employee_profile(ids[1],(select id from store_employees where store_id=ids[1]));
 if p->>'phone_masked'<>'••••123' or p->>'bank_account_masked'<>'••••4567' or p ? 'phone' or p ? 'bank_account_number' then raise exception 'PROFILE_MASK_FAILED';end if;
 if office_photo_employee_profile(ids[2],(select id from store_employees where store_id=ids[1])) is not null then raise exception 'PROFILE_SCOPE_LEAK';end if;
 begin perform office_photo_operations_report(ids[1:1],'2026-10-01','2026-10-20',ids[2:2],'{}','{}','{}');raise exception 'EXPECTED_SCOPE_REJECTION';exception when sqlstate '22023' then null;end;
 begin perform office_photo_operations_report(ids,'2026-01-01','2026-10-20',ids,ids,ids,ids);raise exception 'EXPECTED_DATE_REJECTION';exception when sqlstate '22023' then null;end;
 if has_function_privilege('authenticated','office_photo_operations_report(uuid[],date,date,uuid[],uuid[],uuid[],uuid[])','execute') then raise exception 'ACL_LEAK';end if;
 raise notice 'PASS: aggregate separation, mixed grants, exact payroll period, masks, cross-store denial, bounds and ACL';
end $$;
-- Simulate an overnight open shift and later clock-out: only the latest event counts.
insert into attendance_logs select gen_random_uuid(),store_id,id,'clock_out','2026-10-20 17:00+07' from store_employees;
do $$declare ids uuid[];r jsonb;begin select array_agg(id order by id) into ids from restaurants;
 r:=office_photo_operations_report(ids,'2026-10-01','2026-10-20',ids,ids,ids,ids);
 if (r#>>'{rows,0,attendance,working}')::int<>0 then raise exception 'LAST_EVENT_FAILED';end if;end $$;
commit;
analyze restaurants;analyze inventory_items;analyze attendance_logs;analyze photo_objet_sales;analyze payroll_records;
\timing on
select jsonb_array_length(r->'rows') as stores,octet_length(r::text) as response_bytes from (select office_photo_operations_report(array(select id from restaurants order by id limit 6),'2026-10-01','2026-10-20',array(select id from restaurants order by id limit 6),array(select id from restaurants order by id limit 6),array(select id from restaurants order by id limit 6),array(select id from restaurants order by id limit 6)) as r)q;
select jsonb_array_length(r->'rows') as stores,octet_length(r::text) as response_bytes from (select office_photo_operations_report(array(select id from restaurants),'2026-10-01','2026-10-20',array(select id from restaurants),array(select id from restaurants),array(select id from restaurants),array(select id from restaurants)) as r)q;
