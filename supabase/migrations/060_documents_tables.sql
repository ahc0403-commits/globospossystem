create table if not exists documents.documents (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  category text not null,
  scope text not null,
  updated_at timestamptz not null default now(),
  version text not null,
  status documents.doc_status not null,
  is_pinned boolean default false,
  brand_id uuid references ops.brands(id),
  visibility text not null default 'all' check (visibility in ('all', 'brand', 'store', 'admin'))
);
create table if not exists documents.document_versions (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references documents.documents(id) on delete cascade,
  version text not null,
  created_at timestamptz not null default now(),
  note text not null
);
