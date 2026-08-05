-- Both functions declare an OUT column (via `returns table (...)`) that
-- shadows a same-named column referenced unqualified in a membership check,
-- causing "column reference is ambiguous" (42702) at call time. Fix: qualify
-- every reference to the shadowed column with its table alias.

create or replace function get_active_group_members(target_group_id uuid)
returns table (user_id uuid, username text, avatar_url text, role text, status text, joined_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from group_members gm
    where gm.group_id = target_group_id and gm.user_id = auth.uid()
  ) then
    raise exception 'You are not a member of this group.';
  end if;

  return query
    select m.user_id, p.username, p.avatar_url, m.role, m.status, m.joined_at
    from group_members m
    join profiles p on p.id = m.user_id
    where m.group_id = target_group_id
      and m.status = 'joined'
    order by m.joined_at;
end;
$$;

create or replace function create_group_trip(
  target_group_id uuid,
  destination_lng double precision,
  destination_lat double precision,
  trip_name text default null
)
returns table (id uuid, group_id uuid, name text, status text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  new_trip_id uuid;
begin
  if not exists (
    select 1 from group_members gm
    where gm.group_id = target_group_id and gm.user_id = auth.uid()
  ) then
    raise exception 'You are not a member of this group.';
  end if;

  insert into group_trips (group_id, name, destination, created_by)
  values (
    target_group_id,
    trip_name,
    ST_SetSRID(ST_MakePoint(destination_lng, destination_lat), 4326)::geography,
    auth.uid()
  )
  returning group_trips.id into new_trip_id;

  return query
    select t.id, t.group_id, t.name, t.status, t.created_at
    from group_trips t
    where t.id = new_trip_id;
end;
$$;
