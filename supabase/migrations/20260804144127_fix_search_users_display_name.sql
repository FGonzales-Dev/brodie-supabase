-- display_name was dropped from profiles; search_users() still referenced it
-- and would fail at runtime the moment it was actually called. Return columns
-- changed, so the old function must be dropped first (CREATE OR REPLACE can't
-- change a function's OUT parameter row type).
drop function search_users(text);

create function search_users(search_query text)
returns table (id uuid, username text, avatar_url text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if length(trim(search_query)) < 2 then
    return;
  end if;

  return query
    select p.id, p.username, p.avatar_url
    from profiles p
    where p.username is not null
      and p.username ilike search_query || '%'
      and p.id <> auth.uid()
    order by p.username
    limit 20;
end;
$$;
