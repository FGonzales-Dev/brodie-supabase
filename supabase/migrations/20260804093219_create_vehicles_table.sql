create table vehicles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles (id) on delete cascade,
  type text not null check (type in ('motorcycle', 'bike')),
  name text not null,
  photo_url text,
  created_at timestamptz not null default now()
);

create index vehicles_user_id_idx on vehicles (user_id);

alter table vehicles enable row level security;
