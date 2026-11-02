-- Daily API limits move from constants in the Edge Functions to this table,
-- the single source the functions count against and the app's usage screen
-- reports. Change a cap with an UPDATE; no function redeploy needed.
create table api_quotas (
  api_name text primary key,
  label text not null,
  user_daily_limit integer not null check (user_daily_limit >= 0),
  global_daily_limit integer not null check (global_daily_limit >= 0)
);

alter table api_quotas enable row level security;
-- No policies: read through the functions below.

insert into api_quotas (api_name, label, user_daily_limit, global_daily_limit) values
  -- Mapbox Directions: ~100k free requests/month; 3,000/day stays under it.
  ('mapbox_directions', 'Route previews', 40, 3000),
  -- Mapbox Search Box, counted per session: the free tier is 500 or 2,500
  -- sessions/month depending on the account; 16/day stays under 500.
  ('mapbox_search', 'Place searches', 30, 16);

-- Overloads that take their limits from api_quotas. An API without a row is
-- refused, so a typo can't mean "unlimited".
create function consume_api_quota(p_user_id uuid, p_api_name text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_quota api_quotas;
begin
  select * into v_quota from api_quotas where api_name = p_api_name;
  if not found then
    return false;
  end if;
  return consume_api_quota(p_user_id, p_api_name, v_quota.user_daily_limit, v_quota.global_daily_limit);
end;
$$;

create function consume_api_session(p_user_id uuid, p_api_name text, p_session_token text, p_max_requests integer)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_quota api_quotas;
begin
  select * into v_quota from api_quotas where api_name = p_api_name;
  if not found then
    return false;
  end if;
  return consume_api_session(
    p_user_id, p_api_name, p_session_token, v_quota.user_daily_limit, v_quota.global_daily_limit, p_max_requests
  );
end;
$$;

revoke execute on function consume_api_quota(uuid, text) from public, anon, authenticated;
revoke execute on function consume_api_session(uuid, text, text, integer) from public, anon, authenticated;
grant execute on function consume_api_quota(uuid, text) to service_role;
grant execute on function consume_api_session(uuid, text, text, integer) to service_role;

-- Today's usage for the signed-in rider, for the app's usage screen. Counts
-- can exceed the limit because refused calls are counted too; the app shows
-- what's left, never below zero. Days run on UTC, like check_global_rate_limit.
create function get_my_api_usage()
returns table (
  api_name text,
  label text,
  used_today integer,
  user_daily_limit integer,
  all_riders_used_today integer,
  global_daily_limit integer,
  resets_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  with today as (
    select to_timestamp(floor(extract(epoch from now()) / 86400) * 86400) as window_start
  )
  select
    q.api_name,
    q.label,
    coalesce((
      select u.call_count from api_user_usage u
      where u.user_id = auth.uid() and u.api_name = q.api_name and u.usage_date = current_date
    ), 0),
    q.user_daily_limit,
    coalesce((
      select r.call_count from api_rate_limits r, today
      where r.api_name = q.api_name and r.window_start = today.window_start
    ), 0),
    q.global_daily_limit,
    (select window_start + interval '1 day' from today)
  from api_quotas q
  order by q.label;
$$;

revoke execute on function get_my_api_usage() from public, anon;
grant execute on function get_my_api_usage() to authenticated;
