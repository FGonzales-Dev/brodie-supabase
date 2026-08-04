-- Enabling RLS and adding policies is not enough on its own: Postgres still
-- requires the underlying table-level GRANT for a role before its RLS
-- policies are even consulted. The Supabase dashboard does this grant
-- silently when you create a table through the UI; local/CLI migrations
-- must do it explicitly.
grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.vehicles to authenticated;
grant select, insert, update, delete on public.emergency_contacts to authenticated;
