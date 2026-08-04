create table rides (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles (id) on delete cascade,
  vehicle_id uuid references vehicles (id) on delete set null,
  route geography(linestring, 4326),
  start_point geography(point, 4326),
  end_point geography(point, 4326),
  distance_m numeric,
  duration_s integer,
  started_at timestamptz not null,
  ended_at timestamptz,
  created_at timestamptz not null default now()
);

create index rides_user_id_idx on rides (user_id);
create index rides_route_idx on rides using gist (route);

alter table rides enable row level security;
