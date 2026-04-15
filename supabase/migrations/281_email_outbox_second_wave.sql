-- Second-wave email outbox enablement:
-- Expand email enqueue + settings gate for operational approval/status emails.
--
-- Grounded events (4):
--   purchase_approved, purchase_rejected  → recipient: purchase_requests.requested_by
--   payroll_confirmed, payroll_rejected   → recipients: super_admin + brand_admin
--     (same audience as existing notify_payroll_confirmed in migration 270)
--
-- Deferred events (2):
--   expense_approved, expense_returned    → BLOCKED: accounting.expenses.submitted_by
--     is TEXT (display name), not UUID FK. No deterministic recipient resolution.
--     Requires schema fix to accounting.expenses before email can be enabled.

-- ── 1. Widen email_outbox CHECK constraints ──────────────────────────────────
-- Include all 6 planned event types so constraint does not need re-expanding
-- when expense events are unblocked.

alter table system.email_outbox
  drop constraint if exists email_outbox_event_action_check;
alter table system.email_outbox
  add constraint email_outbox_event_action_check
  check (event_action in (
    'account_created', 'document_released',
    'purchase_approved', 'purchase_rejected',
    'expense_approved', 'expense_returned',
    'payroll_confirmed', 'payroll_rejected'
  ));
alter table system.email_outbox
  drop constraint if exists email_outbox_template_key_check;
alter table system.email_outbox
  add constraint email_outbox_template_key_check
  check (template_key in (
    'account_created', 'document_released',
    'purchase_approved', 'purchase_rejected',
    'expense_approved', 'expense_returned',
    'payroll_confirmed', 'payroll_rejected'
  ));
-- ── 2. Add email gating settings ────────────────────────────────────────────

alter table system.system_settings
  add column if not exists purchase_approval_email_enabled boolean not null default true,
  add column if not exists expense_approval_email_enabled boolean not null default true,
  add column if not exists payroll_status_email_enabled boolean not null default true;
-- ── 3. Update get_system_settings() ─────────────────────────────────────────

create or replace function system.get_system_settings()
returns jsonb
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
declare
  v_settings system.system_settings%rowtype;
begin
  if core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  select *
  into v_settings
  from system.system_settings
  where settings_key = 'global';

  if not found then
    raise exception 'System settings row is missing';
  end if;

  return jsonb_build_object(
    'supported_keys',
    jsonb_build_array(
      'payroll_confirmation_in_app_notifications_enabled',
      'document_release_in_app_notifications_enabled',
      'purchase_approval_email_enabled',
      'expense_approval_email_enabled',
      'payroll_status_email_enabled'
    ),
    'payroll_confirmation_in_app_notifications_enabled',
    v_settings.payroll_confirmation_in_app_notifications_enabled,
    'document_release_in_app_notifications_enabled',
    v_settings.document_release_in_app_notifications_enabled,
    'purchase_approval_email_enabled',
    v_settings.purchase_approval_email_enabled,
    'expense_approval_email_enabled',
    v_settings.expense_approval_email_enabled,
    'payroll_status_email_enabled',
    v_settings.payroll_status_email_enabled
  );
end;
$$;
-- ── 4. Update update_system_settings() ──────────────────────────────────────

