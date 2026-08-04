-- The leader's "Add" no longer joins someone directly — it creates a pending
-- invite the invited user must accept.
create or replace function add_group_member(target_group_id uuid, target_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from groups
    where id = target_group_id and leader_id = auth.uid()
  ) then
    raise exception 'Only the group leader can add members.';
  end if;

  insert into group_members (group_id, user_id, role, status)
  values (target_group_id, target_user_id, 'member', 'pending')
  on conflict (group_id, user_id) do nothing;
end;
$$;

create function accept_group_invite(target_group_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update group_members
  set status = 'joined', joined_at = now()
  where group_id = target_group_id
    and user_id = auth.uid()
    and status = 'pending';

  if not found then
    raise exception 'No pending invite found for this group.';
  end if;
end;
$$;

grant execute on function accept_group_invite(uuid) to authenticated;

create function decline_group_invite(target_group_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from group_members
  where group_id = target_group_id
    and user_id = auth.uid()
    and status = 'pending';

  if not found then
    raise exception 'No pending invite found for this group.';
  end if;
end;
$$;

grant execute on function decline_group_invite(uuid) to authenticated;

-- joined_at doubles as "invited_at" for a still-pending row — same column,
-- reinterpreted, rather than adding a second timestamp column for it.
create function get_pending_invites()
returns table (group_id uuid, group_name text, invited_by text, invited_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
    select g.id, g.name, p.username, gm.joined_at
    from group_members gm
    join groups g on g.id = gm.group_id
    join profiles p on p.id = g.leader_id
    where gm.user_id = auth.uid()
      and gm.status = 'pending'
    order by gm.joined_at desc;
end;
$$;

grant execute on function get_pending_invites() to authenticated;
