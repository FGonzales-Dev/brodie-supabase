-- Profile pictures and vehicle photos in Supabase Storage.
--
-- Files live at "<user id>/<random id>.<ext>" in two public buckets, so the
-- app can show them by URL without signing each one. The random file name
-- is what keeps a photo private: its URL can't be guessed. Riders can only
-- write inside their own folder.
--
-- The database stores the file's path in the bucket, not a URL, so the
-- project's domain can change without rewriting rows. The columns are
-- renamed to say so.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('avatars', 'avatars', true, 5242880, array['image/jpeg', 'image/png', 'image/webp']),
  ('vehicle-photos', 'vehicle-photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy "Riders can read their own photo files"
  on storage.objects for select
  to authenticated
  using (bucket_id in ('avatars', 'vehicle-photos') and (storage.foldername(name))[1] = auth.uid()::text);

create policy "Riders can upload photos to their own folder"
  on storage.objects for insert
  to authenticated
  with check (bucket_id in ('avatars', 'vehicle-photos') and (storage.foldername(name))[1] = auth.uid()::text);

create policy "Riders can replace their own photos"
  on storage.objects for update
  to authenticated
  using (bucket_id in ('avatars', 'vehicle-photos') and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id in ('avatars', 'vehicle-photos') and (storage.foldername(name))[1] = auth.uid()::text);

create policy "Riders can delete their own photos"
  on storage.objects for delete
  to authenticated
  using (bucket_id in ('avatars', 'vehicle-photos') and (storage.foldername(name))[1] = auth.uid()::text);

-- Nothing has written these columns yet.
alter table profiles rename column avatar_url to avatar_path;
alter table vehicles rename column photo_url to photo_path;

-- A row can only point at a file in its owner's folder. Riders update these
-- columns directly (through the existing update policies on their own rows).
alter table profiles
  add constraint profiles_avatar_path_own_folder
  check (avatar_path is null or avatar_path like id::text || '/%');
alter table vehicles
  add constraint vehicles_photo_path_own_folder
  check (photo_path is null or photo_path like user_id::text || '/%');

-- The functions that returned avatar_url now return avatar_path. Their
-- return columns change, so each is dropped first.
drop function search_users(text);
drop function get_active_group_members(uuid);
drop function get_trip_riders(uuid);

-- Riders can be found by exact email or by username prefix (see the
-- search_users_by_email migration for why email matching is exact).
create function search_users(search_query text)
returns table (id uuid, username text, avatar_path text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_query text := trim(search_query);
begin
  if length(v_query) < 2 then
    return;
  end if;

  if position('@' in v_query) > 0 then
    return query
      select p.id, p.username, p.avatar_path
      from profiles p
      join auth.users u on u.id = p.id
      where p.username is not null
        and lower(u.email) = lower(v_query)
        and p.id <> auth.uid();
    return;
  end if;

  return query
    select p.id, p.username, p.avatar_path
    from profiles p
    where p.username is not null
      and p.username ilike v_query || '%'
      and p.id <> auth.uid()
    order by p.username
    limit 20;
end;
$$;

create function get_active_group_members(target_group_id uuid)
returns table (user_id uuid, username text, avatar_path text, role text, status text, joined_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from group_members gm
    where gm.group_id = target_group_id and gm.user_id = auth.uid()
  ) then
    raise exception 'You are not a member of this group.';
  end if;

  return query
    select m.user_id, p.username, p.avatar_path, m.role, m.status, m.joined_at
    from group_members m
    join profiles p on p.id = m.user_id
    where m.group_id = target_group_id
      and m.status = 'joined'
    order by m.joined_at;
end;
$$;

create function get_trip_riders(target_trip_id uuid)
returns table (user_id uuid, username text, avatar_path text, seat smallint, is_leader boolean, joined_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select r.user_id, p.username, p.avatar_path, r.seat, r.user_id = g.leader_id, r.joined_at
  from trip_riders r
  join group_trips t on t.id = r.trip_id
  join groups g on g.id = t.group_id
  join profiles p on p.id = r.user_id
  where r.trip_id = target_trip_id
    and r.status = 'joined'
    and is_joined_group_member(t.group_id)
  order by r.seat;
$$;

-- These were callable without signing in (new functions are executable by
-- everyone by default); now only signed-in riders can call them.
revoke execute on function search_users(text) from public, anon;
revoke execute on function get_active_group_members(uuid) from public, anon;
revoke execute on function get_trip_riders(uuid) from public, anon;

grant execute on function search_users(text) to authenticated;
grant execute on function get_active_group_members(uuid) to authenticated;
grant execute on function get_trip_riders(uuid) to authenticated;
