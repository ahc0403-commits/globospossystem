-- Migration: 254_fix_purchases_canonical_path.sql
-- Fix O-6/M-4: PurchaseRepository was targeting public.office_purchases (removed in 210).
-- Canonical table is accounting.purchase_requests (migration 050).
-- Steps:
--   1. Add nullable columns to accounting.purchase_requests for richer Flutter model.
--   2. Rebuild accounting.purchase_requests_view (first created in 253) to include new columns
--      plus display-name joins for requested_by / approved_by.
--   3. Update accounting.approve_purchase to also set approved_by = auth.uid().
--   4. Add accounting.return_purchase RPC (was missing; PurchaseRepository.returnPurchase
--      previously did a direct UPDATE which bypassed RLS).

-- ── 1. Extend accounting.purchase_requests ────────────────────────────────────

alter table accounting.purchase_requests
  add column if not exists description  text,
  add column if not exists items        jsonb,
  add column if not exists requested_by uuid references public.office_user_profiles(auth_id),
  add column if not exists approved_by  uuid references public.office_user_profiles(auth_id);
-- ── 2. Rebuild purchase_requests_view ─────────────────────────────────────────

drop view if exists accounting.purchase_requests_view;

create or replace view accounting.purchase_requests_view as
select
  pr.id,
  pr.title,
  pr.store_id,
  s.name                as store_name,
  pr.brand_id,
  b.name                as brand_name,
  pr.amount,
  pr.requested_date,
  pr.status,
  pr.description,
  pr.items,
  pr.requested_by,
  rp.display_name       as requested_by_name,
  pr.approved_by,
  ap.display_name       as approved_by_name,
  pr.created_at
from accounting.purchase_requests pr
left join ops.stores s                   on s.id       = pr.store_id
left join ops.brands b                   on b.id       = pr.brand_id
left join public.office_user_profiles rp on rp.auth_id = pr.requested_by
left join public.office_user_profiles ap on ap.auth_id = pr.approved_by;
alter view accounting.purchase_requests_view set (security_invoker = true);
grant select on accounting.purchase_requests_view to authenticated;
-- ── 3. Update approve_purchase to record the approver ────────────────────────

create or replace function accounting.approve_purchase(purchase_id uuid)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() not in ('superAdmin', 'brandManager') then
    raise exception 'Insufficient permissions: brandManager+ required';
  end if;

  if core.current_role() = 'brandManager' then
    if not exists (
      select 1
      from accounting.purchase_requests pr
      where pr.id = purchase_id and pr.brand_id = core.current_brand_id()
    ) then
      raise exception 'Record is outside your brand scope';
    end if;
  end if;

  update accounting.purchase_requests
  set status      = 'approved',
      approved_by = auth.uid()
  where id = purchase_id;
end; $$;
-- ── 4. Add return_purchase RPC ────────────────────────────────────────────────

create or replace function accounting.return_purchase(purchase_id uuid)
returns void
language plpgsql
security definer
set search_path = public, core, ops, hr, accounting, documents, system
as $$
begin
  if core.current_role() not in ('superAdmin', 'brandManager') then
    raise exception 'Insufficient permissions: brandManager+ required';
  end if;

  if core.current_role() = 'brandManager' then
    if not exists (
      select 1
      from accounting.purchase_requests pr
      where pr.id = purchase_id and pr.brand_id = core.current_brand_id()
    ) then
      raise exception 'Record is outside your brand scope';
    end if;
  end if;

  update accounting.purchase_requests
  set status = 'returned'
  where id = purchase_id;
end; $$;
