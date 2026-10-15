begin;
do $$ declare p regprocedure := 'public.office_photo_payroll_inputs(uuid,uuid,date,date)'::regprocedure; begin
  if has_function_privilege('anon',p,'execute') or has_function_privilege('authenticated',p,'execute')
    or not has_function_privilege('service_role',p,'execute') then
    raise exception 'Payroll input RPC privileges differ from the service-only contract';
  end if;
  if exists(select 1 from pg_proc where oid=p and (not prosecdef or provolatile<>'s'
    or pg_get_userbyid(proowner)<>'postgres')) then
    raise exception 'Payroll input RPC must be stable with the fixed database owner';
  end if;
  if has_table_privilege('anon','public.v_office_employee_daily_allowances','select')
    or has_table_privilege('authenticated','public.v_office_employee_daily_allowances','select')
    or not has_table_privilege('service_role','public.v_office_employee_daily_allowances','select') then
    raise exception 'Office allowance read view must be service-only';
  end if;
end $$;
do $$ declare employee record; result jsonb; begin
  select id,store_id into employee from public.store_employees where is_active order by id limit 1;
  if employee.id is null then raise exception 'No existing employee is available to verify the read contract'; end if;
  set local role service_role;
  result:=public.office_photo_payroll_inputs(employee.store_id,employee.id,current_date-14,current_date);
  if result->>'version'<>'1' or result->>'store_id'<>employee.store_id::text
    or result->>'employee_id'<>employee.id::text or jsonb_array_length(result->'staff')<>1
    or jsonb_array_length(result->'logs')>5000 then
    raise exception 'Payroll input RPC smoke returned an invalid scoped snapshot';
  end if;
end $$;
select exists(select 1 from public.v_office_employee_daily_allowances limit 1) as allowance_read_ready;
rollback;
