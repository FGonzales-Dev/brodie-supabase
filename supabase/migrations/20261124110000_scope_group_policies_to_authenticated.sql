-- The group read policies applied to every role, so a signed-out (anon)
-- request evaluated is_joined_group_member, which anon may not execute, and
-- got "permission denied" instead of no rows. Membership only means
-- anything for signed-in users, so the policies now apply to them alone.

alter policy "Members can view fellow crew members" on group_members to authenticated;
alter policy "Members can view their groups" on groups to authenticated;
alter policy "Members can view their group's trips" on group_trips to authenticated;
