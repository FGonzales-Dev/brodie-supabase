-- ride_groups conflated two different things: a persistent crew of riders,
-- and a single ride event. Splitting them apart: "groups" is the persistent
-- crew; a new "group_trips" table (next migration) holds the per-trip
-- destination/status, since a group can go on many trips over time.
alter table ride_groups rename to groups;
alter table ride_group_members rename to group_members;

-- Renames automatically carry over to FKs, indexes, RLS policies, and grants
-- (Postgres tracks those by OID, not name) — just tidying policy names for
-- readability, not required for them to keep working.
alter policy "Members can view their ride groups" on groups
  rename to "Members can view their groups";
alter policy "Members can view fellow group members" on group_members
  rename to "Members can view fellow crew members";

-- destination/status belonged to a single ride, not the persistent crew.
alter table groups drop column destination;
alter table groups drop column status;
alter table groups drop column ended_at;

alter index ride_groups_leader_id_idx rename to groups_leader_id_idx;
alter index ride_group_members_group_id_idx rename to group_members_group_id_idx;
alter index ride_group_members_user_id_idx rename to group_members_user_id_idx;
