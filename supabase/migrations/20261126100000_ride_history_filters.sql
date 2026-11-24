-- Filtering and sorting the rider's history. It's paged, so filters run
-- here rather than on the phone, which only ever has one page.
--
-- Every new parameter has a default, so callers that only pass p_limit and
-- p_offset get the same newest-first list as before.

drop function get_ride_history(integer, integer);

-- Shared by get_ride_history and get_ride_history_totals so the list and
-- its totals always agree on what matches. p_kind is 'all', 'solo' or
-- 'group'; p_from is inclusive, p_to exclusive; null means no limit.
create function ride_matches_filter(
  r rides,
  p_kind text,
  p_from timestamptz,
  p_to timestamptz,
  p_vehicle_id uuid
)
returns boolean
language sql
immutable
as $$
  select (p_kind = 'all'
          or (p_kind = 'solo' and r.group_trip_id is null)
          or (p_kind = 'group' and r.group_trip_id is not null))
     and (p_from is null or r.started_at >= p_from)
     and (p_to is null or r.started_at < p_to)
     and (p_vehicle_id is null or r.vehicle_id = p_vehicle_id);
$$;

create function check_ride_filter(p_kind text, p_sort text)
returns void
language plpgsql
immutable
as $$
begin
  if p_kind not in ('all', 'solo', 'group') then
    raise exception 'Unknown ride kind: %', p_kind;
  end if;
  if p_sort not in ('newest', 'oldest', 'distance', 'moving_time') then
    raise exception 'Unknown sort: %', p_sort;
  end if;
end;
$$;

create function get_ride_history(
  p_limit integer default 20,
  p_offset integer default 0,
  p_kind text default 'all',
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_vehicle_id uuid default null,
  p_sort text default 'newest'
)
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
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform check_ride_filter(p_kind, p_sort);
  return query
    select r.id, r.vehicle_id, r.destination_name, r.arrived, r.distance_m, r.duration_s, r.moving_s,
           r.max_speed_mps, r.started_at, r.ended_at, r.group_trip_id, g.name
    from rides r
    left join group_trips t on t.id = r.group_trip_id
    left join groups g on g.id = t.group_id
    where r.user_id = auth.uid()
      and ride_matches_filter(r, p_kind, p_from, p_to, p_vehicle_id)
    order by
      case when p_sort = 'distance' then r.distance_m end desc nulls last,
      case when p_sort = 'moving_time' then coalesce(r.moving_s, r.duration_s) end desc nulls last,
      case when p_sort = 'oldest' then r.started_at end asc,
      r.started_at desc,
      r.id
    limit least(greatest(p_limit, 1), 100) offset greatest(p_offset, 0);
end;
$$;

-- What the filtered list adds up to, for the line above it.
create function get_ride_history_totals(
  p_kind text default 'all',
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_vehicle_id uuid default null
)
returns table (ride_count bigint, distance_m numeric, moving_s bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform check_ride_filter(p_kind, 'newest');
  return query
    select count(*), coalesce(sum(r.distance_m), 0), coalesce(sum(coalesce(r.moving_s, r.duration_s)), 0)::bigint
    from rides r
    where r.user_id = auth.uid()
      and ride_matches_filter(r, p_kind, p_from, p_to, p_vehicle_id);
end;
$$;

create index rides_user_distance_idx on rides (user_id, distance_m desc);

revoke execute on function ride_matches_filter(rides, text, timestamptz, timestamptz, uuid) from public, anon;
revoke execute on function check_ride_filter(text, text) from public, anon;
revoke execute on function get_ride_history(integer, integer, text, timestamptz, timestamptz, uuid, text) from public, anon;
revoke execute on function get_ride_history_totals(text, timestamptz, timestamptz, uuid) from public, anon;

grant execute on function ride_matches_filter(rides, text, timestamptz, timestamptz, uuid) to authenticated;
grant execute on function check_ride_filter(text, text) to authenticated;
grant execute on function get_ride_history(integer, integer, text, timestamptz, timestamptz, uuid, text) to authenticated;
grant execute on function get_ride_history_totals(text, timestamptz, timestamptz, uuid) to authenticated;
