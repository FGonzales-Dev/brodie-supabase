-- check_global_rate_limit was executable by every signed-in user (and, by
-- Postgres default, PUBLIC), so a client could exhaust the shared limit for
-- everyone or simply never call it. From here on only server code (Edge
-- Functions using the service role) may touch API quotas.
revoke execute on function check_global_rate_limit(text, integer, integer) from public, anon, authenticated;
grant execute on function check_global_rate_limit(text, integer, integer) to service_role;

-- Per-user daily call counts for third-party APIs, so one user can't use up
-- the shared daily allowance.
create table api_user_usage (
  user_id uuid not null references auth.users (id) on delete cascade,
  api_name text not null,
  usage_date date not null,
  call_count integer not null default 0,
  primary key (user_id, api_name, usage_date)
);

alter table api_user_usage enable row level security;
-- No policies: only consume_api_quota (service role) reads or writes it.

-- Counts one call against the user's and the global daily quota (both reset
-- at midnight UTC). Returns false when either is exhausted; the caller must
-- then not make the API request. Rejected calls still count, which is the
-- conservative choice for a quota.
create function consume_api_quota(
  p_user_id uuid,
  p_api_name text,
  p_user_daily_limit integer,
  p_global_daily_limit integer
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_count integer;
begin
  insert into api_user_usage (user_id, api_name, usage_date, call_count)
  values (p_user_id, p_api_name, current_date, 1)
  on conflict (user_id, api_name, usage_date) do update
    set call_count = api_user_usage.call_count + 1
  returning call_count into v_user_count;

  if v_user_count > p_user_daily_limit then
    return false;
  end if;

  return check_global_rate_limit(p_api_name, p_global_daily_limit, 86400);
end;
$$;

revoke execute on function consume_api_quota(uuid, text, integer, integer) from public, anon, authenticated;
grant execute on function consume_api_quota(uuid, text, integer, integer) to service_role;
