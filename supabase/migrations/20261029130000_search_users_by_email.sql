-- Riders can now be found by email as well as by username, for group invites.
--
-- Email matching is deliberately exact (the whole address, case-insensitive):
-- partial matching would let any signed-in user harvest other riders'
-- addresses by typing fragments like "@gmail". Results still carry only the
-- public username, never the email itself. Username search is unchanged
-- (prefix match).
create or replace function search_users(search_query text)
returns table (id uuid, username text, avatar_url text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_query text := trim(search_query);
begin
  if length(v_query) < 2 then
    return;
  end if;

  if position('@' in v_query) > 0 then
    return query
      select p.id, p.username, p.avatar_url
      from profiles p
      join auth.users u on u.id = p.id
      where p.username is not null
        and lower(u.email) = lower(v_query)
        and p.id <> auth.uid();
    return;
  end if;

  return query
    select p.id, p.username, p.avatar_url
    from profiles p
    where p.username is not null
      and p.username ilike v_query || '%'
      and p.id <> auth.uid()
    order by p.username
    limit 20;
end;
$$;

grant execute on function search_users(text) to authenticated;
