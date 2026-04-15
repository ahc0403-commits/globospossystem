-- 279: HR self-submit leave request RPC
-- Bundle F-2: wire My Leave self-submit to hr.leave_requests table.
-- Security definer RPC bypasses RLS; validates auth + resolves employee_id
-- by email match between office_user_profiles and hr.employees.
-- Follows exact F-1 pattern (migration 278).

create or replace function hr.submit_my_leave_request(
  p_leave_type hr.leave_type,
  p_start_date date,
  p_end_date date,
  p_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_id uuid;
  v_email text;
  v_employee_id uuid;
  v_store_id uuid;
  v_brand_id uuid;
  v_day_count int;
  v_leave_id uuid;
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
  select e.id, e.store_id, e.brand_id
  into v_employee_id, v_store_id, v_brand_id
  from hr.employees e
  where lower(e.email) = lower(v_email)
    and e.status = 'active'
  limit 1;

  if v_employee_id is null then
    raise exception 'No matching employee record found for your email';
  end if;

  -- 4. Compute day count
  v_day_count := (p_end_date - p_start_date) + 1;
  if v_day_count < 1 then
    raise exception 'End date must be on or after start date';
  end if;

  -- 5. Insert leave request
  insert into hr.leave_requests (
    employee_id, store_id, brand_id,
    leave_type, start_date, end_date, day_count,
    status, requested_by, reason
  ) values (
    v_employee_id, v_store_id, v_brand_id,
    p_leave_type, p_start_date, p_end_date, v_day_count,
    'pending', v_auth_id, p_reason
  )
  returning id into v_leave_id;

  return v_leave_id;
end;
$$;
-- Grant execute to authenticated users
grant execute on function hr.submit_my_leave_request(hr.leave_type, date, date, text)
  to authenticated;
