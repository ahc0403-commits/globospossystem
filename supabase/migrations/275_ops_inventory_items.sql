-- 275: Ops Inventory Items — canonical office-owned inventory table
-- Bundle B-3: foundation table + RLS + indexes (no Flutter pages yet)
-- Note: POS inventory bridge is separate (photo_objet_inventory, dashboard views).
-- This is the office-owned canonical inventory for Operations > Inventory surface.

-- Enum for inventory status
do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'ops' and t.typname = 'inventory_status'
  ) then
    create type ops.inventory_status as enum ('in_stock', 'low_stock', 'out_of_stock', 'discontinued');
  end if;
end $$;
-- Table
create table if not exists ops.inventory_items (
  id              uuid primary key default gen_random_uuid(),
  store_id        uuid not null references ops.stores(id),
  brand_id        uuid not null references ops.brands(id),
  item_name       text not null,
  category        text not null default '',
  quantity         numeric(12,2) not null default 0,
  unit            text not null default '',
  reorder_level   numeric(12,2),
  status          ops.inventory_status not null default 'in_stock',
  last_updated_at timestamptz not null default now(),
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint chk_inventory_quantity check (quantity >= 0)
);
-- Indexes
create index if not exists idx_inventory_store
  on ops.inventory_items (store_id);
create index if not exists idx_inventory_brand
  on ops.inventory_items (brand_id);
create index if not exists idx_inventory_status
  on ops.inventory_items (status);
create index if not exists idx_inventory_category
  on ops.inventory_items (category);
-- RLS
alter table ops.inventory_items enable row level security;
-- Select: superAdmin sees all, brandManager sees own brand, storeManager sees own store
drop policy if exists inventory_select_scoped on ops.inventory_items;
create policy inventory_select_scoped on ops.inventory_items
  for select
  using (
    core.current_role() = 'superAdmin'
    or brand_id = core.current_brand_id()
    or store_id = core.current_store_id()
  );
-- Insert: superAdmin, brandManager, storeManager within their scope
drop policy if exists inventory_insert_scoped on ops.inventory_items;
create policy inventory_insert_scoped on ops.inventory_items
  for insert
  with check (
    core.current_role() = 'superAdmin'
    or (core.current_role() = 'brandManager' and brand_id = core.current_brand_id())
    or (core.current_role() = 'storeManager' and store_id = core.current_store_id())
  );
-- Update: superAdmin, brandManager, storeManager within their scope
drop policy if exists inventory_update_scoped on ops.inventory_items;
create policy inventory_update_scoped on ops.inventory_items
  for update
  using (
    core.current_role() = 'superAdmin'
    or (core.current_role() = 'brandManager' and brand_id = core.current_brand_id())
    or (core.current_role() = 'storeManager' and store_id = core.current_store_id())
  )
  with check (
    core.current_role() = 'superAdmin'
    or (core.current_role() = 'brandManager' and brand_id = core.current_brand_id())
    or (core.current_role() = 'storeManager' and store_id = core.current_store_id())
  );
-- updated_at trigger
create or replace function ops.set_inventory_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;
drop trigger if exists trg_inventory_updated_at on ops.inventory_items;
create trigger trg_inventory_updated_at
  before update on ops.inventory_items
  for each row execute function ops.set_inventory_updated_at();
