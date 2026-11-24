-- Why the billed Mapbox calls happen: each day's route requests and search
-- sessions, split by what the rider was doing. This is to decide where to
-- cut usage from real numbers. Totals across all riders only: no user ids.
--
-- Recorded by the Edge Functions after a call passes the quota, so it counts
-- what Mapbox bills: every route request, and each search session once.

create table api_usage_by_purpose (
  usage_date date not null default current_date,
  api_name text not null,
  purpose text not null check (purpose in (
    'ride_preview', 'reroute', 'group_plan',      -- mapbox_directions
    'ride_destination', 'group_destination',     -- mapbox_search
    'unknown'                                     -- apps that don't say why
  )),
  call_count integer not null default 0,
  primary key (usage_date, api_name, purpose)
);

alter table api_usage_by_purpose enable row level security;
-- No policies: written and read through the functions below.

-- Counts one billed call. For a session-billed API (search), pass the
-- session token: only the session's first request counts.
create function record_api_purpose(
  p_user_id uuid,
  p_api_name text,
  p_purpose text,
  p_session_token text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_purpose text := case
    when p_purpose in ('ride_preview', 'reroute', 'group_plan', 'ride_destination', 'group_destination')
      then p_purpose
    else 'unknown'
  end;
begin
  if p_session_token is not null and not exists (
    select 1 from api_session_usage s
    where s.user_id = p_user_id
      and s.api_name = p_api_name
      and s.session_token = p_session_token
      and s.request_count = 1
  ) then
    return;
  end if;

  insert into api_usage_by_purpose (api_name, purpose, call_count)
  values (p_api_name, v_purpose, 1)
  on conflict (usage_date, api_name, purpose) do update
    set call_count = api_usage_by_purpose.call_count + 1;
end;
$$;

revoke execute on function record_api_purpose(uuid, text, text, text) from public, anon, authenticated;
grant execute on function record_api_purpose(uuid, text, text, text) to service_role;

-- The last p_days days (today included), all riders, for the Usage screen.
create function get_api_usage_by_purpose(p_days integer default 7)
returns table (api_name text, purpose text, call_count bigint)
language sql
stable
security definer
set search_path = public
as $$
  select u.api_name, u.purpose, sum(u.call_count)
  from api_usage_by_purpose u
  where u.usage_date > current_date - least(greatest(p_days, 1), 90)
  group by u.api_name, u.purpose
  order by u.api_name, sum(u.call_count) desc;
$$;

revoke execute on function get_api_usage_by_purpose(integer) from public, anon;
grant execute on function get_api_usage_by_purpose(integer) to authenticated;
