-- Quotas for session-billed APIs (Mapbox Search Box bills per session: a run
-- of suggest calls plus one retrieve under the same session token). Each new
-- session counts once against consume_api_quota's per-user and global daily
-- limits; further requests in the same session are free, up to a cap.
create table api_session_usage (
  user_id uuid not null references auth.users (id) on delete cascade,
  api_name text not null,
  session_token text not null,
  started_at timestamptz not null default now(),
  request_count integer not null default 0,
  primary key (user_id, api_name, session_token)
);

alter table api_session_usage enable row level security;
-- No policies: only consume_api_session (service role) reads or writes it.

-- Returns false when the request must not be sent: the session is new and a
-- daily quota is exhausted, or the session already used p_max_requests.
-- A session older than an hour counts as new again, so one token can't be
-- reused indefinitely to dodge the daily quota.
create function consume_api_session(
  p_user_id uuid,
  p_api_name text,
  p_session_token text,
  p_user_daily_limit integer,
  p_global_daily_limit integer,
  p_max_requests integer
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request_count integer;
begin
  update api_session_usage
    set request_count = request_count + 1
    where user_id = p_user_id
      and api_name = p_api_name
      and session_token = p_session_token
      and started_at > now() - interval '1 hour'
    returning request_count into v_request_count;

  if found then
    return v_request_count <= p_max_requests;
  end if;

  -- A rejected session is not recorded, so retrying with its token can't
  -- slip past the quota.
  if not consume_api_quota(p_user_id, p_api_name, p_user_daily_limit, p_global_daily_limit) then
    return false;
  end if;

  insert into api_session_usage (user_id, api_name, session_token, started_at, request_count)
  values (p_user_id, p_api_name, p_session_token, now(), 1)
  on conflict (user_id, api_name, session_token) do update
    set started_at = excluded.started_at, request_count = 1;

  -- Keep the table small: this user's sessions from earlier days are no longer needed.
  delete from api_session_usage
    where user_id = p_user_id and started_at < now() - interval '1 day';

  return true;
end;
$$;

revoke execute on function consume_api_session(uuid, text, text, integer, integer, integer) from public, anon, authenticated;
grant execute on function consume_api_session(uuid, text, text, integer, integer, integer) to service_role;
