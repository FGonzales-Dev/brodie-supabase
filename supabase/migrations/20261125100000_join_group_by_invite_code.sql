-- Joining a group from its invite code or link (https://<site>/join/<code>).
-- Anyone signed in with the code can join straight away; the leader can
-- reset the code so old links stop working.

-- Wrong codes per rider per day. Codes are 6 hex characters, so without a
-- limit a script could walk through them and join strangers' groups.
create table invite_code_misses (
  user_id uuid not null references profiles (id) on delete cascade,
  miss_date date not null default current_date,
  misses integer not null default 0,
  primary key (user_id, miss_date)
);

alter table invite_code_misses enable row level security;
-- No policies: written only by the functions below.

-- How a typed or linked code is compared: case, spaces and dashes ignored.
create function normalize_invite_code(raw_code text)
returns text
language sql
immutable
as $$
  select upper(regexp_replace(coalesce(raw_code, ''), '[\s-]', '', 'g'));
$$;

-- The group behind a code, after the caller's daily wrong-code limit.
-- Counts a miss when nothing matches.
create function find_group_by_invite_code(raw_code text)
returns groups
language plpgsql
security definer
set search_path = public
as $$
declare
  max_misses_per_day constant integer := 20;
  code text := normalize_invite_code(raw_code);
  found_group groups;
  misses_today integer;
begin
  if auth.uid() is null then
    raise exception 'Sign in to join a group.';
  end if;

  select m.misses into misses_today
  from invite_code_misses m
  where m.user_id = auth.uid() and m.miss_date = current_date;
  if coalesce(misses_today, 0) >= max_misses_per_day then
    raise exception 'Too many wrong invite codes today. Try again tomorrow.';
  end if;

  select g.* into found_group from groups g where g.invite_code = code;
  if not found then
    insert into invite_code_misses (user_id, misses) values (auth.uid(), 1)
    on conflict (user_id, miss_date) do update set misses = invite_code_misses.misses + 1;
    return null;
  end if;
  return found_group;
end;
$$;

-- What the join screen shows before the rider taps Join. Empty when the
-- code matches no group. my_status is the caller's membership, if any
-- ('pending', 'joined' or 'left').
create function get_group_invite_preview(invite_code text)
returns table (
  group_id uuid,
  name text,
  leader_username text,
  member_count bigint,
  my_status text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  target groups := find_group_by_invite_code(invite_code);
begin
  if target.id is null then
    return;
  end if;
  return query
    select
      target.id,
      target.name,
      p.username,
      (select count(*) from group_members gm where gm.group_id = target.id and gm.status = 'joined'),
      (select gm.status from group_members gm where gm.group_id = target.id and gm.user_id = auth.uid())
    from profiles p
    where p.id = target.leader_id;
end;
$$;

-- Joins the group behind the code and returns its id, or null when the code
-- matches no group. (Null rather than an error: an error would roll back
-- the wrong-code count.) Also accepts a pending invite and re-joins after
-- leaving; joining twice is harmless.
create function join_group_by_invite_code(invite_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  target groups := find_group_by_invite_code(invite_code);
begin
  if target.id is null then
    return null;
  end if;

  insert into group_members (group_id, user_id, role, status)
  values (target.id, auth.uid(), 'member', 'joined')
  on conflict (group_id, user_id) do update
    set status = 'joined', joined_at = now(), left_at = null
    where group_members.status <> 'joined';
  return target.id;
end;
$$;

-- Leader only: a new code, so links and codes already shared stop working.
-- Members who already joined stay in the group.
create function reset_group_invite_code(target_group_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  new_code text;
begin
  if not exists (select 1 from groups g where g.id = target_group_id and g.leader_id = auth.uid()) then
    raise exception 'Only the group leader can reset the invite code.';
  end if;

  loop
    new_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    begin
      update groups set invite_code = new_code where id = target_group_id;
      return new_code;
    exception
      when unique_violation then
        -- Another group has this code; draw again.
    end;
  end loop;
end;
$$;

revoke execute on function find_group_by_invite_code(text) from public, anon, authenticated;
revoke execute on function get_group_invite_preview(text) from public, anon;
revoke execute on function join_group_by_invite_code(text) from public, anon;
revoke execute on function reset_group_invite_code(uuid) from public, anon;

grant execute on function get_group_invite_preview(text) to authenticated;
grant execute on function join_group_by_invite_code(text) to authenticated;
grant execute on function reset_group_invite_code(uuid) to authenticated;
