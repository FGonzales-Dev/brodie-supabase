create table group_ride_location_snapshots (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references ride_groups (id) on delete cascade,
  user_id uuid not null references profiles (id) on delete cascade,
  location geography(point, 4326) not null,
  recorded_at timestamptz not null default now()
);

create index group_ride_location_snapshots_group_id_idx on group_ride_location_snapshots (group_id);
create index group_ride_location_snapshots_location_idx on group_ride_location_snapshots using gist (location);

alter table group_ride_location_snapshots enable row level security;
