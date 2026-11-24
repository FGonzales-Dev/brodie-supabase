-- The leader's phone announces the end of a ride on the trip channel right
-- after complete_group_trip marks the trip completed. The channel only
-- accepted planned and active trips, so Realtime rejected that last message
-- and riders only learned the ride was over at their next trip check (up to
-- 30 seconds later). Riders of a completed trip may now use its channel for a
-- few minutes after it ended, long enough for that announcement.

create or replace function can_use_trip_channel(channel_topic text)
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
      and (
        t.status in ('planned', 'active')
        or (t.status = 'completed' and t.ended_at > now() - interval '5 minutes')
      )
  );
$$;
