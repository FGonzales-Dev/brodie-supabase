-- Saving finished rides from the app: the stats the ride summary and
-- history screens show, an app-generated id so a retried upload can't create
-- a duplicate, and routes passed as polyline6 (the format the app already
-- uses for Mapbox routes) instead of a JSON array of points.
--
-- `rides` keeps RLS on with no policies; every read and write goes through
-- the security definer functions below, scoped to auth.uid().

alter table rides
  add column destination_name text check (char_length(destination_name) <= 200),
  add column arrived boolean not null default false,
  add column moving_s integer check (moving_s >= 0),
  add column max_speed_mps numeric check (max_speed_mps >= 0),
  -- Set once group trips record each rider's ride.
  add column group_trip_id uuid references group_trips (id) on delete set null;

create index rides_user_started_idx on rides (user_id, started_at desc);

-- Never called by a released app; replaced by the version below.
drop function save_completed_ride(uuid, jsonb, numeric, integer, timestamptz, timestamptz);

-- Saving the same p_id twice returns the existing ride, so the app can retry
-- an upload whose response was lost. A vehicle that isn't the caller's (e.g.
-- deleted while the ride waited offline) is dropped rather than failing the
-- upload forever.
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
  p_vehicle_id uuid default null
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
    id, user_id, vehicle_id, route, start_point, end_point, distance_m, duration_s, moving_s,
    max_speed_mps, started_at, ended_at, arrived, destination_name
  )
  values (
    p_id,
    auth.uid(),
    (select v.id from vehicles v where v.id = p_vehicle_id and v.user_id = auth.uid()),
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

-- Return columns change, so the old function must be dropped first.
drop function get_ride_history(integer, integer);

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
  ended_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select r.id, r.vehicle_id, r.destination_name, r.arrived, r.distance_m, r.duration_s, r.moving_s,
         r.max_speed_mps, r.started_at, r.ended_at
  from rides r
  where r.user_id = auth.uid()
  order by r.started_at desc, r.id
  limit least(greatest(p_limit, 1), 100) offset greatest(p_offset, 0);
$$;

-- One ride with its route, for the ride detail screen.
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
  route_polyline6 text
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select r.id, r.vehicle_id, r.destination_name, r.arrived, r.distance_m, r.duration_s, r.moving_s,
         r.max_speed_mps, r.started_at, r.ended_at, ST_AsEncodedPolyline(r.route::geometry, 6)
  from rides r
  where r.id = p_id and r.user_id = auth.uid();
$$;

-- Null clears the vehicle. A vehicle that isn't the caller's is refused.
create function set_ride_vehicle(p_id uuid, p_vehicle_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_vehicle_id is not null
     and not exists (select 1 from vehicles v where v.id = p_vehicle_id and v.user_id = auth.uid()) then
    raise exception 'That vehicle is no longer in your garage.';
  end if;

  update rides set vehicle_id = p_vehicle_id where id = p_id and user_id = auth.uid();
end;
$$;

-- Deleting a ride that doesn't exist is not an error: the app may delete a
-- ride whose upload never reached the server.
create function delete_ride(p_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  delete from rides where id = p_id and user_id = auth.uid();
$$;

revoke execute on function save_completed_ride(uuid, text, numeric, integer, integer, numeric, timestamptz, timestamptz, boolean, text, uuid) from public, anon;
revoke execute on function get_ride_history(integer, integer) from public, anon;
revoke execute on function get_ride(uuid) from public, anon;
revoke execute on function set_ride_vehicle(uuid, uuid) from public, anon;
revoke execute on function delete_ride(uuid) from public, anon;

grant execute on function save_completed_ride(uuid, text, numeric, integer, integer, numeric, timestamptz, timestamptz, boolean, text, uuid) to authenticated;
grant execute on function get_ride_history(integer, integer) to authenticated;
grant execute on function get_ride(uuid) to authenticated;
grant execute on function set_ride_vehicle(uuid, uuid) to authenticated;
grant execute on function delete_ride(uuid) to authenticated;
