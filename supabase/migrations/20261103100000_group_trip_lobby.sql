-- Group trip lobby: the group leader plans a trip (destination plus the
-- route everyone will ride), group members join it and get a seat, and the
-- leader starts or cancels it. A group has at most one open trip at a time.
--
-- A seat is a small per-trip number that live position broadcasts carry
-- instead of a user id (see PositionCodec in brodie-mobile).

alter table group_trips
  add column route geography(linestring, 4326),
  -- Goes up whenever the shared route changes, so riders know to reload it.
  add column route_version integer not null default 1,
  add column distance_m numeric check (distance_m >= 0),
  add column duration_s integer check (duration_s >= 0);

-- Trips from the old create_group_trip have no route and no app ever showed
-- them; close them so the one-open-trip rule below can apply.
update group_trips set status = 'cancelled', ended_at = now()
where route is null and status in ('planned', 'active');

create unique index group_trips_one_open_per_group on group_trips (group_id)
  where status in ('planned', 'active');

create table trip_riders (
  trip_id uuid not null references group_trips (id) on delete cascade,
  user_id uuid not null references profiles (id) on delete cascade,
  seat smallint not null check (seat >= 0),
  status text not null default 'joined' check (status in ('joined', 'left')),
  joined_at timestamptz not null default now(),
  primary key (trip_id, user_id),
  unique (trip_id, seat)
);

create index trip_riders_user_id_idx on trip_riders (user_id);

alter table trip_riders enable row level security;
-- No policies: read and written through the functions below.

-- Replaced by plan_group_trip and get_open_group_trip; no app called them.
drop function create_group_trip(uuid, double precision, double precision, text);
drop function get_group_trips(uuid);

create function is_joined_group_member(target_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from group_members gm
    where gm.group_id = target_group_id and gm.user_id = auth.uid() and gm.status = 'joined'
  );
$$;

-- The trip's row, locked, after checking the caller leads its group.
create function lock_trip_as_leader(target_trip_id uuid)
returns group_trips
language plpgsql
security definer
set search_path = public
as $$
declare
  trip group_trips;
begin
  select t.* into trip from group_trips t where t.id = target_trip_id for update;
  if not found or not exists (select 1 from groups g where g.id = trip.group_id and g.leader_id = auth.uid()) then
    raise exception 'Only the group leader can do that.';
  end if;
  return trip;
end;
$$;

