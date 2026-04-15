-- Bounded diagnostics for email non-generation in DB-owned enqueue paths.
--
-- Goal:
-- Persist deterministic skip reasons only when a qualifying handled email
-- branch decides not to create any outbox row.

create table if not exists system.email_enqueue_diagnostics (
  id uuid primary key default gen_random_uuid(),
  source_audit_log_id uuid not null unique
    references system.audit_log(id) on delete cascade,
  event_action text not null,
  entity_type text not null,
  entity_id uuid,
  diagnostic_reason_code text not null check (diagnostic_reason_code in (
    'setting_disabled',
    'source_record_missing',
    'recipient_identity_missing',
    'recipient_profile_missing',
    'recipient_inactive',
    'recipient_email_missing',
    'no_eligible_recipients'
  )),
  diagnostic_message text not null,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists idx_email_enqueue_diagnostics_created
  on system.email_enqueue_diagnostics(created_at desc);
create index if not exists idx_email_enqueue_diagnostics_entity
  on system.email_enqueue_diagnostics(entity_type, entity_id, created_at desc);
alter table system.email_enqueue_diagnostics enable row level security;
drop policy if exists email_enqueue_diagnostics_select_admin
  on system.email_enqueue_diagnostics;
create policy email_enqueue_diagnostics_select_admin
on system.email_enqueue_diagnostics
for select
to authenticated
using (core.current_role() = 'superAdmin');
grant usage on schema system to authenticated, service_role;
grant select on system.email_enqueue_diagnostics to authenticated, service_role;
grant insert, update on system.email_enqueue_diagnostics to service_role;
create or replace function system.record_email_enqueue_diagnostic(
  p_source_audit_log_id uuid,
  p_event_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_reason_code text,
  p_message text,
  p_detail jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
begin
  insert into system.email_enqueue_diagnostics (
    source_audit_log_id,
    event_action,
    entity_type,
    entity_id,
    diagnostic_reason_code,
    diagnostic_message,
    detail
  )
  values (
    p_source_audit_log_id,
    p_event_action,
    p_entity_type,
    p_entity_id,
    p_reason_code,
    left(coalesce(p_message, 'Email enqueue skipped'), 4000),
    coalesce(p_detail, '{}'::jsonb)
  )
  on conflict (source_audit_log_id) do update
  set
    event_action = excluded.event_action,
    entity_type = excluded.entity_type,
    entity_id = excluded.entity_id,
    diagnostic_reason_code = excluded.diagnostic_reason_code,
    diagnostic_message = excluded.diagnostic_message,
    detail = excluded.detail,
    created_at = now();
end;
$$;
create or replace function system.enqueue_email_from_audit_log()
returns trigger
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
declare
  v_profile public.office_user_profiles%rowtype;
  v_settings system.system_settings%rowtype;
  v_pr record;
  v_pay record;
  v_exp record;
  v_document record;
  v_inserted_count integer := 0;
  v_has_email boolean;
begin
  if new.action = 'account_created'
     and new.entity_type = 'account'
     and new.entity_id is not null then
    select *
    into v_profile
    from public.office_user_profiles oup
    where oup.auth_id = new.entity_id
    limit 1;

    if not found then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'recipient_profile_missing',
        'Email enqueue skipped because the office profile was not found for the account.',
        jsonb_build_object('recipient_auth_id', new.entity_id)
      );
      return new;
    end if;

    if not coalesce(v_profile.is_active, false) then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'recipient_inactive',
        'Email enqueue skipped because the account profile is inactive.',
        jsonb_build_object(
          'recipient_auth_id', v_profile.auth_id,
          'recipient_email', v_profile.email
        )
      );
      return new;
    end if;

    if nullif(trim(coalesce(v_profile.email, '')), '') is null then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'recipient_email_missing',
        'Email enqueue skipped because the account profile has no email address.',
        jsonb_build_object('recipient_auth_id', v_profile.auth_id)
      );
      return new;
    end if;

    perform system.enqueue_email_outbox(
      new.id,
      'account_created',
      'account_created',
      v_profile.auth_id,
      v_profile.email,
      v_profile.display_name,
      'Your Office account is ready',
      jsonb_build_object(
        'display_name', v_profile.display_name,
        'email', v_profile.email,
        'account_level', v_profile.account_level,
        'scope_type', v_profile.scope_type,
        'scope_ids', coalesce(to_jsonb(v_profile.scope_ids), '[]'::jsonb)
      )
    );

  elsif new.action = 'document_released'
        and new.entity_type = 'document'
        and new.entity_id is not null then
    select
      d.id,
      d.title,
      d.category,
      d.scope,
      d.visibility,
      d.brand_id
    into v_document
    from documents.documents d
    where d.id = new.entity_id
    limit 1;

    if not found then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'source_record_missing',
        'Email enqueue skipped because the document record was not found.',
        '{}'::jsonb
      );
      return new;
    end if;

    insert into system.email_outbox (
      source_audit_log_id,
      event_action,
      template_key,
      recipient_auth_id,
      recipient_email,
      recipient_name,
      subject,
      payload
    )
    select
      new.id,
      'document_released',
      'document_released',
      oup.auth_id,
      lower(trim(oup.email)),
      nullif(trim(coalesce(oup.display_name, '')), ''),
      'Document released: ' || v_document.title,
      jsonb_build_object(
        'document_id', v_document.id,
        'title', v_document.title,
        'category', v_document.category,
        'scope', v_document.scope,
        'visibility', v_document.visibility,
        'brand_id', v_document.brand_id
      )
    from public.office_user_profiles oup
    where oup.is_active = true
      and nullif(trim(coalesce(oup.email, '')), '') is not null
      and (
        v_document.visibility = 'all'
        or oup.account_level in ('super_admin', 'platform_admin')
        or (
          v_document.visibility = 'admin'
          and oup.account_level in ('office_admin', 'brand_admin')
        )
        or (
          v_document.visibility = 'brand'
          and (
            (oup.scope_type = 'brand' and oup.scope_ids[1] = v_document.brand_id)
            or (
              oup.scope_type = 'store'
              and exists (
                select 1
                from ops.stores s
                where s.id = oup.scope_ids[1]
                  and s.brand_id = v_document.brand_id
              )
            )
          )
        )
        or (
          v_document.visibility = 'store'
          and oup.scope_type = 'store'
        )
      )
    on conflict do nothing;

    get diagnostics v_inserted_count = row_count;

    if v_inserted_count = 0 then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'no_eligible_recipients',
        'Email enqueue skipped because no eligible active recipients with email matched the document visibility rules.',
        jsonb_build_object(
          'visibility', v_document.visibility,
          'brand_id', v_document.brand_id
        )
      );
    end if;

  elsif new.action in ('purchase_approved', 'purchase_rejected')
        and new.entity_type = 'purchase_request'
        and new.entity_id is not null then
    select *
    into v_settings
    from system.system_settings
    where settings_key = 'global';

    if not coalesce(v_settings.purchase_approval_email_enabled, true) then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'setting_disabled',
        'Email enqueue skipped because purchase approval emails are disabled in system settings.',
        jsonb_build_object('settings_key', 'purchase_approval_email_enabled')
      );
      return new;
    end if;

    select
      pr.id as pr_id,
      pr.title as pr_title,
      pr.amount as pr_amount,
      pr.status as pr_status,
      pr.store_id as pr_store_id,
      pr.brand_id as pr_brand_id,
      pr.requested_by as requested_by,
      s.name as store_name,
      b.name as brand_name
    into v_pr
    from accounting.purchase_requests pr
    join ops.stores s on s.id = pr.store_id
    join ops.brands b on b.id = pr.brand_id
    where pr.id = new.entity_id
    limit 1;

    if not found then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'source_record_missing',
        'Email enqueue skipped because the purchase request record was not found.',
        '{}'::jsonb
      );
      return new;
    end if;

    if v_pr.requested_by is null then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'recipient_identity_missing',
        'Email enqueue skipped because the purchase request has no canonical requester identity.',
        jsonb_build_object('purchase_request_id', v_pr.pr_id)
      );
      return new;
    end if;

    select *
    into v_profile
    from public.office_user_profiles oup
    where oup.auth_id = v_pr.requested_by
    limit 1;

    if not found then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'recipient_profile_missing',
        'Email enqueue skipped because the requester office profile was not found.',
        jsonb_build_object(
          'purchase_request_id', v_pr.pr_id,
          'recipient_auth_id', v_pr.requested_by
        )
      );
      return new;
    end if;

    if not coalesce(v_profile.is_active, false) then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'recipient_inactive',
        'Email enqueue skipped because the requester profile is inactive.',
        jsonb_build_object(
          'purchase_request_id', v_pr.pr_id,
          'recipient_auth_id', v_profile.auth_id
        )
      );
      return new;
    end if;

    if nullif(trim(coalesce(v_profile.email, '')), '') is null then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'recipient_email_missing',
        'Email enqueue skipped because the requester profile has no email address.',
        jsonb_build_object(
          'purchase_request_id', v_pr.pr_id,
          'recipient_auth_id', v_profile.auth_id
        )
      );
      return new;
    end if;

    perform system.enqueue_email_outbox(
      new.id,
      new.action,
      new.action,
      v_profile.auth_id,
      v_profile.email,
      v_profile.display_name,
      case new.action
        when 'purchase_approved' then 'Purchase request approved: ' || v_pr.pr_title
        when 'purchase_rejected' then 'Purchase request rejected: ' || v_pr.pr_title
      end,
      jsonb_build_object(
        'purchase_request_id', v_pr.pr_id,
        'title', v_pr.pr_title,
        'amount', v_pr.pr_amount,
        'status', v_pr.pr_status,
        'store_id', v_pr.pr_store_id,
        'store_name', v_pr.store_name,
        'brand_id', v_pr.pr_brand_id,
        'brand_name', v_pr.brand_name
      )
    );

  elsif new.action in ('payroll_confirmed', 'payroll_rejected')
        and new.entity_type = 'payroll_record'
        and new.entity_id is not null then
    select *
    into v_settings
    from system.system_settings
    where settings_key = 'global';

    if not coalesce(v_settings.payroll_status_email_enabled, true) then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'setting_disabled',
        'Email enqueue skipped because payroll status emails are disabled in system settings.',
        jsonb_build_object('settings_key', 'payroll_status_email_enabled')
      );
      return new;
    end if;

    select
      pr.id as pay_id,
      pr.employee_name as employee_name,
      pr.period_date as period_date,
      pr.status as pay_status,
      pr.store_id as pay_store_id,
      pr.brand_id as pay_brand_id,
      s.name as store_name,
      b.name as brand_name
    into v_pay
    from hr.payroll_records pr
    join ops.stores s on s.id = pr.store_id
    join ops.brands b on b.id = pr.brand_id
    where pr.id = new.entity_id
    limit 1;

    if not found then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'source_record_missing',
        'Email enqueue skipped because the payroll record was not found.',
        '{}'::jsonb
      );
      return new;
    end if;

    insert into system.email_outbox (
      source_audit_log_id,
      event_action,
      template_key,
      recipient_auth_id,
      recipient_email,
      recipient_name,
      subject,
      payload
    )
    select
      new.id,
      new.action,
      new.action,
      oup.auth_id,
      lower(trim(oup.email)),
      nullif(trim(coalesce(oup.display_name, '')), ''),
      case new.action
        when 'payroll_confirmed' then 'Payroll confirmed: ' || v_pay.store_name || ' - ' || v_pay.period_date::text
        when 'payroll_rejected' then 'Payroll rejected: ' || v_pay.store_name || ' - ' || v_pay.period_date::text
      end,
      jsonb_build_object(
        'payroll_record_id', v_pay.pay_id,
        'employee_name', v_pay.employee_name,
        'period_date', v_pay.period_date,
        'status', v_pay.pay_status,
        'store_id', v_pay.pay_store_id,
        'store_name', v_pay.store_name,
        'brand_id', v_pay.pay_brand_id,
        'brand_name', v_pay.brand_name
      )
    from public.office_user_profiles oup
    where oup.account_level in ('super_admin', 'brand_admin')
      and oup.is_active = true
      and nullif(trim(coalesce(oup.email, '')), '') is not null
    on conflict do nothing;

    get diagnostics v_inserted_count = row_count;

    if v_inserted_count = 0 then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'no_eligible_recipients',
        'Email enqueue skipped because no eligible active admin recipients with email were available for the payroll event.',
        jsonb_build_object(
          'payroll_record_id', v_pay.pay_id,
          'store_id', v_pay.pay_store_id,
          'brand_id', v_pay.pay_brand_id
        )
      );
    end if;

  elsif new.action in ('expense_approved', 'expense_returned')
        and new.entity_type = 'expense'
        and new.entity_id is not null then
    select *
    into v_settings
    from system.system_settings
    where settings_key = 'global';

    if not coalesce(v_settings.expense_approval_email_enabled, true) then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'setting_disabled',
        'Email enqueue skipped because expense approval emails are disabled in system settings.',
        jsonb_build_object('settings_key', 'expense_approval_email_enabled')
      );
      return new;
    end if;

    select
      e.id as exp_id,
      e.description as exp_description,
      e.amount as exp_amount,
      e.status as exp_status,
      e.return_note as exp_return_note,
      e.store_id as exp_store_id,
      e.submitted_by_auth_id as submitted_by_auth_id,
      s.name as store_name,
      s.brand_id as exp_brand_id,
      b.name as brand_name
    into v_exp
    from accounting.expenses e
    join ops.stores s on s.id = e.store_id
    join ops.brands b on b.id = s.brand_id
    where e.id = new.entity_id
    limit 1;

    if not found then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'source_record_missing',
        'Email enqueue skipped because the expense record was not found.',
        '{}'::jsonb
      );
      return new;
    end if;

    if v_exp.submitted_by_auth_id is null then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'recipient_identity_missing',
        'Email enqueue skipped because the expense has no canonical submitter identity.',
        jsonb_build_object('expense_id', v_exp.exp_id)
      );
      return new;
    end if;

    select *
    into v_profile
    from public.office_user_profiles oup
    where oup.auth_id = v_exp.submitted_by_auth_id
    limit 1;

    if not found then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'recipient_profile_missing',
        'Email enqueue skipped because the expense submitter office profile was not found.',
        jsonb_build_object(
          'expense_id', v_exp.exp_id,
          'recipient_auth_id', v_exp.submitted_by_auth_id
        )
      );
      return new;
    end if;

    if not coalesce(v_profile.is_active, false) then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'recipient_inactive',
        'Email enqueue skipped because the expense submitter profile is inactive.',
        jsonb_build_object(
          'expense_id', v_exp.exp_id,
          'recipient_auth_id', v_profile.auth_id
        )
      );
      return new;
    end if;

    if nullif(trim(coalesce(v_profile.email, '')), '') is null then
      perform system.record_email_enqueue_diagnostic(
        new.id,
        new.action,
        new.entity_type,
        new.entity_id,
        'recipient_email_missing',
        'Email enqueue skipped because the expense submitter profile has no email address.',
        jsonb_build_object(
          'expense_id', v_exp.exp_id,
          'recipient_auth_id', v_profile.auth_id
        )
      );
      return new;
    end if;

    perform system.enqueue_email_outbox(
      new.id,
      new.action,
      new.action,
      v_profile.auth_id,
      v_profile.email,
      v_profile.display_name,
      case new.action
        when 'expense_approved' then 'Expense approved: ' || v_exp.exp_description
        when 'expense_returned' then 'Expense returned: ' || v_exp.exp_description
      end,
      jsonb_build_object(
        'expense_id', v_exp.exp_id,
        'description', v_exp.exp_description,
        'amount', v_exp.exp_amount,
        'status', v_exp.exp_status,
        'return_note', v_exp.exp_return_note,
        'store_id', v_exp.exp_store_id,
        'store_name', v_exp.store_name,
        'brand_id', v_exp.exp_brand_id,
        'brand_name', v_exp.brand_name
      )
    );
  end if;

  return new;
end;
$$;
