-- 280: HR self-read attendance RPC
-- Bundle F-5: wire My Attendance to hr.attendance_records with self-scope.
-- Security definer RPC bypasses RLS; validates auth + resolves employee_id
-- by email match between office_user_profiles and hr.employees.
-- Follows F-1/F-2 identity resolution pattern.

create or replace function hr.get_my_attendance()
returns setof hr.attendance_records
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_id uuid;
  v_email text;
  v_employee_id uuid;
begin
  -- 1. Must be authenticated
  v_auth_id := auth.uid();
  if v_auth_id is null then
    raise exception 'Not authenticated';
  end if;

  -- 2. Resolve email from office_user_profiles
  select oup.email into v_email
  from public.office_user_profiles oup
  where oup.auth_id = v_auth_id
    and oup.is_active = true;

  if v_email is null then
    raise exception 'No active office profile found';
  end if;

  -- 3. Resolve employee by email match
  select e.id into v_employee_id
  from hr.employees e
  where lower(e.email) = lower(v_email)
    and e.status = 'active'
  limit 1;

  if v_employee_id is null then
    raise exception 'No matching employee record found for your email';
  end if;

  -- 4. Return attendance records for this employee
  return query
    select *
    from hr.attendance_records ar
    where ar.employee_id = v_employee_id
    order by ar.attendance_date desc;
end;
$$;
-- Grant execute to authenticated users
grant execute on function hr.get_my_attendance()
  to authenticated;
