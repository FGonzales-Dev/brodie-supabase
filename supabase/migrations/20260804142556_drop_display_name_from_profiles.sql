alter table profiles drop column display_name;

-- The trigger function inserted display_name on signup; must be replaced so
-- it doesn't reference the now-dropped column.
create or replace function create_profile_on_signup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end;
$$;
