-- Lists the groups the caller currently belongs to, with a member count for
-- the group list screen. Security definer so it can read across all of a
-- user's group_members rows without a broader "read any membership" RLS
-- policy — gated implicitly by filtering on auth.uid() in the query itself.
create function get_my_groups()
returns table (
  id uuid,
  name text,
  invite_code text,
  leader_id uuid,
  created_at timestamptz,
  member_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
    select
      g.id,
      g.name,
      g.invite_code,
      g.leader_id,
      g.created_at,
      (
        select count(*)
        from group_members gm2
        where gm2.group_id = g.id and gm2.status = 'joined'
      ) as member_count
    from groups g
    join group_members gm on gm.group_id = g.id
    where gm.user_id = auth.uid()
      and gm.status = 'joined'
    order by g.created_at desc;
end;
$$;

grant execute on function get_my_groups() to authenticated;
