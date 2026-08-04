# Plan: Local → Production Supabase Auto-Deploy

## Decision: split into a separate repo

`supabase/` (schema, RLS, stored procedures, and — soon — Edge Functions) moves
out of `brodie-mobile` into its own repo: **`brodie-supabase`**.

**Why:** the Flutter app is not the only planned consumer of this database —
an admin panel is likely before launch (tech spec §3.1 already names "a second
client" as the trigger for keeping schema logic decoupled from any one app).
Splitting now, while the migration history is still small, is cheap; splitting
after a second client exists would mean untangling shared history later.

**Settings decided:**
| Decision | Choice |
|---|---|
| Repo name | `brodie-supabase` |
| Visibility | Private |
| History | Fresh start — copy current `supabase/` files as a new initial commit, don't carry over `brodie-mobile`'s per-commit history for them |

**Tradeoff accepted:** stored procedures are tightly coupled to the Flutter
repository code that calls them (`GroupRideRepository.createGroup()` →
`create_ride_group` RPC, etc.). With two repos, a feature that needs both a new
migration *and* new app code becomes two PRs in two repos instead of one — that
coordination cost is the price of the cleaner split. Practically: land the
`brodie-supabase` migration PR first (or together, referencing each other in
the PR descriptions), then the `brodie-mobile` PR that calls it.

---

## Current state (checked before writing this plan)

- Local Supabase running (`supabase start`), 15 migrations already applied
  locally, currently living at `brodie-mobile/supabase/`.
- **No hosted/production Supabase project exists yet.**
- No `.github/workflows/` in either repo yet.
- `gh` CLI is **not installed** in this environment — repo creation on GitHub
  has to be done manually via github.com, not scripted here.
- `brodie-mobile`'s working tree currently has uncommitted changes, including
  untracked files under `supabase/` (`config.toml` and 4 migration files) that
  predate this split decision.

---

## Step 1 — Create the new repo (manual, on github.com)

1. Create a new **private** repo: `brodie-supabase` (empty — no README/gitignore
   template, to avoid a merge conflict with the first push).
2. Note the clone URL, e.g. `https://github.com/FGonzales-Dev/brodie-supabase.git`.

## Step 2 — Move `supabase/` out of `brodie-mobile`, fresh history

In `brodie-mobile`:
```bash
git mv supabase ../brodie-supabase-tmp   # move files out, staged as a deletion here
```
(Or a plain filesystem move + `git add -A` if `git mv` on a whole directory is
awkward — either way, this becomes a commit in `brodie-mobile` that *removes*
`supabase/`.)

In the new location, turn it into the new repo:
```bash
cd ../brodie-supabase-tmp
git init
git add .
git commit -m "Initial import: schema, RLS, and stored procedures from brodie-mobile"
git remote add origin https://github.com/FGonzales-Dev/brodie-supabase.git
git branch -M main
git push -u origin main
```

Back in `brodie-mobile`, commit the removal:
```bash
git add -A
git commit -m "Move supabase/ to its own repo (brodie-supabase)"
git push
```

**Note:** the 4 untracked migration files + untracked `config.toml` currently
sitting in `brodie-mobile`'s working tree move over as part of this — they end
up as part of `brodie-supabase`'s initial commit, not as separate history.

## Step 3 — Local dev setup after the split

Anyone (including future-you) working on this needs both repos checked out
side by side, e.g.:
```
GitHub/
  brodie-mobile/
  brodie-supabase/
```
`supabase start` / `supabase db reset` now run from inside `brodie-supabase/`,
not from `brodie-mobile/`. Add a short note to `brodie-mobile/README.md`
pointing this out, since it's a change from how the project worked before.

## Step 4 — Create the production Supabase project

1. Supabase dashboard → **New project** (e.g. `brodie-prod`), note region + DB password.
2. In `brodie-supabase/`: `supabase link --project-ref <prod-project-ref>`.

## Step 5 — First push: baseline the production DB

```bash
supabase db push
```
This applies all 15 migrations to the empty prod project in order. Verify
tables/RLS/functions in the hosted Studio before automating further.

## Step 6 — GitHub Actions workflow (now lives in `brodie-supabase`)

Since this repo *is* the schema now, the path filter can be simpler — every
push to `main` here is a schema change by definition:

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

### Repo secrets — add to `brodie-supabase` (not `brodie-mobile`)
`Settings → Secrets and variables → Actions`:
- `SUPABASE_ACCESS_TOKEN` (Account → Access Tokens on the Supabase dashboard)
- `SUPABASE_PROJECT_ID` (Project Settings → General)
- `SUPABASE_DB_PASSWORD` (set in Step 4)

## Step 7 — Prove the loop end-to-end

1. In `brodie-supabase/`: `supabase migration new test_pipeline_marker`, add a
   trivial/harmless change, `supabase db reset` locally to confirm it applies.
2. Commit + push to `main` (or merge a PR).
3. Watch the Action run under `brodie-supabase`'s **Actions** tab.
4. Confirm the change landed in the hosted Studio.

---

## Ongoing workflow (after setup)

```bash
# in brodie-supabase/
supabase migration new <change_name>
# edit the generated .sql file
supabase db reset          # proves it's reproducible from migration history alone
# test the brodie-mobile app locally against `supabase start`
git add supabase/migrations/<file>.sql   # or just migrations/ if it's repo root now
git commit -m "..."
git push origin main        # → GitHub Action pushes it to production automatically
```

If the change also needs app code (new repository method calling a new RPC),
open the `brodie-mobile` PR alongside it, cross-linking both PRs in their
descriptions so reviewers see the full picture even though they're separate
diffs.

---

## Deferred (not needed yet, revisit later)

- **Staging Supabase project / `develop` branch gate** — add once there are
  real users, per original tech spec §3.3 guidance. Same logic applies
  regardless of which repo `supabase/` lives in.
- **Manual-approval gate before migrations apply** (`workflow_dispatch` +
  required review) — a "once there's real production data" concern, not now.
- **Rollback strategy** — Supabase migrations are forward-only; a bad migration
  needs a new migration to fix it. Keep in mind for migrations that touch data,
  not just schema.
- **Admin panel repo** — when it's actually started, it becomes a second
  consumer of `brodie-supabase` (same migrations, same RPCs), which is the
  whole reason this split was done now instead of later.
