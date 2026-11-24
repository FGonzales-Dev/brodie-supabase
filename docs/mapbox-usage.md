# Mapbox tokens and usage

Brodie uses three Mapbox products. Only two are billed per use, and both go
through this project's Edge Functions:

| Product | Billed | Called from | Limit |
|---|---|---|---|
| Maps SDK (the map itself) | per monthly active user | the app, with the **app token** | none needed |
| Directions | per request | `mapbox-directions`, with the **server token** | `api_quotas` row `mapbox_directions` |
| Search Box | per search session | `mapbox-search`, with the **server token** | `api_quotas` row `mapbox_search` |

## Two tokens

Use separate tokens so each one's usage shows up on its own in the Mapbox
account's statistics, and so the server one can be rotated without an app
update.

1. **App token** (`brodie-app`, public, starts with `pk.`)
   - Scopes: only the default public ones (styles, tiles, fonts). Give it no
     secret scopes.
   - Goes in `brodie-mobile/.env` as `MAPBOX_ACCESS_TOKEN`, then
     `dart run build_runner build`. It's compiled into the app, so treat it as
     visible to anyone with the app.
   - Mobile apps can't use Mapbox's URL restrictions; keeping it to map
     drawing is the protection.
2. **Server token** (`brodie-server`, public scopes are enough)
   - Used only by the Edge Functions for Directions and Search. Never put it in
     the app.
   - Set it with `supabase secrets set MAPBOX_SECRET_TOKEN=<token>`; locally it
     goes in `supabase/functions/.env` (see `.env.example`).
   - To rotate: create a new token, set the secret, then delete the old token.

## What the app does to keep usage down

- Searches wait for 3 typed letters and a pause, reuse suggestions already
  fetched in the same search, and group suggest and pick calls into one
  billed session.
- Saved places, recent places and **Choose on map** need no search at all.
- A recent route preview to the same place, from about the same spot, is
  reused for 30 minutes (on the phone only).
- Reroutes happen only when a rider (solo) or the leader (group) taps for
  one; everyone else gets "Off route" guidance worked out on the phone.
- A group ride requests its route once: riders reuse the leader's route and
  its turn directions, and a group reroute is one request for everyone.
- Small route previews (lobby, ride detail, summary) are drawn as an outline;
  the map loads only when someone taps **Show on map**.

## Seeing where usage goes

`get_api_usage_by_purpose(days)` (also on the app's Usage screen) splits the
billed calls by purpose: solo previews, reroutes, group plans, and solo or
group destination searches. Mapbox's own statistics page shows the totals per
token.

## Changing a daily limit

Limits live in the `api_quotas` table, so changing one needs no function
redeploy. Do it as a migration, like any schema change:

```sql
-- e.g. allow 50 search sessions a day across all riders
update api_quotas set global_daily_limit = 50 where api_name = 'mapbox_search';
```

Size limits against the free allowance on the Mapbox plan in use (check its
pricing page; free tiers change), divided by about 30 days.
