create table ride_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  destination geography(point, 4326),
  invite_code text not null unique,
  leader_id uuid not null references profiles (id) on delete cascade,
  status text not null default 'active' check (status in ('active', 'ended')),
  created_at timestamptz not null default now(),
  ended_at timestamptz
);

create index ride_groups_leader_id_idx on ride_groups (leader_id);

alter table ride_groups enable row level security;
