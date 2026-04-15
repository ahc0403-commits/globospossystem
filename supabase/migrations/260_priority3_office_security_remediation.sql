-- Priority 3 Office security remediation (2026-04-08 audit)
-- Covers: audit_log_select scope, Photo Objet store policy split,
-- missing SECURITY DEFINER search_path declarations.

drop policy if exists audit_log_select on system.audit_log;
create policy audit_log_select
on system.audit_log
for select
using (core.current_role() = 'superAdmin');
drop policy if exists "po_inventory_store" on public.photo_objet_inventory;
create policy "po_inventory_store_select" on public.photo_objet_inventory
  for select to authenticated
  using (store_id = public.get_photo_objet_store_id());
create policy "po_inventory_store_insert" on public.photo_objet_inventory
  for insert to authenticated
  with check (store_id = public.get_photo_objet_store_id());
create policy "po_inventory_store_update" on public.photo_objet_inventory
  for update to authenticated
  using (store_id = public.get_photo_objet_store_id())
  with check (store_id = public.get_photo_objet_store_id());
drop policy if exists "po_attendance_store" on public.photo_objet_attendance;
create policy "po_attendance_store_select" on public.photo_objet_attendance
  for select to authenticated
  using (store_id = public.get_photo_objet_store_id());
create policy "po_attendance_store_insert" on public.photo_objet_attendance
  for insert to authenticated
  with check (store_id = public.get_photo_objet_store_id());
create policy "po_attendance_store_update" on public.photo_objet_attendance
  for update to authenticated
  using (store_id = public.get_photo_objet_store_id())
  with check (store_id = public.get_photo_objet_store_id());
drop policy if exists "po_staff_store_write" on public.photo_objet_staff;
create policy "po_staff_store_insert" on public.photo_objet_staff
  for insert to authenticated
  with check (store_id = public.get_photo_objet_store_id());
create policy "po_staff_store_update" on public.photo_objet_staff
  for update to authenticated
  using (store_id = public.get_photo_objet_store_id())
  with check (store_id = public.get_photo_objet_store_id());
create or replace function system.notify_payroll_confirmed()
returns trigger
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if new.status = 'confirmed' and (old.status is null or old.status != 'confirmed') then
    insert into system.notifications (recipient_id, type, title, entity_type, entity_id)
    select oup.auth_id,
           'payroll_confirmed',
           'Payroll record confirmed',
           'payroll',
           new.id
    from public.office_user_profiles oup
    where oup.account_level in ('super_admin', 'brand_admin')
      and oup.is_active = true;
  end if;
  return new;
end;
$$;
create or replace function system.notify_document_released()
returns trigger
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if new.status = 'active' and (old.status is null or old.status != 'active') then
    insert into system.notifications (recipient_id, type, title, entity_type, entity_id)
    select oup.auth_id,
           'document_released',
           'Document released: ' || new.title,
           'document',
           new.id
    from public.office_user_profiles oup
    where oup.is_active = true;
  end if;
  return new;
end;
$$;
create or replace function public.is_master_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.office_user_profiles
    where auth_id = auth.uid()
      and account_level = 'master_admin'
  );
$$;
create or replace function public.get_master_admin_restaurant_ids()
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select array(
    select restaurant_id from public.master_admin_restaurants
    where user_auth_id = auth.uid()
  );
$$;
create or replace function public.is_photo_objet_master()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.office_user_profiles
    where auth_id = auth.uid()
      and account_level in ('super_admin', 'platform_admin', 'office_admin', 'photo_objet_master')
  );
$$;
create or replace function public.get_photo_objet_store_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select (scope_ids[1])::uuid
  from public.office_user_profiles
  where auth_id = auth.uid()
    and account_level = 'photo_objet_store_admin'
    and scope_type = 'store'
  limit 1;
$$;
