-- Office integration Phase 2: QC follow-up workflow

create table if not exists public.office_qc_followups (
  id uuid primary key default gen_random_uuid(),
  source_qc_check_id uuid not null references public.qc_checks(id),
  restaurant_id uuid not null references public.restaurants(id),
  brand_id uuid not null references public.brands(id),
  status text not null check (status in ('open', 'in_progress', 'resolved', 'closed')),
  assigned_to uuid,
  resolution_notes text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
