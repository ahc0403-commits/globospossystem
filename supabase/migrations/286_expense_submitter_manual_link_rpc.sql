-- Manual correction path for historical expense submitter identity linkage.
--
-- Scope:
-- - Only link expenses that still lack submitted_by_auth_id.
-- - Operator explicitly chooses an existing office_user_profiles.auth_id.
-- - Preserve legacy submitted_by text unless the existing sync trigger needs to
--   fill a blank value.

-- expenses_view already has the correct shape from migration 282
-- (new columns appended at end to preserve dependent view compatibility).
-- No view replacement needed here.

create or replace function accounting.link_expense_submitter_identity(
  expense_id uuid,
  submitter_auth_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
declare
  v_expense accounting.expenses%rowtype;
  v_profile public.office_user_profiles%rowtype;
begin
  if session_user <> 'postgres' and core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  if expense_id is null then
    raise exception 'expense_id is required';
  end if;

  if submitter_auth_id is null then
    raise exception 'submitter_auth_id is required';
  end if;

  select *
  into v_expense
  from accounting.expenses e
  where e.id = expense_id
  for update;

  if not found then
    raise exception 'Expense % not found', expense_id;
  end if;

  if v_expense.submitted_by_auth_id is not null then
    raise exception 'Expense % already has a canonical submitter identity', expense_id;
  end if;

  select *
  into v_profile
  from public.office_user_profiles oup
  where oup.auth_id = submitter_auth_id
  limit 1;

  if not found then
    raise exception 'Office profile not found for submitter_auth_id %', submitter_auth_id;
  end if;

  update accounting.expenses
  set submitted_by_auth_id = submitter_auth_id
  where id = v_expense.id;

  perform system.write_audit_log(
    'expense_submitter_identity_linked',
    'expense',
    v_expense.id,
    jsonb_build_object(
      'old_submitted_by_auth_id', v_expense.submitted_by_auth_id,
      'new_submitted_by_auth_id', v_profile.auth_id,
      'legacy_submitted_by', v_expense.submitted_by,
      'linked_profile_id', v_profile.id,
      'linked_display_name', v_profile.display_name,
      'linked_email', v_profile.email,
      'linked_is_active', v_profile.is_active
    )
  );
end;
$$;
grant execute on function accounting.link_expense_submitter_identity(uuid, uuid)
  to authenticated;
