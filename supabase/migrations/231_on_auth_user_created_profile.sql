create or replace function public.handle_new_office_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.office_user_profiles (
    auth_id,
    display_name,
    email,
    account_level,
    scope_type,
    scope_ids,
    is_active
  )
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data ->> 'display_name',
      new.raw_user_meta_data ->> 'name',
      split_part(new.email, '@', 1)
    ),
    new.email,
    coalesce(new.raw_user_meta_data ->> 'account_level', 'staff'),
    coalesce(new.raw_user_meta_data ->> 'scope_type', 'store'),
    case
      when jsonb_typeof(new.raw_user_meta_data -> 'scope_ids') = 'array'
        then (new.raw_user_meta_data -> 'scope_ids')
      else '[]'::jsonb
    end,
    true
  )
  on conflict (auth_id) do update
    set
      display_name = excluded.display_name,
      email = excluded.email,
      account_level = excluded.account_level,
      scope_type = excluded.scope_type,
      scope_ids = excluded.scope_ids,
      updated_at = now();

  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_office_user();
