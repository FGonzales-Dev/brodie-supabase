-- Getting more out of the one route a group ride requests:
--
-- 1. The turn-by-turn directions that came with the leader's route are kept
--    with the trip, so every rider gets next-turn guidance without a
--    Directions request of their own.
-- 2. The leader can reroute the whole group: one new route, stored on the
--    trip with route_version bumped, which riders pick up instead of each
--    asking for their own.

alter table group_trips
  add column maneuvers jsonb not null default '[]'::jsonb
    check (jsonb_typeof(maneuvers) = 'array' and jsonb_array_length(maneuvers) <= 1000);

comment on column group_trips.maneuvers is
  'Turn instructions in route order: [{instruction, type, modifier, lng, lat}], as from mapbox-directions.';

-- The trip's route, checked: a line of at least 2 points and directions as
-- a JSON array.
create function check_trip_route(route_polyline6 text, route_maneuvers jsonb)
returns geometry
language plpgsql
immutable
set search_path = public, extensions
as $$
declare
  route_geom geometry := ST_LineFromEncodedPolyline(route_polyline6, 6);
begin
  if route_geom is null or ST_NPoints(route_geom) < 2 then
    raise exception 'A ride route needs at least 2 points.';
  end if;
  if jsonb_typeof(coalesce(route_maneuvers, '[]'::jsonb)) <> 'array' then
    raise exception 'Route directions must be a list.';
  end if;
  return route_geom;
end;
$$;

-- plan_group_trip gains route_maneuvers. Its parameters change, so the old
-- version is dropped; callers that don't send directions still work.
drop function plan_group_trip(uuid, double precision, double precision, text, numeric, integer, text);

create function plan_group_trip(
  target_group_id uuid,
  destination_lng double precision,
  destination_lat double precision,
  route_polyline6 text,
  route_distance_m numeric,
  route_duration_s integer,
  trip_name text default null,
  route_maneuvers jsonb default '[]'::jsonb
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
  route_geom := check_trip_route(route_polyline6, route_maneuvers);

  begin
    insert into group_trips (group_id, name, destination, created_by, route, distance_m, duration_s, maneuvers)
    values (
      target_group_id,
      left(nullif(trim(trip_name), ''), 200),
      ST_SetSRID(ST_MakePoint(destination_lng, destination_lat), 4326)::geography,
      auth.uid(),
      route_geom::geography,
      route_distance_m,
      route_duration_s,
      coalesce(route_maneuvers, '[]'::jsonb)
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

-- Leader only, while the ride is on: replaces the group's route (from the
-- leader's position to the same destination) and bumps route_version so
-- every rider's phone switches to it. Returns the new version.
create function reroute_group_trip(
  target_trip_id uuid,
  route_polyline6 text,
  route_distance_m numeric,
  route_duration_s integer,
  route_maneuvers jsonb default '[]'::jsonb
)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  trip group_trips := lock_trip_as_leader(target_trip_id);
  route_geom geometry;
  new_version integer;
begin
  if trip.status <> 'active' then
    raise exception 'Only a ride that has started can be rerouted.';
  end if;
  route_geom := check_trip_route(route_polyline6, route_maneuvers);

  update group_trips
  set route = route_geom::geography,
      distance_m = route_distance_m,
      duration_s = route_duration_s,
      maneuvers = coalesce(route_maneuvers, '[]'::jsonb),
      route_version = route_version + 1
  where id = target_trip_id
  returning route_version into new_version;
  return new_version;
end;
$$;

-- Adds the directions. Return columns change, so drop first.
drop function get_open_group_trip(uuid);

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
  started_at timestamptz,
  maneuvers jsonb
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select t.id, t.group_id, g.leader_id, t.name, ST_X(t.destination::geometry), ST_Y(t.destination::geometry),
         t.status, ST_AsEncodedPolyline(t.route::geometry, 6), t.route_version, t.distance_m, t.duration_s,
         t.created_at, t.started_at, t.maneuvers
  from group_trips t
  join groups g on g.id = t.group_id
  where t.group_id = target_group_id
    and t.status in ('planned', 'active')
    and is_joined_group_member(t.group_id);
$$;

revoke execute on function check_trip_route(text, jsonb) from public, anon, authenticated;
revoke execute on function plan_group_trip(uuid, double precision, double precision, text, numeric, integer, text, jsonb) from public, anon;
revoke execute on function reroute_group_trip(uuid, text, numeric, integer, jsonb) from public, anon;
revoke execute on function get_open_group_trip(uuid) from public, anon;

grant execute on function plan_group_trip(uuid, double precision, double precision, text, numeric, integer, text, jsonb) to authenticated;
grant execute on function reroute_group_trip(uuid, text, numeric, integer, jsonb) to authenticated;
grant execute on function get_open_group_trip(uuid) to authenticated;
