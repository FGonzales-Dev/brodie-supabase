-- Signature changed (destination params removed — a group no longer has a
-- destination, a trip does), so the old function must be dropped first.
drop function create_ride_group(text, double precision, double precision);

create function create_ride_group(group_name text)
returns table (id uuid, name text, invite_code text, leader_id uuid, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  new_group_id uuid;
  generated_code text;
  attempt int := 0;
begin
  loop
    generated_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    begin
      insert into groups (name, invite_code, leader_id)
      values (group_name, generated_code, auth.uid())
      returning groups.id into new_group_id;
      exit;
    exception
      when unique_violation then
        attempt := attempt + 1;
        if attempt >= 5 then
          raise exception 'Could not generate a unique invite code, please try again.';
        end if;
    end;
  end loop;

  insert into group_members (group_id, user_id, role, status)
  values (new_group_id, auth.uid(), 'leader', 'joined');

  return query
    select g.id, g.name, g.invite_code, g.leader_id, g.created_at
    from groups g
    where g.id = new_group_id;
end;
$$;

grant execute on function create_ride_group(text) to authenticated;

-- Same signature as before, body updated for the renamed tables.
create or replace function add_group_member(target_group_id uuid, target_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from groups
    where id = target_group_id and leader_id = auth.uid()
  ) then
    raise exception 'Only the group leader can add members.';
  end if;

  insert into group_members (group_id, user_id, role, status)
  values (target_group_id, target_user_id, 'member', 'joined')
  on conflict (group_id, user_id) do nothing;
end;
$$;

-- Same signature as before, body updated for the renamed tables.
create or replace function get_active_group_members(target_group_id uuid)
returns table (user_id uuid, username text, avatar_url text, role text, status text, joined_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from group_members
    where group_id = target_group_id and user_id = auth.uid()
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

-- Creates a trip under an existing group — any member can propose one, not
-- just the leader.
create function create_group_trip(
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
    select 1 from group_members
    where group_id = target_group_id and user_id = auth.uid()
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

grant execute on function create_group_trip(uuid, double precision, double precision, text) to authenticated;

create function get_group_trips(target_group_id uuid)
returns table (id uuid, name text, status text, created_at timestamptz, started_at timestamptz, ended_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from group_members
    where group_id = target_group_id and user_id = auth.uid()
  ) then
    raise exception 'You are not a member of this group.';
  end if;

  return query
    select t.id, t.name, t.status, t.created_at, t.started_at, t.ended_at
    from group_trips t
    where t.group_id = target_group_id
    order by t.created_at desc;
end;
$$;

grant execute on function get_group_trips(uuid) to authenticated;
