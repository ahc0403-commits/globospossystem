create or replace function core.current_account_id()
returns uuid
language sql
stable
as $$
  select auth.uid();
$$;
create or replace function core.current_role()
returns text
language sql
stable
as $$
  select role from core.accounts where id = auth.uid();
$$;
create or replace function core.current_brand_id()
returns uuid
language sql
stable
as $$
  select scope_brand_id from core.accounts where id = auth.uid();
$$;
create or replace function core.current_store_id()
returns uuid
language sql
stable
as $$
  select scope_store_id from core.accounts where id = auth.uid();
$$;