create function plan_group_trip(
  target_group_id uuid,
  destination_lng double precision,
  destination_lat double precision,
  route_polyline6 text,
  route_distance_m numeric,
  route_duration_s integer,
  trip_name text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  route_geom geometry;
  new_trip_id uuid;
begin
  if not exists (select 1 from groups g where g.id = target_group_id and g.leader_id = auth.uid()) then
    raise exception 'Only the group leader can plan a ride.';
  end if;

  route_geom := ST_LineFromEncodedPolyline(route_polyline6, 6);
  if route_geom is null or ST_NPoints(route_geom) < 2 then
    raise exception 'A ride route needs at least 2 points.';
  end if;

  begin
    insert into group_trips (group_id, name, destination, created_by, route, distance_m, duration_s)
    values (
      target_group_id,
      left(nullif(trim(trip_name), ''), 200),
      ST_SetSRID(ST_MakePoint(destination_lng, destination_lat), 4326)::geography,
      auth.uid(),
      route_geom::geography,
      route_distance_m,
      route_duration_s
    )
    returning group_trips.id into new_trip_id;
  exception
    when unique_violation then
      raise exception 'This group already has a ride planned. Cancel it before planning another.';
  end;

  insert into trip_riders (trip_id, user_id, seat) values (new_trip_id, auth.uid(), 0);
  return new_trip_id;
end;
$$;

-- The group's planned or active trip, if any.
create function get_open_group_trip(target_group_id uuid)
returns table (
  id uuid,
  group_id uuid,
  leader_id uuid,
  name text,
  destination_lng double precision,
  destination_lat double precision,
  status text,
  route_polyline6 text,
  route_version integer,
  distance_m numeric,
  duration_s integer,
  created_at timestamptz,
  started_at timestamptz
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select t.id, t.group_id, g.leader_id, t.name, ST_X(t.destination::geometry), ST_Y(t.destination::geometry),
         t.status, ST_AsEncodedPolyline(t.route::geometry, 6), t.route_version, t.distance_m, t.duration_s,
         t.created_at, t.started_at
  from group_trips t
  join groups g on g.id = t.group_id
  where t.group_id = target_group_id
    and t.status in ('planned', 'active')
    and is_joined_group_member(t.group_id);
$$;

create function get_trip_riders(target_trip_id uuid)
returns table (user_id uuid, username text, seat smallint, is_leader boolean, joined_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select r.user_id, p.username, r.seat, r.user_id = g.leader_id, r.joined_at
  from trip_riders r
  join group_trips t on t.id = r.trip_id
  join groups g on g.id = t.group_id
  join profiles p on p.id = r.user_id
  where r.trip_id = target_trip_id
    and r.status = 'joined'
    and is_joined_group_member(t.group_id)
  order by r.seat;
$$;

-- Joining again after leaving keeps the same seat. Riders may join a trip
-- that has already started.
create function join_group_trip(target_trip_id uuid)
returns smallint
language plpgsql
security definer
set search_path = public
as $$
declare
  trip group_trips;
  rider_seat smallint;
begin
  -- The lock makes concurrent joins take seats one at a time.
  select t.* into trip from group_trips t where t.id = target_trip_id for update;
  if not found or not is_joined_group_member(trip.group_id) then
    raise exception 'You are not a member of this group.';
  end if;
  if trip.status not in ('planned', 'active') then
    raise exception 'This ride has already ended.';
  end if;

  update trip_riders r set status = 'joined'
  where r.trip_id = target_trip_id and r.user_id = auth.uid()
  returning r.seat into rider_seat;
  if found then
    return rider_seat;
  end if;

  select coalesce(max(r.seat) + 1, 0) into rider_seat from trip_riders r where r.trip_id = target_trip_id;
  insert into trip_riders (trip_id, user_id, seat) values (target_trip_id, auth.uid(), rider_seat);
  return rider_seat;
end;
$$;

create function leave_group_trip(target_trip_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (
    select 1 from group_trips t join groups g on g.id = t.group_id
    where t.id = target_trip_id and g.leader_id = auth.uid()
  ) then
    raise exception 'As the leader, cancel the ride instead of leaving it.';
  end if;

  update trip_riders set status = 'left'
  where trip_id = target_trip_id and user_id = auth.uid();
end;
$$;

create function start_group_trip(target_trip_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  trip group_trips := lock_trip_as_leader(target_trip_id);
begin
  if trip.status <> 'planned' then
    raise exception 'This ride has already started or ended.';
  end if;
  update group_trips set status = 'active', started_at = now() where id = target_trip_id;
end;
$$;

create function cancel_group_trip(target_trip_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  trip group_trips := lock_trip_as_leader(target_trip_id);
begin
  if trip.status not in ('planned', 'active') then
    raise exception 'This ride has already ended.';
  end if;
  update group_trips set status = 'cancelled', ended_at = now() where id = target_trip_id;
end;
$$;

-- Adds each group's open trip status, so the groups list can show a ride
-- is planned or under way. Return columns change, so drop first.
drop function get_my_groups();

create function get_my_groups()
returns table (
  id uuid,
  name text,
  invite_code text,
  leader_id uuid,
  created_at timestamptz,
  member_count bigint,
  open_trip_status text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    g.id,
    g.name,
    g.invite_code,
    g.leader_id,
    g.created_at,
    (select count(*) from group_members gm2 where gm2.group_id = g.id and gm2.status = 'joined'),
    (select t.status from group_trips t where t.group_id = g.id and t.status in ('planned', 'active'))
  from groups g
  join group_members gm on gm.group_id = g.id
  where gm.user_id = auth.uid()
    and gm.status = 'joined'
  order by g.created_at desc;
$$;

revoke execute on function is_joined_group_member(uuid) from public, anon;
revoke execute on function lock_trip_as_leader(uuid) from public, anon, authenticated;
revoke execute on function plan_group_trip(uuid, double precision, double precision, text, numeric, integer, text) from public, anon;
revoke execute on function get_open_group_trip(uuid) from public, anon;
revoke execute on function get_trip_riders(uuid) from public, anon;
revoke execute on function join_group_trip(uuid) from public, anon;
revoke execute on function leave_group_trip(uuid) from public, anon;
revoke execute on function start_group_trip(uuid) from public, anon;
revoke execute on function cancel_group_trip(uuid) from public, anon;
revoke execute on function get_my_groups() from public, anon;

grant execute on function is_joined_group_member(uuid) to authenticated;
grant execute on function plan_group_trip(uuid, double precision, double precision, text, numeric, integer, text) to authenticated;
grant execute on function get_open_group_trip(uuid) to authenticated;
grant execute on function get_trip_riders(uuid) to authenticated;
grant execute on function join_group_trip(uuid) to authenticated;
grant execute on function leave_group_trip(uuid) to authenticated;
grant execute on function start_group_trip(uuid) to authenticated;
grant execute on function cancel_group_trip(uuid) to authenticated;
grant execute on function get_my_groups() to authenticated;
