-- Creates the group and adds the creator as leader, atomically. Runs as
-- security definer so it can insert into ride_groups/ride_group_members
-- without needing broad direct-insert RLS policies on either table.
create function create_ride_group(
  group_name text,
  destination_lng double precision,
  destination_lat double precision
)
returns table (id uuid, name text, invite_code text, leader_id uuid, status text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  new_group_id uuid;
  generated_code text;
  attempt int := 0;
begin
  loop
    generated_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    begin
      insert into ride_groups (name, destination, invite_code, leader_id, status)
      values (
        group_name,
        ST_SetSRID(ST_MakePoint(destination_lng, destination_lat), 4326)::geography,
        generated_code,
        auth.uid(),
        'active'
      )
      returning ride_groups.id into new_group_id;
      exit;
    exception
      when unique_violation then
        attempt := attempt + 1;
        if attempt >= 5 then
          raise exception 'Could not generate a unique invite code, please try again.';
        end if;
    end;
  end loop;

  insert into ride_group_members (group_id, user_id, role, status)
  values (new_group_id, auth.uid(), 'leader', 'joined');

  return query
    select rg.id, rg.name, rg.invite_code, rg.leader_id, rg.status, rg.created_at
    from ride_groups rg
    where rg.id = new_group_id;
end;
$$;

grant execute on function create_ride_group(text, double precision, double precision) to authenticated;

-- Leader-only: adds a searched user directly as a joined member, no separate
-- accept/decline step (matches how the invite-code path already works).
create function add_group_member(target_group_id uuid, target_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from ride_groups
    where id = target_group_id and leader_id = auth.uid()
  ) then
    raise exception 'Only the group leader can add members.';
  end if;

  insert into ride_group_members (group_id, user_id, role, status)
  values (target_group_id, target_user_id, 'member', 'joined')
  on conflict (group_id, user_id) do nothing;
end;
$$;

grant execute on function add_group_member(uuid, uuid) to authenticated;

-- Joins membership with profiles for the member list UI (username, avatar),
-- which requires bypassing the restrictive "read your own profile only" RLS
-- policy — hence security definer, gated by a caller-is-a-member check.
create function get_active_group_members(target_group_id uuid)
returns table (user_id uuid, username text, avatar_url text, role text, status text, joined_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from ride_group_members
    where group_id = target_group_id and user_id = auth.uid()
  ) then
    raise exception 'You are not a member of this group.';
  end if;

  return query
    select m.user_id, p.username, p.avatar_url, m.role, m.status, m.joined_at
    from ride_group_members m
    join profiles p on p.id = m.user_id
    where m.group_id = target_group_id
      and m.status = 'joined'
    order by m.joined_at;
end;
$$;

grant execute on function get_active_group_members(uuid) to authenticated;
