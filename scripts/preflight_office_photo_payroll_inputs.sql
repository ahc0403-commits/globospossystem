do $$ begin
  if to_regprocedure('public.office_photo_payroll_inputs(uuid,uuid,date,date)') is not null then
    raise exception 'Payroll input RPC already exists; investigate history before applying';
  end if;
  if to_regclass('public.store_employees') is null or to_regclass('public.attendance_logs') is null
    or to_regclass('public.employee_hourly_pay_rules') is null
    or to_regclass('public.employee_daily_allowances') is null
    or to_regclass('public.vietnam_public_holidays') is null then
    raise exception 'Required existing POS payroll input relations are missing';
  end if;
end $$;
