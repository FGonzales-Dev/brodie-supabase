-- Solo ride tracking: save a completed ride (route + stats) and page through
-- a user's ride history. `rides` has RLS enabled with no policies (see
-- 20260804093220_create_rides_table.sql), so — same pattern as the group
-- functions — all access goes through these SECURITY DEFINER functions,
-- scoped to auth.uid() internally, rather than adding table-level policies.

create or replace function save_completed_ride(
  p_vehicle_id uuid,
  p_route_coordinates jsonb, -- array of [lng, lat] pairs, in order
  p_distance_m numeric,
  p_duration_s integer,
  p_started_at timestamptz,
  p_ended_at timestamptz
)
returns table (id uuid, distance_m numeric, duration_s integer, started_at timestamptz, ended_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  new_ride_id uuid;
  point_count integer;
  route_geog geography;
  start_pt geography;
  end_pt geography;
begin
  point_count := jsonb_array_length(p_route_coordinates);
  if point_count < 2 then
    raise exception 'A ride route needs at least 2 points.';
  end if;

  route_geog := ST_SetSRID(
    ST_MakeLine(
      array(
        select ST_MakePoint((pt->>0)::double precision, (pt->>1)::double precision)
        from jsonb_array_elements(p_route_coordinates) as pt
      )
    ),
    4326
  )::geography;

  start_pt := ST_SetSRID(
    ST_MakePoint(
      (p_route_coordinates->0->>0)::double precision,
      (p_route_coordinates->0->>1)::double precision
    ),
    4326
  )::geography;

  end_pt := ST_SetSRID(
    ST_MakePoint(
      (p_route_coordinates->(point_count - 1)->>0)::double precision,
      (p_route_coordinates->(point_count - 1)->>1)::double precision
    ),
    4326
  )::geography;

  insert into rides (user_id, vehicle_id, route, start_point, end_point, distance_m, duration_s, started_at, ended_at)
  values (auth.uid(), p_vehicle_id, route_geog, start_pt, end_pt, p_distance_m, p_duration_s, p_started_at, p_ended_at)
  returning rides.id into new_ride_id;

  return query
    select r.id, r.distance_m, r.duration_s, r.started_at, r.ended_at
    from rides r
    where r.id = new_ride_id;
end;
$$;

grant execute on function save_completed_ride(uuid, jsonb, numeric, integer, timestamptz, timestamptz) to authenticated;

create or replace function get_ride_history(p_limit integer default 20, p_offset integer default 0)
returns table (
  id uuid,
  vehicle_id uuid,
  distance_m numeric,
  duration_s integer,
  started_at timestamptz,
  ended_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
    select r.id, r.vehicle_id, r.distance_m, r.duration_s, r.started_at, r.ended_at
    from rides r
    where r.user_id = auth.uid()
    order by r.started_at desc
    limit p_limit offset p_offset;
end;
$$;

grant execute on function get_ride_history(integer, integer) to authenticated;