create or replace function system.update_system_settings(settings_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
declare
  v_allowed_keys constant text[] := array[
    'payroll_confirmation_in_app_notifications_enabled',
    'document_release_in_app_notifications_enabled',
    'purchase_approval_email_enabled',
    'expense_approval_email_enabled',
    'payroll_status_email_enabled'
  ];
  v_key text;
  v_invalid_keys text[];
  v_settings system.system_settings%rowtype;
  v_old_values jsonb;
  v_new_values jsonb;
  v_changed_keys text[] := '{}';
begin
  if core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  if settings_patch is null or jsonb_typeof(settings_patch) <> 'object' then
    raise exception 'settings_patch must be a JSON object';
  end if;

  -- Reject unknown keys
  select array_agg(key order by key)
  into v_invalid_keys
  from jsonb_object_keys(settings_patch) as key
  where key <> all(v_allowed_keys);

  if coalesce(array_length(v_invalid_keys, 1), 0) > 0 then
    raise exception 'Unsupported system settings key(s): %', array_to_string(v_invalid_keys, ', ');
  end if;

  -- Require at least one valid key
  if not exists (
    select 1
    from jsonb_object_keys(settings_patch) as key
    where key = any(v_allowed_keys)
  ) then
    raise exception 'No supported system settings keys were provided';
  end if;

  -- Validate boolean types for every provided key
  for v_key in select key from jsonb_object_keys(settings_patch) as key
  loop
    if jsonb_typeof(settings_patch -> v_key) <> 'boolean' then
      raise exception '% must be a boolean', v_key;
    end if;
  end loop;

  -- Lock settings row
  select *
  into v_settings
  from system.system_settings
  where settings_key = 'global'
  for update;

  if not found then
    raise exception 'System settings row is missing';
  end if;

  -- Snapshot old values
  v_old_values := jsonb_build_object(
    'payroll_confirmation_in_app_notifications_enabled',
    v_settings.payroll_confirmation_in_app_notifications_enabled,
    'document_release_in_app_notifications_enabled',
    v_settings.document_release_in_app_notifications_enabled,
    'purchase_approval_email_enabled',
    v_settings.purchase_approval_email_enabled,
    'expense_approval_email_enabled',
    v_settings.expense_approval_email_enabled,
    'payroll_status_email_enabled',
    v_settings.payroll_status_email_enabled
  );

  -- Apply each key and track changes
  if settings_patch ? 'payroll_confirmation_in_app_notifications_enabled' then
    if v_settings.payroll_confirmation_in_app_notifications_enabled is distinct from
       (settings_patch ->> 'payroll_confirmation_in_app_notifications_enabled')::boolean then
      v_changed_keys := array_append(v_changed_keys, 'payroll_confirmation_in_app_notifications_enabled');
    end if;
    v_settings.payroll_confirmation_in_app_notifications_enabled :=
      (settings_patch ->> 'payroll_confirmation_in_app_notifications_enabled')::boolean;
  end if;

  if settings_patch ? 'document_release_in_app_notifications_enabled' then
    if v_settings.document_release_in_app_notifications_enabled is distinct from
       (settings_patch ->> 'document_release_in_app_notifications_enabled')::boolean then
      v_changed_keys := array_append(v_changed_keys, 'document_release_in_app_notifications_enabled');
    end if;
    v_settings.document_release_in_app_notifications_enabled :=
      (settings_patch ->> 'document_release_in_app_notifications_enabled')::boolean;
  end if;

  if settings_patch ? 'purchase_approval_email_enabled' then
    if v_settings.purchase_approval_email_enabled is distinct from
       (settings_patch ->> 'purchase_approval_email_enabled')::boolean then
      v_changed_keys := array_append(v_changed_keys, 'purchase_approval_email_enabled');
    end if;
    v_settings.purchase_approval_email_enabled :=
      (settings_patch ->> 'purchase_approval_email_enabled')::boolean;
  end if;

  if settings_patch ? 'expense_approval_email_enabled' then
    if v_settings.expense_approval_email_enabled is distinct from
       (settings_patch ->> 'expense_approval_email_enabled')::boolean then
      v_changed_keys := array_append(v_changed_keys, 'expense_approval_email_enabled');
    end if;
    v_settings.expense_approval_email_enabled :=
      (settings_patch ->> 'expense_approval_email_enabled')::boolean;
  end if;

  if settings_patch ? 'payroll_status_email_enabled' then
    if v_settings.payroll_status_email_enabled is distinct from
       (settings_patch ->> 'payroll_status_email_enabled')::boolean then
      v_changed_keys := array_append(v_changed_keys, 'payroll_status_email_enabled');
    end if;
    v_settings.payroll_status_email_enabled :=
      (settings_patch ->> 'payroll_status_email_enabled')::boolean;
  end if;

  -- Persist
  update system.system_settings
  set
    payroll_confirmation_in_app_notifications_enabled =
      v_settings.payroll_confirmation_in_app_notifications_enabled,
    document_release_in_app_notifications_enabled =
      v_settings.document_release_in_app_notifications_enabled,
    purchase_approval_email_enabled =
      v_settings.purchase_approval_email_enabled,
    expense_approval_email_enabled =
      v_settings.expense_approval_email_enabled,
    payroll_status_email_enabled =
      v_settings.payroll_status_email_enabled,
    updated_at = now()
  where settings_key = 'global';

  -- Snapshot new values
  v_new_values := jsonb_build_object(
    'payroll_confirmation_in_app_notifications_enabled',
    v_settings.payroll_confirmation_in_app_notifications_enabled,
    'document_release_in_app_notifications_enabled',
    v_settings.document_release_in_app_notifications_enabled,
    'purchase_approval_email_enabled',
    v_settings.purchase_approval_email_enabled,
    'expense_approval_email_enabled',
    v_settings.expense_approval_email_enabled,
    'payroll_status_email_enabled',
    v_settings.payroll_status_email_enabled
  );

  -- Audit
  perform system.write_audit_log(
    'system_settings_updated',
    'system_settings',
    null,
    jsonb_build_object(
      'settings_key', 'global',
      'update_mode', 'partial_patch',
      'changed_keys', to_jsonb(v_changed_keys),
      'old_values', v_old_values,
      'new_values', v_new_values
    )
  );

  return v_new_values;
end;
$$;
-- ── 5. Expand email enqueue trigger ─────────────────────────────────────────
-- Replaces first-wave-only function with full second-wave handler.
-- Adds: purchase_approved, purchase_rejected, payroll_confirmed, payroll_rejected.
-- Preserves: account_created, document_released (unchanged).

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

  -- ── purchase_approved / purchase_rejected (second-wave) ────────────────────
  -- Recipient: the user who submitted the purchase request (requested_by).
  -- requested_by is uuid references office_user_profiles(auth_id), nullable
  -- for legacy rows — skip if null.
  elsif new.action in ('purchase_approved', 'purchase_rejected')
        and new.entity_type = 'purchase_request'
        and new.entity_id is not null then

    -- Check settings gate
    select *
    into v_settings
    from system.system_settings
    where settings_key = 'global';

    if not coalesce(v_settings.purchase_approval_email_enabled, true) then
      return new;
    end if;

    -- Look up purchase request + requester profile
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

  -- ── payroll_confirmed / payroll_rejected (second-wave) ─────────────────────
  -- Recipients: all active super_admin + brand_admin users.
  -- Matches existing notify_payroll_confirmed() audience (migration 270).
  elsif new.action in ('payroll_confirmed', 'payroll_rejected')
        and new.entity_type = 'payroll_record'
        and new.entity_id is not null then

    -- Check settings gate
    select *
    into v_settings
    from system.system_settings
    where settings_key = 'global';

    if not coalesce(v_settings.payroll_status_email_enabled, true) then
      return new;
    end if;

    -- Look up payroll record for subject/payload context
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
      -- Fan-out to super_admin + brand_admin (same audience as in-app notification)
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

  end if;

  return new;
end;
$$;
-- ── 6. Replace trigger to use renamed function ──────────────────────────────

drop trigger if exists trg_enqueue_first_wave_email_from_audit_log on system.audit_log;
drop trigger if exists trg_enqueue_email_from_audit_log on system.audit_log;
create trigger trg_enqueue_email_from_audit_log
after insert on system.audit_log
for each row
execute function system.enqueue_email_from_audit_log();
-- Clean up orphaned first-wave function (trigger no longer references it)
drop function if exists system.enqueue_first_wave_email_from_audit_log();
