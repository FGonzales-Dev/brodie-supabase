-- Global (app-wide, not per-user) rate limiting for outbound third-party API
-- calls (Mapbox Search Box / Directions). One row per api_name; the window
-- resets in place when it rolls over, so the table never grows unbounded.

create table if not exists api_rate_limits (
  api_name text primary key,
  window_start timestamptz not null,
  call_count integer not null default 0
);

alter table api_rate_limits enable row level security;
-- No policies: this table is only ever touched via the SECURITY DEFINER
-- function below, never read/written directly by client code.

create or replace function check_global_rate_limit(
  p_api_name text,
  p_limit integer,
  p_window_seconds integer default 60
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_window timestamptz := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  v_count integer;
begin
  insert into api_rate_limits (api_name, window_start, call_count)
  values (p_api_name, v_window, 1)
  on conflict (api_name) do update
    set call_count = case
          when api_rate_limits.window_start = v_window then api_rate_limits.call_count + 1
          else 1
        end,
        window_start = v_window
  returning call_count into v_count;

  return v_count <= p_limit;
end;
$$;

grant execute on function check_global_rate_limit(text, integer, integer) to authenticated;
