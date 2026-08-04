# Plan: Local → Production Supabase Auto-Deploy

## Decision: separate repo, already created

`supabase/` (schema, RLS, stored procedures, and — soon — Edge Functions) lives
in its own repo: **`brodie-supabase`** (private). This repo is the single
source of truth for the database — `brodie-mobile` no longer contains a
`supabase/` folder.

**Why:** the Flutter app isn't the only planned consumer of this database — an
admin panel is likely before launch. Splitting now, while migration history is
still small, is cheap; splitting after a second client exists would mean
untangling shared history later.

**Tradeoff accepted:** stored procedures are tightly coupled to the Flutter
repository code that calls them. With two repos, a feature that needs both a
new migration *and* new app code becomes two PRs in two repos instead of one.
Practically: land the `brodie-supabase` migration PR first (or together,
cross-linking both PR descriptions), then the `brodie-mobile` PR that calls it.

## Branch strategy (decided)

| Branch | Purpose |
|---|---|
| `dev` | Where local schema changes get pushed first. New migrations, RLS changes, stored procedures — push here, review, iterate. **Not** connected to production. |
| `main` | The branch linked to the production Supabase project. The GitHub Actions deploy workflow only triggers on push to `main`. Merging `dev` → `main` is the deliberate act of shipping schema changes to production. |

This is a lighter-weight version of the "staging project" idea from the
original single-repo plan — no second hosted Supabase project, just a git
branch gate in front of the one production project. Revisit a real staging
Supabase project later if `dev`-branch testing against the local Docker
instance stops being enough (e.g. once there's a second developer, or
production data volume makes local reproduction unrealistic).

---

## Progress so far

- [x] **Step 1 — Repo created.** `brodie-supabase` exists on GitHub (private),
      cloned locally, `origin` set, `dev` and `main` branches both exist.
- [ ] **Step 2 — Move `supabase/` out of `brodie-mobile`, in progress now.**
      Moving (not copying) the folder — including the gitignored
      `.branches`/`.temp` local CLI state — so the running local Docker
      Postgres instance keeps working unchanged, just pointed at from the new
      folder location. Lands on `dev` first, not `main` — merging to `main` is
      a separate, later step, done once the production project + CI workflow
      (Steps 4–6) are ready.
- [ ] Step 3 — local dev setup note in `brodie-mobile/README.md`
- [ ] Step 4 — create production Supabase project
- [ ] Step 5 — link `main` to it, baseline first push
- [ ] Step 6 — GitHub Actions workflow on `main`
- [ ] Step 7 — prove the loop end-to-end

---

## Step 3 — Local dev setup after the split

Both repos checked out side by side:
```
GitHub/
  brodie-mobile/
  brodie-supabase/
```
`supabase start` / `supabase db reset` now run from inside `brodie-supabase/`
(on whichever branch you're testing — usually `dev`), not from
`brodie-mobile/`. `config.toml`'s `project_id` is unchanged, so the CLI finds
the same Docker containers/volumes as before — nothing about the running local
database is reset by this move.

## Step 4 — Create the production Supabase project

1. Supabase dashboard → **New project** (e.g. `brodie-prod`), note region + DB password.
2. In `brodie-supabase/`, on `main`: `supabase link --project-ref <prod-project-ref>`.

## Step 5 — First push: baseline the production DB

From `main` (after merging in whatever's on `dev` that you're ready to ship):
```bash
supabase db push
```
Applies all existing migrations to the empty prod project in order. Verify in
the hosted Studio before relying on CI for it.

## Step 6 — GitHub Actions workflow (only watches `main`)

`brodie-supabase/.github/workflows/deploy.yml`:
```yaml
name: Deploy Supabase Migrations

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: supabase/setup-cli@v1
        with:
          version: latest

      - name: Link project
        run: supabase link --project-ref $SUPABASE_PROJECT_ID
        env:
          SUPABASE_ACCESS_TOKEN: ${{ secrets.SUPABASE_ACCESS_TOKEN }}
          SUPABASE_PROJECT_ID: ${{ secrets.SUPABASE_PROJECT_ID }}

      - name: Push migrations to production
        run: supabase db push
        env:
          SUPABASE_ACCESS_TOKEN: ${{ secrets.SUPABASE_ACCESS_TOKEN }}
          SUPABASE_DB_PASSWORD: ${{ secrets.SUPABASE_DB_PASSWORD }}
```

This file itself needs to exist **on `main`** to fire on future pushes to
`main` — add it via a PR from `dev` (or a small dedicated branch) merged into
`main`, same as any other change to `main`.

### Repo secrets — add to `brodie-supabase`
`Settings → Secrets and variables → Actions`:
- `SUPABASE_ACCESS_TOKEN` (Account → Access Tokens on the Supabase dashboard)
- `SUPABASE_PROJECT_ID` (Project Settings → General)
- `SUPABASE_DB_PASSWORD` (set in Step 4)

## Step 7 — Prove the loop end-to-end

1. On `dev`: `supabase migration new test_pipeline_marker`, add a trivial/
   harmless change, `supabase db reset` locally to confirm it applies.
2. Merge `dev` → `main` (PR or direct merge).
3. Watch the Action run under `brodie-supabase`'s **Actions** tab.
4. Confirm the change landed in the hosted Studio.

---

## Ongoing workflow (after setup)

```bash
# in brodie-supabase/, on dev
supabase migration new <change_name>
# edit the generated .sql file
supabase db reset          # proves it's reproducible from migration history alone
# test the brodie-mobile app locally against `supabase start`
git add supabase/migrations/<file>.sql   # or migrations/ directly if it's repo root
git commit -m "..."
git push origin dev

# when ready to ship to production:
# open a PR dev -> main, review, merge
# → GitHub Action pushes it to production automatically
```

If the change also needs app code (new repository method calling a new RPC),
open the `brodie-mobile` PR alongside it, cross-linking both PRs in their
descriptions so reviewers see the full picture even though they're separate
diffs/repos.

---

## Deferred (not needed yet, revisit later)

- **Real staging Supabase project** — the `dev`/`main` branch gate covers most
  of this need for now (local Docker DB is the de facto "dev environment").
  Add a real hosted staging project once local reproduction stops being
  realistic (real data volume, multiple devs).
- **Manual-approval gate before migrations apply** (`workflow_dispatch` +
  required review) — a "once there's real production data" concern, not now.
- **Rollback strategy** — Supabase migrations are forward-only; a bad migration
  needs a new migration to fix it. Keep in mind for migrations that touch data,
  not just schema.
- **Admin panel repo** — when it's actually started, it becomes a second
  consumer of `brodie-supabase` (same migrations, same RPCs), which is the
  whole reason this split was done now instead of later.
