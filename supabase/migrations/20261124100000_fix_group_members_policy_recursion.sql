-- The select policy on group_members looked itself up to decide whether
-- the caller belongs to the group, so Postgres hit infinite recursion on any
-- read of group_members, or of groups / group_trips whose policies query it.
--
-- Membership is now checked by is_joined_group_member (security definer, from
-- the trip lobby migration), which reads group_members without going through
-- RLS. Only joined members get direct read access: pending invitees and riders
-- who left no longer see the roster. The app reads groups through RPCs, which
-- bypass these policies, so nothing it does changes.

drop policy "Members can view fellow crew members" on group_members;
create policy "Members can view fellow crew members"
  on group_members for select
  using (user_id = auth.uid() or is_joined_group_member(group_id));

drop policy "Members can view their groups" on groups;
create policy "Members can view their groups"
  on groups for select
  using (leader_id = auth.uid() or is_joined_group_member(id));

drop policy "Members can view their group's trips" on group_trips;
create policy "Members can view their group's trips"
  on group_trips for select
  using (is_joined_group_member(group_id));
