begin;

-- Inputs only. Payroll arithmetic remains in the existing POS Dart package.
-- One employee / <=92 ICT dates, one statement snapshot, no per-record queries.
create or replace function public.office_photo_payroll_inputs(
  p_store_id uuid, p_employee_id uuid, p_from date, p_to date
) returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb;
begin
  if current_user <> 'service_role' then
    raise exception 'PAYROLL_INPUT_FORBIDDEN';
  end if;
  if p_store_id is null or p_employee_id is null or p_from is null or p_to is null
    or not isfinite(p_from) or not isfinite(p_to) or p_to < p_from or p_to-p_from > 91 then
    raise exception 'PAYROLL_INPUT_QUERY_INVALID';
  end if;

  with employee as materialized (
    select id,store_id,employee_number,full_name,employment_role
    from public.store_employees where id=p_employee_id and store_id=p_store_id and is_active
  ), logs as materialized (
    select l.id,l.type,l.logged_at
    from public.attendance_logs l join employee e on e.id=l.employee_id
    where l.restaurant_id=p_store_id
      and l.logged_at >= (p_from::timestamp at time zone 'Asia/Ho_Chi_Minh')
      and l.logged_at < ((p_to+1)::timestamp at time zone 'Asia/Ho_Chi_Minh')
    order by l.logged_at,l.id limit 5001
  ), allowances as materialized (
    select a.id,a.store_id,a.employee_id,a.work_date,a.is_split_shift,
      a.meal_allowance_amount,a.parking_allowance_amount
    from public.employee_daily_allowances a join employee e on e.id=a.employee_id
    where a.store_id=p_store_id and a.work_date between p_from and p_to
  )
  select jsonb_build_object(
    'version',1,'store_id',p_store_id,'employee_id',p_employee_id,
    'from',p_from,'to',p_to,'generated_at',statement_timestamp(),
    'staff',coalesce((select jsonb_agg(jsonb_build_object(
      'user_id',e.id,'employee_number',e.employee_number,'full_name',e.full_name,
      'role',e.employment_role)) from employee e),'[]'::jsonb),
    'logs',coalesce((select jsonb_agg(jsonb_build_object(
      'id',l.id,'restaurant_id',p_store_id,'employee_id',e.id,'user_id',e.id,
      'type',l.type,'logged_at',l.logged_at,
      'users',jsonb_build_object('id',e.id,
        'full_name',coalesce(nullif(btrim(e.full_name),''),nullif(btrim(e.employee_number),''),'-'),
        'role',coalesce(nullif(btrim(e.employment_role),''),'staff'))
    ) order by l.logged_at,l.id) from logs l cross join employee e),'[]'::jsonb),
    'allowances',coalesce((select jsonb_agg(to_jsonb(a) order by a.work_date,a.id)
      from allowances a),'[]'::jsonb),
    'holidays',coalesce((select jsonb_agg(h.holiday_date order by h.holiday_date)
      from public.vietnam_public_holidays h
      where h.is_active and h.holiday_date between p_from and p_to),'[]'::jsonb),
    'hourly_rules',coalesce((select jsonb_object_agg(e.id,(
      select jsonb_build_object('hourly_rate',r.hourly_rate,'scheduled_start',r.scheduled_start,
        'night_start',r.night_start,'night_multiplier',r.night_multiplier,
        'holiday_multiplier',r.holiday_multiplier,'exclude_sunday',r.exclude_sunday,
        'late_threshold_minutes',r.late_threshold_minutes,
        'late_review_hourly_multiplier',r.late_review_hourly_multiplier)
      from public.employee_hourly_pay_rules r
      where r.store_id=p_store_id and r.employee_id=e.id and e.employment_role='part_timer'
    )) from employee e),'{}'::jsonb)
  ) into result;
  if jsonb_array_length(result->'staff') <> 1 then raise exception 'PAYROLL_EMPLOYEE_NOT_FOUND'; end if;
  if jsonb_array_length(result->'logs') > 5000 then raise exception 'PAYROLL_INPUT_LIMIT_EXCEEDED'; end if;
  return result;
end; $$;
revoke all on function public.office_photo_payroll_inputs(uuid,uuid,date,date) from public,anon,authenticated;
grant execute on function public.office_photo_payroll_inputs(uuid,uuid,date,date) to service_role;
commit;
