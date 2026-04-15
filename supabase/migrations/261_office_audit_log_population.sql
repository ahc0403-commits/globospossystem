-- Office audit-log population hardening
-- Adds DB-owned automatic write paths for the current canonical Office actions.

create or replace function system.write_audit_log(
  p_action text,
  p_entity_type text,
  p_entity_id uuid default null,
  p_detail jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  insert into system.audit_log (actor_id, action, entity_type, entity_id, detail)
  values (
    auth.uid(),
    p_action,
    p_entity_type,
    p_entity_id,
    coalesce(p_detail, '{}'::jsonb)
  );
end;
$$;
create or replace function system.audit_office_user_profile_changes()
returns trigger
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if tg_op = 'INSERT' then
    perform system.write_audit_log(
      'account_created',
      'account',
      new.auth_id,
      jsonb_build_object(
        'profile_id', new.id,
        'account_level', new.account_level,
        'scope_type', new.scope_type,
        'scope_ids', coalesce(to_jsonb(new.scope_ids), '[]'::jsonb),
        'is_active', new.is_active
      )
    );
    return new;
  end if;

  if new.is_active is distinct from old.is_active then
    perform system.write_audit_log(
      case when new.is_active then 'account_activated' else 'account_deactivated' end,
      'account',
      new.auth_id,
      jsonb_build_object(
        'profile_id', new.id,
        'old_is_active', old.is_active,
        'new_is_active', new.is_active
      )
    );
  end if;

  if new.account_level is distinct from old.account_level
     or new.scope_type is distinct from old.scope_type
     or new.scope_ids is distinct from old.scope_ids then
    perform system.write_audit_log(
      'permissions_updated',
      'account',
      new.auth_id,
      jsonb_build_object(
        'profile_id', new.id,
        'old_account_level', old.account_level,
        'new_account_level', new.account_level,
        'old_scope_type', old.scope_type,
        'new_scope_type', new.scope_type,
        'old_scope_ids', coalesce(to_jsonb(old.scope_ids), '[]'::jsonb),
        'new_scope_ids', coalesce(to_jsonb(new.scope_ids), '[]'::jsonb)
      )
    );
  end if;

  return new;
end;
$$;
drop trigger if exists trg_audit_office_user_profiles on public.office_user_profiles;
create trigger trg_audit_office_user_profiles
after insert or update of is_active, account_level, scope_type, scope_ids
on public.office_user_profiles
for each row
execute function system.audit_office_user_profile_changes();
create or replace function system.audit_payroll_status_changes()
returns trigger
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if tg_op = 'UPDATE'
     and new.status is distinct from old.status
     and new.status in ('confirmed', 'rejected', 'returned') then
    perform system.write_audit_log(
      'payroll_' || new.status,
      'payroll_record',
      new.id,
      jsonb_build_object(
        'employee_id', new.employee_id,
        'store_id', new.store_id,
        'brand_id', new.brand_id,
        'period_date', new.period_date,
        'old_status', old.status,
        'new_status', new.status
      )
    );
  end if;

  return new;
end;
$$;
drop trigger if exists trg_audit_payroll_status on hr.payroll_records;
create trigger trg_audit_payroll_status
after update of status
on hr.payroll_records
for each row
execute function system.audit_payroll_status_changes();
create or replace function system.audit_purchase_request_status_changes()
returns trigger
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if tg_op = 'UPDATE'
     and new.status is distinct from old.status
     and new.status in ('approved', 'rejected', 'returned') then
    perform system.write_audit_log(
      'purchase_' || new.status,
      'purchase_request',
      new.id,
      jsonb_build_object(
        'store_id', new.store_id,
        'brand_id', new.brand_id,
        'old_status', old.status,
        'new_status', new.status,
        'amount', new.amount
      )
    );
  end if;

  return new;
end;
$$;
drop trigger if exists trg_audit_purchase_request_status on accounting.purchase_requests;
create trigger trg_audit_purchase_request_status
after update of status
on accounting.purchase_requests
for each row
execute function system.audit_purchase_request_status_changes();
create or replace function system.audit_expense_status_changes()
returns trigger
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if tg_op = 'UPDATE'
     and new.status is distinct from old.status
     and new.status in ('approved', 'returned') then
    perform system.write_audit_log(
      'expense_' || new.status,
      'expense',
      new.id,
      jsonb_build_object(
        'store_id', new.store_id,
        'old_status', old.status,
        'new_status', new.status,
        'amount', new.amount,
        'return_note', new.return_note
      )
    );
  end if;

  return new;
end;
$$;
drop trigger if exists trg_audit_expense_status on accounting.expenses;
create trigger trg_audit_expense_status
after update of status
on accounting.expenses
for each row
execute function system.audit_expense_status_changes();
create or replace function system.audit_document_release()
returns trigger
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if tg_op = 'UPDATE'
     and new.status = 'active'
     and new.status is distinct from old.status then
    perform system.write_audit_log(
      'document_released',
      'document',
      new.id,
      jsonb_build_object(
        'brand_id', new.brand_id,
        'scope', new.scope,
        'visibility', new.visibility,
        'old_status', old.status,
        'new_status', new.status,
        'title', new.title
      )
    );
  end if;

  return new;
end;
$$;
drop trigger if exists trg_audit_document_release on documents.documents;
create trigger trg_audit_document_release
after update of status
on documents.documents
for each row
execute function system.audit_document_release();
