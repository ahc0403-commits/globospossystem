-- Office integration Phase 2: Office purchase approvals

create table if not exists public.office_purchases (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id),
  brand_id uuid not null references public.brands(id),
  status text not null check (status in ('draft', 'submitted', 'approved', 'rejected', 'returned')),
  title text not null,
  description text,
  total_amount numeric(12,2) not null,
  items jsonb,
  requested_by uuid,
  approved_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
