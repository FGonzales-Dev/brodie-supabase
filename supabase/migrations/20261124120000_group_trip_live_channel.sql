-- Live group rides: each open trip has a private Realtime channel,
-- "trip:<trip id>", that carries riders' positions (broadcast) and who is
-- online (presence). Only riders who joined the trip may use it. Positions
-- are never written to a table; they only pass through the channel.

-- Whether the caller is a joined rider on the open trip behind a channel
-- topic. Compares text, so a topic that isn't "trip:<uuid>" is simply false
-- rather than a cast error.
create function can_use_trip_channel(channel_topic text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from trip_riders r
    join group_trips t on t.id = r.trip_id
    where channel_topic = 'trip:' || r.trip_id::text
      and r.user_id = auth.uid()
      and r.status = 'joined'
      and t.status in ('planned', 'active')
  );
$$;

revoke execute on function can_use_trip_channel(text) from public, anon;
grant execute on function can_use_trip_channel(text) to authenticated;

-- Realtime checks these when a client joins a private channel: select to
-- receive, insert to send.
create policy "Trip riders can receive on their trip channel"
  on realtime.messages for select
  to authenticated
  using (
    realtime.messages.extension in ('broadcast', 'presence')
    and can_use_trip_channel((select realtime.topic()))
  );

create policy "Trip riders can send on their trip channel"
  on realtime.messages for insert
  to authenticated
  with check (
    realtime.messages.extension in ('broadcast', 'presence')
    and can_use_trip_channel((select realtime.topic()))
  );

-- Leader only: the ride is over and everyone arrived (or the leader called
-- it). Cancelling is for a ride that shouldn't count; see cancel_group_trip.
create function complete_group_trip(target_trip_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  trip group_trips := lock_trip_as_leader(target_trip_id);
begin
  if trip.status <> 'active' then
    raise exception 'Only a ride that has started can be ended.';
  end if;
  update group_trips set status = 'completed', ended_at = now() where id = target_trip_id;
end;
$$;

revoke execute on function complete_group_trip(uuid) from public, anon;
grant execute on function complete_group_trip(uuid) to authenticated;
