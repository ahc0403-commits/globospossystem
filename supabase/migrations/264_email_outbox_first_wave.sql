-- First-wave email integration:
-- 1. Queue email work asynchronously from already-audited business events.
-- 2. Keep email delivery outside core write transactions.
-- 3. Start with deterministic-recipient events only:
--    - account_created
--    - document_released

create table if not exists system.email_outbox (
  id uuid primary key default gen_random_uuid(),
  source_audit_log_id uuid references system.audit_log(id) on delete set null,
  event_action text not null check (event_action in ('account_created', 'document_released')),
  template_key text not null check (template_key in ('account_created', 'document_released')),
  recipient_auth_id uuid references auth.users(id) on delete set null,
  recipient_email text not null,
  recipient_name text,
  subject text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending', 'processing', 'sent', 'failed', 'dead')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  max_attempts integer not null default 5 check (max_attempts > 0),
  last_error text,
  provider text,
  provider_message_id text,
  provider_response jsonb,
  next_attempt_at timestamptz not null default now(),
  locked_at timestamptz,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_email_outbox_status_due
  on system.email_outbox(status, next_attempt_at, created_at);
create index if not exists idx_email_outbox_audit
  on system.email_outbox(source_audit_log_id);
create unique index if not exists idx_email_outbox_source_recipient
  on system.email_outbox(source_audit_log_id, recipient_email)
  where source_audit_log_id is not null;
alter table system.email_outbox enable row level security;
drop policy if exists email_outbox_select_admin on system.email_outbox;
create policy email_outbox_select_admin
on system.email_outbox
for select
to authenticated
using (core.current_role() = 'superAdmin');
grant usage on schema system to authenticated, service_role;
grant select on system.email_outbox to authenticated, service_role;
grant insert, update on system.email_outbox to service_role;
create or replace function system.enqueue_email_outbox(
  p_source_audit_log_id uuid,
  p_event_action text,
  p_template_key text,
  p_recipient_auth_id uuid,
  p_recipient_email text,
  p_recipient_name text,
  p_subject text,
  p_payload jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
declare
  v_email text := lower(trim(coalesce(p_recipient_email, '')));
begin
  if v_email = '' then
    return;
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
  values (
    p_source_audit_log_id,
    p_event_action,
    p_template_key,
    p_recipient_auth_id,
    v_email,
    nullif(trim(coalesce(p_recipient_name, '')), ''),
    p_subject,
    coalesce(p_payload, '{}'::jsonb)
  )
  on conflict do nothing;
end;
$$;
create or replace function system.enqueue_first_wave_email_from_audit_log()
returns trigger
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
declare
  v_profile public.office_user_profiles%rowtype;
begin
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
  end if;

  return new;
end;
$$;
drop trigger if exists trg_enqueue_first_wave_email_from_audit_log on system.audit_log;
create trigger trg_enqueue_first_wave_email_from_audit_log
after insert on system.audit_log
for each row
execute function system.enqueue_first_wave_email_from_audit_log();
create or replace function system.claim_email_outbox_batch(p_limit integer default 20)
returns table (
  id uuid,
  event_action text,
  template_key text,
  recipient_email text,
  recipient_name text,
  subject text,
  payload jsonb,
  attempt_count integer,
  max_attempts integer
)
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
begin
  return query
  with candidates as (
    select eo.id
    from system.email_outbox eo
    where eo.status in ('pending', 'failed')
      and eo.next_attempt_at <= now()
      and (eo.locked_at is null or eo.locked_at < now() - interval '15 minutes')
    order by eo.created_at
    limit greatest(1, least(coalesce(p_limit, 20), 100))
    for update skip locked
  ),
  claimed as (
    update system.email_outbox eo
    set
      status = 'processing',
      locked_at = now(),
      updated_at = now()
    from candidates c
    where eo.id = c.id
    returning eo.*
  )
  select
    claimed.id,
    claimed.event_action,
    claimed.template_key,
    claimed.recipient_email,
    claimed.recipient_name,
    claimed.subject,
    claimed.payload,
    claimed.attempt_count,
    claimed.max_attempts
  from claimed;
end;
$$;
create or replace function system.mark_email_outbox_sent(
  p_id uuid,
  p_provider_message_id text default null,
  p_provider_response jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
begin
  update system.email_outbox
  set
    status = 'sent',
    provider = 'resend',
    provider_message_id = p_provider_message_id,
    provider_response = coalesce(p_provider_response, '{}'::jsonb),
    sent_at = now(),
    locked_at = null,
    updated_at = now()
  where id = p_id;
end;
$$;
create or replace function system.mark_email_outbox_failed(
  p_id uuid,
  p_error text,
  p_provider_response jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
begin
  update system.email_outbox
  set
    attempt_count = attempt_count + 1,
    last_error = left(coalesce(p_error, 'Unknown email send failure'), 4000),
    provider = 'resend',
    provider_response = coalesce(p_provider_response, '{}'::jsonb),
    status = case
      when attempt_count + 1 >= max_attempts then 'dead'
      else 'failed'
    end,
    next_attempt_at = case
      when attempt_count + 1 >= max_attempts then now()
      when attempt_count + 1 = 1 then now() + interval '5 minutes'
      when attempt_count + 1 = 2 then now() + interval '15 minutes'
      when attempt_count + 1 = 3 then now() + interval '1 hour'
      else now() + interval '6 hours'
    end,
    locked_at = null,
    updated_at = now()
  where id = p_id;
end;
$$;
grant execute on function system.claim_email_outbox_batch(integer) to service_role;
grant execute on function system.mark_email_outbox_sent(uuid, text, jsonb) to service_role;
grant execute on function system.mark_email_outbox_failed(uuid, text, jsonb) to service_role;
