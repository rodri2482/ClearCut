# ClearCut cloud setup (Supabase)

ClearCut keeps everything working offline. Accounts, sync and photo upload turn
on only when a Supabase project is compiled in:

```
flutter build apk --release \
  --dart-define=SUPABASE_URL=https://<project>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=sb_publishable_...
```

The publishable key is safe to ship. Never put a `service_role` key in the app.

## 1. Create the tables

Supabase Dashboard → **SQL Editor** → **New query** → paste
[`schema.sql`](schema.sql) → **Run**.

Without this step every sync request answers `PGRST205` ("table not found") and
the app stays local-only. The script is idempotent, so it is safe to re-run.

## 2. Allow the app's redirect

Supabase Dashboard → **Authentication** → **URL Configuration**:

- **Site URL**: anything valid, e.g. `https://clearcut.app`
- **Redirect URLs** — add both:
  - `clearcut://open`
  - `zangetsu://open`

If a redirect is missing from this list, Supabase falls back to the Site URL,
which is why sign-in can appear to "return to localhost" or to a web page
instead of the app.

## 3. Email confirmation (optional)

Authentication → **Providers** → **Email**: if "Confirm email" is on, the
confirmation link must redirect to `clearcut://open` (covered by step 2).

## 4. Storage

`schema.sql` creates the public `avatars` bucket and policies that only let a
signed-in user write inside their own `<uid>/` folder.

## What syncs

| Feature | Table |
|---|---|
| Continue watching / history | `history`, `profile_history` |
| My List + watch status | `mylist`, `profile_mylist` |
| List categories | `list_categories`, `mylist_categories` (+ per-profile twins) |
| Manga / novel progress | `reading_history`, `profile_reading_history` |
| Household profiles | `viewer_profiles` |
| Full backup | `backups` |
| TV pairing | `tv_pairings` (insert only; approved through an Edge Function) |

Row Level Security pins every row to `user_key = auth.uid()::text`, so the
publishable key cannot read another account's data.
