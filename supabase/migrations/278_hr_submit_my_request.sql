-- 278: HR self-submit request RPC
-- Bundle F-1: wire My Requests self-submit to hr.requests table.
-- Security definer RPC bypasses RLS; validates auth + resolves employee_id
-- by email match between office_user_profiles and hr.employees.

create or replace function hr.submit_my_request(
  p_request_type hr.request_type,
  p_subject text,
  p_details text default null
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
  v_request_id uuid;
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

  -- 4. Insert request
  insert into hr.requests (
    employee_id, store_id, brand_id,
    request_type, subject, details,
    status, submitted_by
  ) values (
    v_employee_id, v_store_id, v_brand_id,
    p_request_type, p_subject, p_details,
    'pending', v_auth_id
  )
  returning id into v_request_id;

  return v_request_id;
end;
$$;
-- Grant execute to authenticated users
grant execute on function hr.submit_my_request(hr.request_type, text, text)
  to authenticated;
