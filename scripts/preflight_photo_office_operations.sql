do $$ declare p record; definition text; begin
 if to_regclass('public.office_photo_pay_policies') is not null or to_regclass('public.office_photo_inventory_requests') is not null then
  raise exception 'Photo operations objects already exist; resolve history before applying';
 end if;
 if to_regprocedure('public.office_photo_payroll_inputs(uuid,uuid,date,date)') is null then
  raise exception 'Existing Photo payroll input contract is required';
 end if;
 if (select count(*) from information_schema.columns where table_schema='public' and table_name='inventory_items' and column_name in('current_stock','restaurant_id','unit','reorder_point'))<>4 then
  raise exception 'POS inventory source schema differs';
 end if;
 if (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname in('get_financial_input_page','get_employee_financial_input_page'))<>2 then
  raise exception 'Financial input RPC set differs';
 end if;
 for p in select oid from pg_proc where pronamespace='public'::regnamespace and proname in('get_financial_input_page','get_employee_financial_input_page') loop
  definition:=pg_get_functiondef(p.oid);
  if position('SELECT id, store_id, employee_number, full_name, employment_role' in definition)=0 or position('FROM public.store_employees WHERE store_id = ANY($1)' in definition)=0 then
   raise exception 'Financial staff projection differs; inspect before applying';
  end if;
 end loop;
end $$;
