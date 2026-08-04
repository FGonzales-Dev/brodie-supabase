create table ride_group_members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references ride_groups (id) on delete cascade,
  user_id uuid not null references profiles (id) on delete cascade,
  role text not null default 'member' check (role in ('leader', 'member')),
  status text not null default 'joined' check (status in ('joined', 'left', 'fell_behind')),
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  unique (group_id, user_id)
);

create index ride_group_members_group_id_idx on ride_group_members (group_id);
create index ride_group_members_user_id_idx on ride_group_members (user_id);

alter table ride_group_members enable row level security;
