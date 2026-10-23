begin;
do $$ declare p regprocedure;name text;ids uuid[];result jsonb;begin
 foreach name in array array[
  'public.office_photo_stock_page(uuid[],uuid)',
  'public.office_photo_stock_count(uuid,uuid,numeric,bigint,uuid,uuid,text,numeric,numeric)',
  'public.office_photo_on_shift(uuid[],uuid)',
  'public.office_photo_pay_policy(uuid,date,integer,uuid,text)',
  'public.office_photo_payroll_batch(uuid[],date,date,uuid,uuid,jsonb)',
  'public.office_photo_payroll_inputs(uuid,uuid,date,date)'] loop
  p:=to_regprocedure(name);
  if p is null or has_function_privilege('anon',p,'execute') or has_function_privilege('authenticated',p,'execute') or not has_function_privilege('service_role',p,'execute') then raise exception 'Photo RPC privilege mismatch: %',name;end if;
  if not (select prosecdef and pg_get_userbyid(proowner)='postgres' from pg_proc where oid=p) then raise exception 'Photo RPC owner/security mismatch: %',name;end if;
 end loop;
 if has_table_privilege('anon','public.v_financial_payroll_staff','select') or has_table_privilege('authenticated','public.v_financial_payroll_staff','select') then raise exception 'Financial staff projection must stay private';end if;
 if (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname in('get_financial_input_page','get_employee_financial_input_page') and position('FROM public.v_financial_payroll_staff WHERE store_id = ANY($1)' in pg_get_functiondef(oid))>0)<>2 then raise exception 'Financial input projection was not updated';end if;
 select array_agg(id) into ids from(select id from public.restaurants where is_active and brand_id='77000000-0000-0000-0000-000000000001' order by id limit 50)x;
 if ids is null then raise exception 'No existing Photo store available for read verification';end if;
 result:=public.office_photo_stock_page(ids);
 if jsonb_array_length(result->'rows')>100 then raise exception 'Stock page exceeds bound';end if;
 result:=public.office_photo_payroll_batch(ids,current_date-14,current_date);
 if jsonb_array_length(result->'inputs')>25 or (result->>'log_count')::integer>5000 then raise exception 'Payroll page exceeds bound';end if;
end $$;
rollback;
