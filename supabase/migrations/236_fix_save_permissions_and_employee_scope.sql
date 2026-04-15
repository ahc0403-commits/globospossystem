-- Fix RPC ambiguity and tighten employee select scope for store managers.

create or replace function system.save_permissions(
  account_id uuid,
  role text,
  scope_brand_id uuid,
  scope_store_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
declare
  v_account_id alias for $1;
  v_role alias for $2;
  v_scope_brand_id alias for $3;
  v_scope_store_id alias for $4;
begin
  if core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  update core.accounts
  set
    role = v_role,
    scope_brand_id = v_scope_brand_id,
    scope_store_id = v_scope_store_id
  where id = v_account_id;
end; $$;
drop policy if exists employees_select_scoped on hr.employees;
create policy employees_select_scoped on hr.employees
  for select
  using (
    core.current_role() = 'superAdmin'
    or (core.current_role() = 'brandManager' and brand_id = core.current_brand_id())
    or (core.current_role() = 'storeManager' and store_id = core.current_store_id())
  );
