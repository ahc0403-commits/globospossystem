-- Inbound receipt/invoice attachment intake foundation (office internal system).
--
-- Boundaries:
-- 1. Gmail/external mailbox remains source of truth for raw email and binaries.
-- 2. Office stores bounded intake metadata + attachment references only.
-- 3. Manual review/linking only; no mailbox mirroring, OCR, or auto-linking.

create table if not exists system.email_inbound_intake (
  id uuid primary key default gen_random_uuid(),
  source_provider text not null default 'gmail' check (source_provider in ('gmail', 'unknown')),
  source_mailbox text not null,
  external_message_ref text not null,
  received_at timestamptz not null,
  sender_email text not null,
  subject text,
  attachment_count integer not null default 0 check (attachment_count >= 0),
  attachment_refs jsonb not null default '[]'::jsonb,
  processing_status text not null default 'new' check (
    processing_status in ('new', 'needs_review', 'linked', 'ignored')
  ),
  status_note text,
  target_entity_type text check (target_entity_type in ('expense', 'purchase_request', 'document')),
  target_entity_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint email_inbound_intake_message_ref_unique unique (source_mailbox, external_message_ref),
  constraint email_inbound_intake_attachment_refs_array check (jsonb_typeof(attachment_refs) = 'array'),
  constraint email_inbound_intake_link_pair_check check (
    (target_entity_type is null and target_entity_id is null)
    or (target_entity_type is not null and target_entity_id is not null)
  )
);
create index if not exists idx_email_inbound_intake_status_received
  on system.email_inbound_intake (processing_status, received_at desc, created_at desc);
create index if not exists idx_email_inbound_intake_received
  on system.email_inbound_intake (received_at desc);
create index if not exists idx_email_inbound_intake_target
  on system.email_inbound_intake (target_entity_type, target_entity_id)
  where target_entity_id is not null;
create or replace function system.touch_email_inbound_intake_updated_at()
returns trigger
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
drop trigger if exists trg_touch_email_inbound_intake_updated_at
  on system.email_inbound_intake;
