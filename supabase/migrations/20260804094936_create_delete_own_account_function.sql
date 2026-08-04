-- Deleting an auth.users row requires elevated privileges the authenticated
-- role doesn't have directly, so this runs as security definer. Every other
-- table (profiles, vehicles, emergency_contacts, rides, ride_groups,
-- ride_group_members, group_ride_location_snapshots) cascades from
-- profiles.id -> auth.users.id, so one delete here cleans up everything.
create function delete_own_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from auth.users where id = auth.uid();
end;
$$;

grant execute on function delete_own_account() to authenticated;
