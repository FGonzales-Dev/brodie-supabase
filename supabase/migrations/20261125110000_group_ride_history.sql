-- Past group rides: each rider's saved ride now records the group trip it
-- belonged to, so a group can list its finished rides and show, per ride,
-- who rode and how far. Positions shared live during the ride are still
-- never stored; these stats come from each rider's own saved ride.

-- save_completed_ride gains p_group_trip_id. Its parameter list changes, so
-- the old version is dropped. Apps that don't send the new parameter keep
-- working, because it defaults to null.
drop function save_completed_ride(uuid, text, numeric, integer, integer, numeric, timestamptz, timestamptz, boolean, text, uuid);

-- Saving the same p_id twice returns the existing ride, so the app can retry
-- an upload whose response was lost. A vehicle that isn't the caller's, or a
-- trip they weren't a rider on, is dropped rather than failing the upload
-- forever.
create function save_completed_ride(
  p_id uuid,
  p_route_polyline6 text,
  p_distance_m numeric,
  p_duration_s integer,
  p_moving_s integer,
  p_max_speed_mps numeric,
  p_started_at timestamptz,
  p_ended_at timestamptz,
  p_arrived boolean,
  p_destination_name text default null,
  p_vehicle_id uuid default null,
  p_group_trip_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  route_geom geometry;
  saved_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Sign in to save rides.';
  end if;
  if p_ended_at < p_started_at or p_distance_m < 0 or p_duration_s < 0 or p_moving_s < 0 or p_max_speed_mps < 0 then
    raise exception 'This ride has invalid stats.';
  end if;

  route_geom := ST_LineFromEncodedPolyline(p_route_polyline6, 6);
  if route_geom is null or ST_NPoints(route_geom) < 2 then
    raise exception 'A ride route needs at least 2 points.';
  end if;

  insert into rides (
    id, user_id, vehicle_id, group_trip_id, route, start_point, end_point, distance_m, duration_s, moving_s,
    max_speed_mps, started_at, ended_at, arrived, destination_name
  )
  values (
    p_id,
    auth.uid(),
    (select v.id from vehicles v where v.id = p_vehicle_id and v.user_id = auth.uid()),
    (select tr.trip_id from trip_riders tr where tr.trip_id = p_group_trip_id and tr.user_id = auth.uid()),
    route_geom::geography,
    ST_StartPoint(route_geom)::geography,
    ST_EndPoint(route_geom)::geography,
    p_distance_m,
    p_duration_s,
    p_moving_s,
    p_max_speed_mps,
    p_started_at,
    p_ended_at,
    p_arrived,
    left(nullif(trim(p_destination_name), ''), 200)
  )
  on conflict (id) do nothing;

  select r.id into saved_id from rides r where r.id = p_id and r.user_id = auth.uid();
  if saved_id is null then
    raise exception 'This ride could not be saved.';
  end if;
  return saved_id;
end;
$$;

create index rides_group_trip_id_idx on rides (group_trip_id) where group_trip_id is not null;

-- The rider's history and ride detail now say which group ride a ride was
-- part of. Return columns change, so both are dropped first.
drop function get_ride_history(integer, integer);
drop function get_ride(uuid);

create function get_ride_history(p_limit integer default 20, p_offset integer default 0)
returns table (
  id uuid,
  vehicle_id uuid,
  destination_name text,
  arrived boolean,
  distance_m numeric,
  duration_s integer,
  moving_s integer,
  max_speed_mps numeric,
  started_at timestamptz,
  ended_at timestamptz,
  group_trip_id uuid,
  group_name text
)
language sql
stable
security definer
set search_path = public
as $$
  select r.id, r.vehicle_id, r.destination_name, r.arrived, r.distance_m, r.duration_s, r.moving_s,
         r.max_speed_mps, r.started_at, r.ended_at, r.group_trip_id, g.name
  from rides r
  left join group_trips t on t.id = r.group_trip_id
  left join groups g on g.id = t.group_id
  where r.user_id = auth.uid()
  order by r.started_at desc, r.id
  limit least(greatest(p_limit, 1), 100) offset greatest(p_offset, 0);
$$;

create function get_ride(p_id uuid)
returns table (
  id uuid,
  vehicle_id uuid,
  destination_name text,
  arrived boolean,
  distance_m numeric,
  duration_s integer,
  moving_s integer,
  max_speed_mps numeric,
  started_at timestamptz,
  ended_at timestamptz,
  route_polyline6 text,
  group_trip_id uuid,
  group_name text
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select r.id, r.vehicle_id, r.destination_name, r.arrived, r.distance_m, r.duration_s, r.moving_s,
         r.max_speed_mps, r.started_at, r.ended_at, ST_AsEncodedPolyline(r.route::geometry, 6),
         r.group_trip_id, g.name
  from rides r
  left join group_trips t on t.id = r.group_trip_id
  left join groups g on g.id = t.group_id
  where r.id = p_id and r.user_id = auth.uid();
$$;

-- A group's finished rides, newest first, for its members. Cancelled rides
-- are left out. my_ride_id is the caller's saved ride on that trip, if any.
create function get_group_ride_history(target_group_id uuid, p_limit integer default 20, p_offset integer default 0)
returns table (
  trip_id uuid,
  name text,
  started_at timestamptz,
  ended_at timestamptz,
  planned_distance_m numeric,
  rider_count bigint,
  my_ride_id uuid
)
language sql
stable
security definer
set search_path = public
as $$
  select
    t.id,
    t.name,
    t.started_at,
    t.ended_at,
    t.distance_m,
    (select count(*) from trip_riders tr where tr.trip_id = t.id),
    (select r.id from rides r where r.group_trip_id = t.id and r.user_id = auth.uid() order by r.started_at limit 1)
  from group_trips t
  where t.group_id = target_group_id
    and t.status = 'completed'
    and is_joined_group_member(target_group_id)
  order by t.started_at desc, t.id
  limit least(greatest(p_limit, 1), 100) offset greatest(p_offset, 0);
$$;

-- One finished group ride: the trip, its planned route, and who led it.
create function get_group_ride(target_trip_id uuid)
returns table (
  trip_id uuid,
  group_id uuid,
  group_name text,
  name text,
  leader_username text,
  started_at timestamptz,
  ended_at timestamptz,
  planned_distance_m numeric,
  route_polyline6 text
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select t.id, g.id, g.name, t.name, p.username, t.started_at, t.ended_at, t.distance_m,
         ST_AsEncodedPolyline(t.route::geometry, 6)
  from group_trips t
  join groups g on g.id = t.group_id
  left join profiles p on p.id = t.created_by
  where t.id = target_trip_id
    and t.status = 'completed'
    and is_joined_group_member(t.group_id);
$$;

-- Everyone who rode a finished group ride, leader first, with the stats from
-- their saved ride. The stats are null for a rider whose ride wasn't saved
-- (too short, still waiting to upload, or deleted). Only totals are shared,
-- never another rider's path.
create function get_group_ride_riders(target_trip_id uuid)
returns table (
  user_id uuid,
  username text,
  is_leader boolean,
  left_early boolean,
  distance_m numeric,
  moving_s integer,
  max_speed_mps numeric,
  arrived boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    tr.user_id,
    p.username,
    tr.user_id = t.created_by,
    tr.status = 'left',
    r.distance_m,
    r.moving_s,
    r.max_speed_mps,
    r.arrived
  from trip_riders tr
  join group_trips t on t.id = tr.trip_id
  join profiles p on p.id = tr.user_id
  left join lateral (
    select r.* from rides r
    where r.group_trip_id = tr.trip_id and r.user_id = tr.user_id
    order by r.started_at
    limit 1
  ) r on true
  where tr.trip_id = target_trip_id
    and t.status = 'completed'
    and is_joined_group_member(t.group_id)
  order by tr.user_id = t.created_by desc, r.distance_m desc nulls last, tr.seat;
$$;

revoke execute on function save_completed_ride(uuid, text, numeric, integer, integer, numeric, timestamptz, timestamptz, boolean, text, uuid, uuid) from public, anon;
revoke execute on function get_ride_history(integer, integer) from public, anon;
revoke execute on function get_ride(uuid) from public, anon;
revoke execute on function get_group_ride_history(uuid, integer, integer) from public, anon;
revoke execute on function get_group_ride(uuid) from public, anon;
revoke execute on function get_group_ride_riders(uuid) from public, anon;

grant execute on function save_completed_ride(uuid, text, numeric, integer, integer, numeric, timestamptz, timestamptz, boolean, text, uuid, uuid) to authenticated;
grant execute on function get_ride_history(integer, integer) to authenticated;
grant execute on function get_ride(uuid) to authenticated;
grant execute on function get_group_ride_history(uuid, integer, integer) to authenticated;
grant execute on function get_group_ride(uuid) to authenticated;
grant execute on function get_group_ride_riders(uuid) to authenticated;
