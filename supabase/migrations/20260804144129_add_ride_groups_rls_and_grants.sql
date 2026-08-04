create policy "Members can view their ride groups"
  on ride_groups for select
  using (
    leader_id = auth.uid()
    or exists (
      select 1 from ride_group_members
      where ride_group_members.group_id = ride_groups.id
        and ride_group_members.user_id = auth.uid()
    )
  );

grant select on ride_groups to authenticated;

create policy "Members can view fellow group members"
  on ride_group_members for select
  using (
    exists (
      select 1 from ride_group_members m2
      where m2.group_id = ride_group_members.group_id
        and m2.user_id = auth.uid()
    )
  );

grant select on ride_group_members to authenticated;
