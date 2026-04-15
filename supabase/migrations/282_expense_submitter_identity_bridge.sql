-- Expense submitter identity bridge:
-- accounting.expenses.submitted_by is TEXT (display name) with no FK to
-- office_user_profiles. This blocks deterministic recipient resolution for
-- expense approval/return email notifications.
--
-- Bridge strategy:
-- 1. Add nullable submitted_by_auth_id UUID FK (safe, additive).
-- 2. Keep legacy TEXT column — existing reads, RPCs, and views depend on it.
-- 3. Update expenses_view to expose the new column + submitter profile join.
-- 4. Extend email enqueue trigger with expense handlers gated on auth_id presence.
-- 5. No backfill: existing TEXT names cannot be reliably matched to profiles.
--
-- Remaining gap after this migration:
-- No expense creation path in the app populates submitted_by_auth_id.
-- Email will only fire for expense rows where this column is set by future
-- write paths (expense submission RPC / form).

-- ── 1. Add identity column ──────────────────────────────────────────────────

alter table accounting.expenses
  add column if not exists submitted_by_auth_id uuid
  references public.office_user_profiles(auth_id);
create index if not exists idx_expenses_submitted_by_auth_id
  on accounting.expenses(submitted_by_auth_id)
  where submitted_by_auth_id is not null;
-- ── 2. Update expenses_view ─────────────────────────────────────────────────
-- Adds submitted_by_auth_id and submitter display_name from profile join.
-- New columns appended at end to preserve existing column positions and
-- avoid breaking dependent views (operations_report_rows_view).

create or replace view accounting.expenses_view as
select
  e.id,
  e.description,
  e.submitted_by,
  e.store_id,
  s.name            as store_name,
  s.brand_id,
  e.amount,
  e.expense_date,
  e.status,
  e.return_note,
  e.created_at,
  e.submitted_by_auth_id,
  oup.display_name  as submitted_by_name
from accounting.expenses e
left join ops.stores s on s.id = e.store_id
left join public.office_user_profiles oup on oup.auth_id = e.submitted_by_auth_id;
alter view accounting.expenses_view set (security_invoker = true);
grant select on accounting.expenses_view to authenticated;
-- ── 3. Extend email enqueue trigger with expense handlers ───────────────────
-- Full replacement of system.enqueue_email_from_audit_log() to add
-- expense_approved and expense_returned handlers.
-- All existing handlers (account_created, document_released,
-- purchase_approved/rejected, payroll_confirmed/rejected) are preserved
-- unchanged from migration 281.

create or replace function system.enqueue_email_from_audit_log()
returns trigger
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
declare
  v_profile  public.office_user_profiles%rowtype;
  v_settings system.system_settings%rowtype;
  v_pr       record;  -- purchase request row + joins
  v_pay      record;  -- payroll record row + joins
  v_exp      record;  -- expense row + joins
