create table group_trips (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references groups (id) on delete cascade,
  name text,
  destination geography(point, 4326) not null,
  status text not null default 'planned' check (status in ('planned', 'active', 'completed', 'cancelled')),
  created_by uuid not null references profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  ended_at timestamptz
);

create index group_trips_group_id_idx on group_trips (group_id);

alter table group_trips enable row level security;

create policy "Members can view their group's trips"
  on group_trips for select
  using (
    exists (
      select 1 from group_members
      where group_members.group_id = group_trips.group_id
        and group_members.user_id = auth.uid()
    )
  );

grant select on group_trips to authenticated;

-- Live location tracking belongs to a specific trip, not the persistent
-- crew, so this is keyed to group_trips rather than groups. No app code
-- reads/writes this table yet (Realtime Broadcast handles live location;
-- this is the "ride history snapshots" landing table from section 3), so
-- it's recreated fresh rather than migrated in place.
drop table if exists group_ride_location_snapshots;

create table trip_location_snapshots (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references group_trips (id) on delete cascade,
  user_id uuid not null references profiles (id) on delete cascade,
  location geography(point, 4326) not null,
  recorded_at timestamptz not null default now()
);

create index trip_location_snapshots_trip_id_idx on trip_location_snapshots (trip_id);
create index trip_location_snapshots_location_idx on trip_location_snapshots using gist (location);

alter table trip_location_snapshots enable row level security;
