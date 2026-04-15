-- Core closure follow-up:
-- 1. Add missing expense reject execution path and audit coverage.
-- 2. Add missing document archive/supersede execution paths and audit coverage.
-- 3. Add missing quality issue resolution path and audit coverage.

create or replace function accounting.reject_expense(expense_id uuid)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() not in ('superAdmin', 'brandManager') then
    raise exception 'Insufficient permissions: brandManager+ required';
  end if;

  if core.current_role() = 'brandManager' then
    if not exists (
      select 1
      from accounting.expenses e
      join ops.stores s on s.id = e.store_id
      where e.id = expense_id and s.brand_id = core.current_brand_id()
    ) then
      raise exception 'Record is outside your brand scope';
    end if;
  end if;

  if not exists (
    select 1
    from accounting.expenses e
    where e.id = expense_id
      and e.status = 'pending'
  ) then
    raise exception 'Only pending expenses can be rejected';
  end if;

  update accounting.expenses
  set status = 'rejected'
  where id = expense_id;

  if not found then
    raise exception 'Expense % not found', expense_id;
  end if;
end;
$$;
create or replace function documents.archive_document(document_id uuid)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() not in ('superAdmin', 'brandManager') then
    raise exception 'Insufficient permissions: brandManager+ required';
  end if;

  if core.current_role() = 'brandManager' then
    if not exists (
      select 1
      from documents.documents d
      where d.id = document_id and d.brand_id = core.current_brand_id()
    ) then
      raise exception 'Record is outside your brand scope';
    end if;
  end if;

  if not exists (
    select 1
    from documents.documents d
    where d.id = document_id
      and d.status = 'active'
  ) then
    raise exception 'Only active documents can be archived';
  end if;

  update documents.documents
  set status = 'archived'
  where id = document_id;

  if not found then
    raise exception 'Document % not found', document_id;
  end if;
end;
$$;
create or replace function documents.supersede_document(document_id uuid)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() not in ('superAdmin', 'brandManager') then
    raise exception 'Insufficient permissions: brandManager+ required';
  end if;

  if core.current_role() = 'brandManager' then
    if not exists (
      select 1
      from documents.documents d
      where d.id = document_id and d.brand_id = core.current_brand_id()
    ) then
      raise exception 'Record is outside your brand scope';
    end if;
  end if;

  if not exists (
    select 1
    from documents.documents d
    where d.id = document_id
      and d.status = 'active'
  ) then
    raise exception 'Only active documents can be superseded';
  end if;

  update documents.documents
  set status = 'superseded'
  where id = document_id;

  if not found then
    raise exception 'Document % not found', document_id;
  end if;
end;
$$;
create or replace function ops.resolve_quality_check(check_id uuid)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() not in ('superAdmin', 'brandManager', 'storeManager') then
    raise exception 'Insufficient permissions: storeManager+ required';
  end if;

  if core.current_role() = 'storeManager' then
    if not exists (
      select 1
      from ops.quality_checks qc
      where qc.id = check_id and qc.store_id = core.current_store_id()
    ) then
      raise exception 'Record is outside your store scope';
    end if;
  elsif core.current_role() = 'brandManager' then
    if not exists (
      select 1
      from ops.quality_checks qc
      join ops.stores s on s.id = qc.store_id
      where qc.id = check_id and s.brand_id = core.current_brand_id()
    ) then
      raise exception 'Record is outside your brand scope';
    end if;
  end if;

  if not exists (
    select 1
    from ops.quality_checks qc
    where qc.id = check_id
      and qc.status = 'issue'
  ) then
    raise exception 'Only issue quality checks can be resolved';
  end if;

  update ops.quality_checks
  set status = 'resolved'
  where id = check_id;

  if not found then
    raise exception 'Quality check % not found', check_id;
  end if;
end;
$$;
create or replace function system.audit_expense_status_changes()
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
create or replace function system.audit_document_status_changes()
returns trigger
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
declare
  v_action text;
begin
  if tg_op = 'UPDATE'
     and new.status is distinct from old.status
     and new.status in ('active', 'archived', 'superseded') then
    v_action := case new.status
      when 'active' then 'document_released'
      when 'archived' then 'document_archived'
      when 'superseded' then 'document_superseded'
      else null
    end;

    perform system.write_audit_log(
      v_action,
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
drop trigger if exists trg_audit_document_status on documents.documents;
create trigger trg_audit_document_status
after update of status
on documents.documents
for each row
execute function system.audit_document_status_changes();
create or replace function system.audit_quality_status_changes()
returns trigger
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if tg_op = 'UPDATE'
     and new.status is distinct from old.status
     and new.status = 'resolved' then
    perform system.write_audit_log(
      'quality_resolved',
      'quality_check',
      new.id,
      jsonb_build_object(
        'store_id', new.store_id,
        'old_status', old.status,
        'new_status', new.status,
        'issue_note', new.issue_note
      )
    );
  end if;

  return new;
end;
$$;
drop trigger if exists trg_audit_quality_status on ops.quality_checks;
create trigger trg_audit_quality_status
after update of status
on ops.quality_checks
for each row
execute function system.audit_quality_status_changes();
