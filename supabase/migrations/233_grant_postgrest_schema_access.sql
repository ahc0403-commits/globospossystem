-- Grant PostgREST access for authenticated role on non-public schemas.
-- RLS still controls row-level access.

grant usage on schema core, hr, ops, accounting, documents, dashboard, system
to authenticated;
grant select on all tables in schema core, hr, ops, accounting, documents, dashboard, system
to authenticated;
grant execute on all functions in schema core, hr, ops, accounting, documents, dashboard, system
to authenticated;
grant execute on function public.current_office_account_level()
to authenticated;
