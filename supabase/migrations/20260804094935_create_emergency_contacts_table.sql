create table emergency_contacts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles (id) on delete cascade,
  name text not null,
  phone text not null,
  relationship text,
  created_at timestamptz not null default now()
);

create index emergency_contacts_user_id_idx on emergency_contacts (user_id);

alter table emergency_contacts enable row level security;

create policy "Users can view their own emergency contacts"
  on emergency_contacts for select
  using (auth.uid() = user_id);

create policy "Users can insert their own emergency contacts"
  on emergency_contacts for insert
  with check (auth.uid() = user_id);

create policy "Users can update their own emergency contacts"
  on emergency_contacts for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "Users can delete their own emergency contacts"
  on emergency_contacts for delete
  using (auth.uid() = user_id);