begin
  -- ── account_created (first-wave, unchanged) ────────────────────────────────
  if new.action = 'account_created'
     and new.entity_type = 'account'
     and new.entity_id is not null then
    select *
    into v_profile
    from public.office_user_profiles oup
    where oup.auth_id = new.entity_id
      and oup.is_active = true
      and nullif(trim(coalesce(oup.email, '')), '') is not null
    limit 1;

    if found then
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
    end if;

  -- ── document_released (first-wave, unchanged) ──────────────────────────────
  elsif new.action = 'document_released'
        and new.entity_type = 'document'
        and new.entity_id is not null then
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
      'Document released: ' || d.title,
      jsonb_build_object(
        'document_id', d.id,
        'title', d.title,
        'category', d.category,
        'scope', d.scope,
        'visibility', d.visibility,
        'brand_id', d.brand_id
      )
    from documents.documents d
    join public.office_user_profiles oup on oup.is_active = true
    where d.id = new.entity_id
      and nullif(trim(coalesce(oup.email, '')), '') is not null
      and (
        d.visibility = 'all'
        or oup.account_level in ('super_admin', 'platform_admin')
        or (
          d.visibility = 'admin'
          and oup.account_level in ('office_admin', 'brand_admin')
        )
        or (
          d.visibility = 'brand'
          and (
            (oup.scope_type = 'brand' and oup.scope_ids[1] = d.brand_id)
            or (
              oup.scope_type = 'store'
              and exists (
                select 1
                from ops.stores s
                where s.id = oup.scope_ids[1]
                  and s.brand_id = d.brand_id
              )
            )
          )
        )
        or (
          d.visibility = 'store'
          and oup.scope_type = 'store'
        )
      )
    on conflict do nothing;

  -- ── purchase_approved / purchase_rejected (second-wave, unchanged) ─────────
  elsif new.action in ('purchase_approved', 'purchase_rejected')
        and new.entity_type = 'purchase_request'
        and new.entity_id is not null then

    select *
    into v_settings
    from system.system_settings
    where settings_key = 'global';

    if not coalesce(v_settings.purchase_approval_email_enabled, true) then
      return new;
    end if;

    select
      pr.id           as pr_id,
      pr.title        as pr_title,
      pr.amount       as pr_amount,
      pr.store_id     as pr_store_id,
      pr.brand_id     as pr_brand_id,
      pr.status       as pr_status,
      s.name          as store_name,
      b.name          as brand_name,
      oup.auth_id     as recipient_auth_id,
      oup.email       as recipient_email,
      oup.display_name as recipient_name
    into v_pr
    from accounting.purchase_requests pr
    join ops.stores s on s.id = pr.store_id
    join ops.brands b on b.id = pr.brand_id
    join public.office_user_profiles oup
      on oup.auth_id = pr.requested_by
      and oup.is_active = true
      and nullif(trim(coalesce(oup.email, '')), '') is not null
    where pr.id = new.entity_id
      and pr.requested_by is not null
    limit 1;

    if found then
      perform system.enqueue_email_outbox(
        new.id,
        new.action,
        new.action,
        v_pr.recipient_auth_id,
        v_pr.recipient_email,
        v_pr.recipient_name,
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
    end if;

  -- ── payroll_confirmed / payroll_rejected (second-wave, unchanged) ──────────
  elsif new.action in ('payroll_confirmed', 'payroll_rejected')
        and new.entity_type = 'payroll_record'
        and new.entity_id is not null then

    select *
    into v_settings
    from system.system_settings
    where settings_key = 'global';

    if not coalesce(v_settings.payroll_status_email_enabled, true) then
      return new;
    end if;

    select
      pr.id           as pay_id,
      pr.employee_name as employee_name,
      pr.period_date  as period_date,
      pr.status       as pay_status,
      pr.store_id     as pay_store_id,
      pr.brand_id     as pay_brand_id,
      s.name          as store_name,
      b.name          as brand_name
    into v_pay
    from hr.payroll_records pr
    join ops.stores s on s.id = pr.store_id
    join ops.brands b on b.id = pr.brand_id
    where pr.id = new.entity_id
    limit 1;

    if found then
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
          when 'payroll_confirmed' then 'Payroll confirmed: ' || v_pay.store_name || ' — ' || v_pay.period_date::text
          when 'payroll_rejected'  then 'Payroll rejected: '  || v_pay.store_name || ' — ' || v_pay.period_date::text
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
    end if;

  -- ── expense_approved / expense_returned (new — identity-bridge gated) ──────
  -- Recipient: the user who submitted the expense (submitted_by_auth_id).
  -- Only fires if submitted_by_auth_id is populated (nullable bridge column).
  -- Legacy rows with NULL auth_id silently skip email.
  elsif new.action in ('expense_approved', 'expense_returned')
        and new.entity_type = 'expense'
        and new.entity_id is not null then

    select *
    into v_settings
    from system.system_settings
    where settings_key = 'global';

    if not coalesce(v_settings.expense_approval_email_enabled, true) then
      return new;
    end if;

    select
      e.id             as exp_id,
      e.description    as exp_description,
      e.amount         as exp_amount,
      e.status         as exp_status,
      e.return_note    as exp_return_note,
      e.store_id       as exp_store_id,
      s.name           as store_name,
      s.brand_id       as exp_brand_id,
      b.name           as brand_name,
      oup.auth_id      as recipient_auth_id,
      oup.email        as recipient_email,
      oup.display_name as recipient_name
    into v_exp
    from accounting.expenses e
    join ops.stores s on s.id = e.store_id
    join ops.brands b on b.id = s.brand_id
    join public.office_user_profiles oup
      on oup.auth_id = e.submitted_by_auth_id
      and oup.is_active = true
      and nullif(trim(coalesce(oup.email, '')), '') is not null
    where e.id = new.entity_id
      and e.submitted_by_auth_id is not null
    limit 1;

    if found then
      perform system.enqueue_email_outbox(
        new.id,
        new.action,
        new.action,
        v_exp.recipient_auth_id,
        v_exp.recipient_email,
        v_exp.recipient_name,
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

  end if;

  return new;
end;
$$;