create trigger trg_touch_email_inbound_intake_updated_at
before update on system.email_inbound_intake
for each row
execute function system.touch_email_inbound_intake_updated_at();
alter table system.email_inbound_intake enable row level security;
drop policy if exists email_inbound_intake_select_admin on system.email_inbound_intake;
create policy email_inbound_intake_select_admin
on system.email_inbound_intake
for select
to authenticated
using (core.current_role() = 'superAdmin');
grant usage on schema system to authenticated, service_role;
grant select on system.email_inbound_intake to authenticated, service_role;
grant insert, update on system.email_inbound_intake to service_role;
create or replace function system.record_email_inbound_intake(
  p_source_provider text,
  p_source_mailbox text,
  p_external_message_ref text,
  p_received_at timestamptz,
  p_sender_email text,
  p_subject text,
  p_attachment_refs jsonb default '[]'::jsonb,
  p_attachment_count integer default null
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
declare
  v_source_provider text := lower(trim(coalesce(p_source_provider, 'gmail')));
  v_source_mailbox text := trim(coalesce(p_source_mailbox, ''));
  v_external_message_ref text := trim(coalesce(p_external_message_ref, ''));
  v_sender_email text := lower(trim(coalesce(p_sender_email, '')));
  v_subject text := nullif(trim(coalesce(p_subject, '')), '');
  v_attachment_refs jsonb := coalesce(p_attachment_refs, '[]'::jsonb);
  v_attachment_count integer;
  v_row_id uuid;
begin
  if v_source_provider = '' then
    v_source_provider := 'gmail';
  end if;

  if v_source_provider not in ('gmail', 'unknown') then
    raise exception 'Unsupported source_provider %', v_source_provider;
  end if;

  if v_source_mailbox = '' then
    raise exception 'source_mailbox is required';
  end if;

  if v_external_message_ref = '' then
    raise exception 'external_message_ref is required';
  end if;

  if v_sender_email = '' then
    raise exception 'sender_email is required';
  end if;

  if jsonb_typeof(v_attachment_refs) <> 'array' then
    raise exception 'attachment_refs must be a JSON array';
  end if;

  v_attachment_count := coalesce(
    p_attachment_count,
    jsonb_array_length(v_attachment_refs),
    0
  );

  if v_attachment_count < 0 then
    raise exception 'attachment_count must be >= 0';
  end if;

  insert into system.email_inbound_intake (
    source_provider,
    source_mailbox,
    external_message_ref,
    received_at,
    sender_email,
    subject,
    attachment_count,
    attachment_refs
  )
  values (
    v_source_provider,
    v_source_mailbox,
    v_external_message_ref,
    coalesce(p_received_at, now()),
    v_sender_email,
    v_subject,
    v_attachment_count,
    v_attachment_refs
  )
  on conflict (source_mailbox, external_message_ref)
  do update set
    source_provider = excluded.source_provider,
    received_at = excluded.received_at,
    sender_email = excluded.sender_email,
    subject = excluded.subject,
    attachment_count = excluded.attachment_count,
    attachment_refs = excluded.attachment_refs,
    updated_at = now()
  returning id into v_row_id;

  return v_row_id;
end;
$$;
grant execute on function system.record_email_inbound_intake(
  text,
  text,
  text,
  timestamptz,
  text,
  text,
  jsonb,
  integer
) to service_role;
create or replace function system.get_email_inbound_intake_queue(
  p_status_filter text default 'unclassified',
  p_limit integer default 200
)
returns table (
  id uuid,
  source_provider text,
  source_mailbox text,
  external_message_ref text,
  received_at timestamptz,
  sender_email text,
  subject text,
  attachment_count integer,
  attachment_refs jsonb,
  processing_status text,
  status_note text,
  target_entity_type text,
  target_entity_id uuid,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
declare
  v_filter text := lower(trim(coalesce(p_status_filter, 'unclassified')));
  v_limit integer := greatest(1, least(coalesce(p_limit, 200), 500));
begin
  if core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  if v_filter not in (
    'all',
    'unclassified',
    'new',
    'needs_review',
    'linked',
    'ignored'
  ) then
    raise exception 'Unsupported status filter %', v_filter;
  end if;

  return query
  select
    i.id,
    i.source_provider,
    i.source_mailbox,
    i.external_message_ref,
    i.received_at,
    i.sender_email,
    i.subject,
    i.attachment_count,
    i.attachment_refs,
    i.processing_status,
    i.status_note,
    i.target_entity_type,
    i.target_entity_id,
    i.created_at,
    i.updated_at
  from system.email_inbound_intake i
  where (
    v_filter = 'all'
    or (
      v_filter = 'unclassified'
      and i.processing_status in ('new', 'needs_review')
    )
    or i.processing_status = v_filter
  )
  order by
    case
      when i.processing_status in ('new', 'needs_review') then 0
      else 1
    end,
    i.received_at desc,
    i.created_at desc
  limit v_limit;
end;
$$;
grant execute on function system.get_email_inbound_intake_queue(text, integer)
  to authenticated;
create or replace function system.set_email_inbound_intake_status(
  p_intake_id uuid,
  p_status text,
  p_status_note text default null
)
returns void
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
declare
  v_status text := lower(trim(coalesce(p_status, '')));
  v_row system.email_inbound_intake%rowtype;
begin
  if core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  if p_intake_id is null then
    raise exception 'intake_id is required';
  end if;

  if v_status not in ('new', 'needs_review', 'ignored') then
    raise exception 'Status must be one of: new, needs_review, ignored';
  end if;

  select *
  into v_row
  from system.email_inbound_intake i
  where i.id = p_intake_id
  for update;

  if not found then
    raise exception 'Inbound intake row % not found', p_intake_id;
  end if;

  update system.email_inbound_intake
  set
    processing_status = v_status,
    status_note = nullif(trim(coalesce(p_status_note, '')), ''),
    target_entity_type = case when v_status = 'ignored' then null else target_entity_type end,
    target_entity_id = case when v_status = 'ignored' then null else target_entity_id end
  where id = p_intake_id;

  perform system.write_audit_log(
    'email_inbound_intake_status_updated',
    'email_inbound_intake',
    p_intake_id,
    jsonb_build_object(
      'old_status', v_row.processing_status,
      'new_status', v_status,
      'old_target_entity_type', v_row.target_entity_type,
      'old_target_entity_id', v_row.target_entity_id,
      'status_note', nullif(trim(coalesce(p_status_note, '')), '')
    )
  );
end;
$$;
grant execute on function system.set_email_inbound_intake_status(uuid, text, text)
  to authenticated;
create or replace function system.link_email_inbound_intake(
  p_intake_id uuid,
  p_target_entity_type text,
  p_target_entity_id uuid,
  p_status_note text default null
)
returns void
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
declare
  v_target_type text := lower(trim(coalesce(p_target_entity_type, '')));
  v_row system.email_inbound_intake%rowtype;
  v_exists boolean := false;
begin
  if core.current_role() <> 'superAdmin' then
    raise exception 'Insufficient permissions: superAdmin required';
  end if;

  if p_intake_id is null then
    raise exception 'intake_id is required';
  end if;

  if p_target_entity_id is null then
    raise exception 'target_entity_id is required';
  end if;

  if v_target_type not in ('expense', 'purchase_request', 'document') then
    raise exception 'Unsupported target_entity_type %', v_target_type;
  end if;

  if v_target_type = 'expense' then
    select exists(
      select 1
      from accounting.expenses e
      where e.id = p_target_entity_id
    ) into v_exists;
  elsif v_target_type = 'purchase_request' then
    select exists(
      select 1
      from accounting.purchase_requests pr
      where pr.id = p_target_entity_id
    ) into v_exists;
  elsif v_target_type = 'document' then
    select exists(
      select 1
      from documents.documents d
      where d.id = p_target_entity_id
    ) into v_exists;
  end if;

  if not v_exists then
    raise exception 'Target record % (%) was not found', v_target_type, p_target_entity_id;
  end if;

  select *
  into v_row
  from system.email_inbound_intake i
  where i.id = p_intake_id
  for update;

  if not found then
    raise exception 'Inbound intake row % not found', p_intake_id;
  end if;

  update system.email_inbound_intake
  set
    processing_status = 'linked',
    target_entity_type = v_target_type,
    target_entity_id = p_target_entity_id,
    status_note = nullif(trim(coalesce(p_status_note, '')), '')
  where id = p_intake_id;

  perform system.write_audit_log(
    'email_inbound_intake_linked',
    'email_inbound_intake',
    p_intake_id,
    jsonb_build_object(
      'old_status', v_row.processing_status,
      'new_status', 'linked',
      'old_target_entity_type', v_row.target_entity_type,
      'old_target_entity_id', v_row.target_entity_id,
      'target_entity_type', v_target_type,
      'target_entity_id', p_target_entity_id,
      'status_note', nullif(trim(coalesce(p_status_note, '')), '')
    )
  );
end;
$$;
grant execute on function system.link_email_inbound_intake(uuid, text, uuid, text)
  to authenticated;
create or replace function system.apply_email_inbound_intake_retention(
  p_retention interval default interval '90 days'
)
returns table (
  pruned_count integer,
  cutoff timestamptz
)
language plpgsql
security definer
set search_path = public, auth, core, ops, hr, accounting, documents, system
as $$
declare
  v_retention interval := coalesce(p_retention, interval '90 days');
  v_cutoff timestamptz;
  v_pruned integer := 0;
begin
  if v_retention <= interval '0 seconds' then
    raise exception 'Retention must be positive';
  end if;

  v_cutoff := now() - v_retention;

  delete from system.email_inbound_intake i
  where i.processing_status in ('linked', 'ignored')
    and coalesce(i.updated_at, i.created_at) < v_cutoff;

  get diagnostics v_pruned = row_count;

  return query
  select v_pruned, v_cutoff;
end;
$$;
grant execute on function system.apply_email_inbound_intake_retention(interval)
  to service_role;
do $$
declare
  v_job_id bigint;
begin
  if to_regclass('cron.job') is null then
    return;
  end if;

  for v_job_id in
    select jobid
    from cron.job
    where jobname = 'email-inbound-intake-retention-cleanup'
  loop
    perform cron.unschedule(v_job_id);
  end loop;

  perform cron.schedule(
    'email-inbound-intake-retention-cleanup',
    '40 3 * * *',
    $cron$
      select *
      from system.apply_email_inbound_intake_retention();
    $cron$
  );
end;
$$;
