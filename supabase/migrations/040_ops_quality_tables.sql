create table if not exists ops.quality_checks (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  category text not null,
  store_id uuid not null references ops.stores(id),
  period text not null,
  status ops.quality_status not null,
  evidence_state text not null,
  issue_note text null,
  created_at timestamptz not null default now()
);
