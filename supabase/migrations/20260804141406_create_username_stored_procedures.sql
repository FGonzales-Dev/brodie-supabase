-- Checking another user's username requires bypassing the restrictive
-- "read your own profile only" RLS policy, so this runs as security definer.
create function is_username_available(check_username text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  return not exists (
    select 1 from profiles where lower(username) = lower(check_username)
  );
end;
$$;

grant execute on function is_username_available(text) to authenticated;

-- Operates only on the caller's own row, which the existing profiles RLS
-- update policy already permits, so this stays security invoker. The point
-- of wrapping it in a function is a friendly error message instead of a raw
-- constraint-violation on conflict.
create function set_username(new_username text)
returns profiles
language plpgsql
set search_path = public
as $$
declare
  updated_profile profiles;
begin
  if new_username !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'Username must be 3-20 characters: lowercase letters, numbers, and underscores only.';
  end if;

  update profiles
  set username = new_username, updated_at = now()
  where id = auth.uid()
  returning * into updated_profile;

  return updated_profile;
exception
  when unique_violation then
    raise exception 'That username is already taken.';
end;
$$;

grant execute on function set_username(text) to authenticated;

-- Searching across other users' profiles requires bypassing the restrictive
-- "read your own profile only" RLS policy, so this runs as security definer
-- and deliberately returns only public-safe fields.
create function search_users(search_query text)
returns table (id uuid, username text, display_name text, avatar_url text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if length(trim(search_query)) < 2 then
    return;
  end if;

  return query
    select p.id, p.username, p.display_name, p.avatar_url
    from profiles p
    where p.username is not null
      and p.username ilike search_query || '%'
      and p.id <> auth.uid()
    order by p.username
    limit 20;
end;
$$;

grant execute on function search_users(text) to authenticated;
