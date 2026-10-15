begin;
do $$ declare p regprocedure := 'public.office_photo_payroll_inputs(uuid,uuid,date,date)'::regprocedure; begin
  if has_function_privilege('anon',p,'execute') or has_function_privilege('authenticated',p,'execute')
    or not has_function_privilege('service_role',p,'execute') then
    raise exception 'Payroll input RPC privileges differ from the service-only contract';
  end if;
  if exists(select 1 from pg_proc where oid=p and (prosecdef or provolatile<>'s')) then
    raise exception 'Payroll input RPC must be stable and security invoker';
  end if;
end $$;
set local role service_role;
do $$ declare employee record; result jsonb; begin
  select id,store_id into employee from public.store_employees where is_active order by id limit 1;
  if employee.id is null then raise exception 'No existing employee is available to verify the read contract'; end if;
  result:=public.office_photo_payroll_inputs(employee.store_id,employee.id,current_date-14,current_date);
  if result->>'version'<>'1' or result->>'store_id'<>employee.store_id::text
    or result->>'employee_id'<>employee.id::text or jsonb_array_length(result->'staff')<>1
    or jsonb_array_length(result->'logs')>5000 then
    raise exception 'Payroll input RPC smoke returned an invalid scoped snapshot';
  end if;
end $$;
rollback;
