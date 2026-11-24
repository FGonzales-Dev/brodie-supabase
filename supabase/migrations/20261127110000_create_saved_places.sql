-- Places a rider saved (home, the usual meeting spot, a favorite café), so
-- they can pick them as a destination without a place search. Unlike recent
-- places, which stay on the phone, these follow the account.

create table saved_places (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 200),
  address text check (char_length(address) <= 300),
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180),
  created_at timestamptz not null default now()
);

create index saved_places_user_id_idx on saved_places (user_id, created_at);

alter table saved_places enable row level security;

create policy "Riders can view their own saved places"
  on saved_places for select to authenticated
  using (auth.uid() = user_id);

create policy "Riders can save places"
  on saved_places for insert to authenticated
  with check (auth.uid() = user_id);

create policy "Riders can rename their saved places"
  on saved_places for update to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "Riders can delete their saved places"
  on saved_places for delete to authenticated
  using (auth.uid() = user_id);

grant select, insert, update, delete on saved_places to authenticated;

-- A rider can keep up to 50 saved places.
create function limit_saved_places()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select count(*) from saved_places where user_id = new.user_id) >= 50 then
    raise exception 'You can save up to 50 places. Remove one to save another.';
  end if;
  return new;
end;
$$;

create trigger saved_places_limit
  before insert on saved_places
  for each row execute function limit_saved_places();
