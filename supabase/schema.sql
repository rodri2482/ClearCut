-- ClearCut cloud schema (Supabase / Postgres)
--
-- Run this once in Supabase Dashboard → SQL Editor → New query → Run.
-- It is idempotent: re-running it will not drop data.
--
-- Why this file exists: the app was written against these table names, but the
-- project only had `profiles`, so every sync request answered PGRST205 ("table
-- not found") and the app fell back to local-only. Create the tables here and
-- cloud sync starts working with the publishable key already in the APK.
--
-- Security model: every row is owned by `user_key`, which is the signed-in
-- user's auth uid as text. Row Level Security pins each row to its owner, so
-- the client-side publishable key can never read another account's data.

-- ---------------------------------------------------------------------------
-- 0. Shared helpers
-- ---------------------------------------------------------------------------

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- 1. Account profile (already existed; kept idempotent)
-- ---------------------------------------------------------------------------

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  avatar_path text,
  updated_at timestamptz not null default now()
);

-- This table may predate the script, so add the columns the app writes.
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists avatar_path text;
alter table public.profiles add column if not exists updated_at timestamptz not null default now();

alter table public.profiles enable row level security;

drop policy if exists "profiles read own" on public.profiles;
create policy "profiles read own" on public.profiles
  for select using (id = auth.uid());

drop policy if exists "profiles write own" on public.profiles;
create policy "profiles write own" on public.profiles
  for insert with check (id = auth.uid());

drop policy if exists "profiles update own" on public.profiles;
create policy "profiles update own" on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

-- ---------------------------------------------------------------------------
-- 2. Watch history (default profile and named viewer profiles)
-- ---------------------------------------------------------------------------

create table if not exists public.history (
  user_key text not null,
  source_id text not null,
  show_id text not null,
  show_title text,
  cover text,
  cover_headers jsonb,
  show_url text,
  category text,
  episode_id text,
  episode_number double precision,
  episode_url text,
  position_ms bigint not null default 0,
  duration_ms bigint not null default 0,
  updated_at bigint not null default 0,
  mal_id text,
  primary key (user_key, source_id, show_id)
);

create table if not exists public.profile_history (
  user_key text not null,
  profile_id text not null,
  source_id text not null,
  show_id text not null,
  show_title text,
  cover text,
  cover_headers jsonb,
  show_url text,
  category text,
  episode_id text,
  episode_number double precision,
  episode_url text,
  position_ms bigint not null default 0,
  duration_ms bigint not null default 0,
  updated_at bigint not null default 0,
  mal_id text,
  primary key (user_key, profile_id, source_id, show_id)
);

-- ---------------------------------------------------------------------------
-- 3. My List (+ per-profile list, sync clock and tombstones)
-- ---------------------------------------------------------------------------

create table if not exists public.mylist (
  user_key text not null,
  source_id text not null,
  item_id text not null,
  title text,
  cover text,
  cover_headers jsonb,
  url text,
  type text,
  status text,
  added_at bigint not null default 0,
  sync_id uuid not null default gen_random_uuid(),
  sync_version bigint not null default 0,
  primary key (user_key, source_id, item_id)
);

create table if not exists public.profile_mylist (
  user_key text not null,
  profile_id text not null,
  source_id text not null,
  item_id text not null,
  title text,
  cover text,
  cover_headers jsonb,
  url text,
  type text,
  status text,
  added_at bigint not null default 0,
  sync_id uuid not null default gen_random_uuid(),
  sync_version bigint not null default 0,
  primary key (user_key, profile_id, source_id, item_id)
);

create table if not exists public.mylist_sync_clock (
  user_key text not null,
  profile_scope text not null default '',
  version bigint not null default 0,
  primary key (user_key, profile_scope)
);

create table if not exists public.mylist_sync_tombstones (
  user_key text not null,
  profile_scope text not null default '',
  source_id text not null,
  item_id text not null,
  sync_version bigint not null default 0,
  primary key (user_key, profile_scope, source_id, item_id)
);

-- ---------------------------------------------------------------------------
-- 4. User categories and their assignments
-- ---------------------------------------------------------------------------

create table if not exists public.list_categories (
  user_key text not null,
  id text not null,
  name text not null,
  position integer not null default 0,
  primary key (user_key, id)
);

create table if not exists public.profile_list_categories (
  user_key text not null,
  profile_id text not null,
  id text not null,
  name text not null,
  position integer not null default 0,
  primary key (user_key, profile_id, id)
);

create table if not exists public.mylist_categories (
  user_key text not null,
  source_id text not null,
  item_id text not null,
  category_id text not null,
  primary key (user_key, source_id, item_id, category_id)
);

create table if not exists public.profile_mylist_categories (
  user_key text not null,
  profile_id text not null,
  source_id text not null,
  item_id text not null,
  category_id text not null,
  primary key (user_key, profile_id, source_id, item_id, category_id)
);

-- ---------------------------------------------------------------------------
-- 5. Reading history (manga / novels)
-- ---------------------------------------------------------------------------

create table if not exists public.reading_history (
  user_key text not null,
  source_id text not null,
  show_id text not null,
  title text,
  cover text,
  chapter_id text,
  chapter_number double precision,
  chapter_url text,
  pos double precision not null default 0,
  total double precision not null default 0,
  updated_ms bigint not null default 0,
  type text,
  primary key (user_key, source_id, show_id)
);

create table if not exists public.profile_reading_history (
  user_key text not null,
  profile_id text not null,
  source_id text not null,
  show_id text not null,
  title text,
  cover text,
  chapter_id text,
  chapter_number double precision,
  chapter_url text,
  pos double precision not null default 0,
  total double precision not null default 0,
  updated_ms bigint not null default 0,
  type text,
  primary key (user_key, profile_id, source_id, show_id)
);

-- ---------------------------------------------------------------------------
-- 6. Viewer profiles (Netflix-style household profiles)
-- ---------------------------------------------------------------------------

create table if not exists public.viewer_profiles (
  user_key text not null,
  profile_id text not null,
  name text,
  bio text,
  avatar integer,
  is_kids boolean not null default false,
  photo_url text,
  cover_url text,
  accent_color integer,
  material_you boolean,
  amoled boolean,
  created_at timestamptz not null default now(),
  primary key (user_key, profile_id)
);

-- ---------------------------------------------------------------------------
-- 7. Full backup blob
-- ---------------------------------------------------------------------------

create table if not exists public.backups (
  user_key text primary key,
  payload text not null,
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 8. TV pairing (inserted by the unsigned-in TV; read by the Edge Function)
-- ---------------------------------------------------------------------------

create table if not exists public.tv_pairings (
  code text primary key,
  tv_secret text not null,
  status text not null default 'pending',
  device_name text,
  expires_at bigint not null,
  created_at timestamptz not null default now()
);

alter table public.tv_pairings enable row level security;

-- A TV has no session yet, so it must be allowed to create its own pairing.
-- Nobody can read the table through the API: the Edge Function uses the
-- service role (which bypasses RLS) to poll and approve.
drop policy if exists "tv_pairings create" on public.tv_pairings;
create policy "tv_pairings create" on public.tv_pairings
  for insert with check (true);

-- ---------------------------------------------------------------------------
-- 9. Row Level Security for every user-owned table
-- ---------------------------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array[
    'history', 'profile_history',
    'mylist', 'profile_mylist',
    'mylist_sync_clock', 'mylist_sync_tombstones',
    'list_categories', 'profile_list_categories',
    'mylist_categories', 'profile_mylist_categories',
    'reading_history', 'profile_reading_history',
    'viewer_profiles', 'backups'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "owner select" on public.%I', t);
    execute format(
      'create policy "owner select" on public.%I for select using (user_key = auth.uid()::text)', t);
    execute format('drop policy if exists "owner insert" on public.%I', t);
    execute format(
      'create policy "owner insert" on public.%I for insert with check (user_key = auth.uid()::text)', t);
    execute format('drop policy if exists "owner update" on public.%I', t);
    execute format(
      'create policy "owner update" on public.%I for update using (user_key = auth.uid()::text) with check (user_key = auth.uid()::text)', t);
    execute format('drop policy if exists "owner delete" on public.%I', t);
    execute format(
      'create policy "owner delete" on public.%I for delete using (user_key = auth.uid()::text)', t);
    execute format('create index if not exists %I on public.%I (user_key)', t || '_user_key_idx', t);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- 9b. My List change tracking
--
-- The client never writes sync_version itself: it reads a per-account clock and
-- asks for rows newer than what it has. These triggers maintain that clock, so
-- two devices converge instead of silently diverging.
-- ---------------------------------------------------------------------------

create or replace function public.mylist_bump_clock(p_user_key text, p_scope text)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v bigint;
begin
  insert into public.mylist_sync_clock (user_key, profile_scope, version)
  values (p_user_key, p_scope, 1)
  on conflict (user_key, profile_scope)
  do update set version = mylist_sync_clock.version + 1
  returning version into v;
  return v;
end;
$$;

create or replace function public.mylist_touch()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  rec jsonb;
  scope text;
  v bigint;
begin
  if tg_op = 'DELETE' then
    rec := to_jsonb(old);
    scope := coalesce(rec ->> 'profile_id', '');
    v := public.mylist_bump_clock(rec ->> 'user_key', scope);
    insert into public.mylist_sync_tombstones
      (user_key, profile_scope, source_id, item_id, sync_version)
    values
      (rec ->> 'user_key', scope, rec ->> 'source_id', rec ->> 'item_id', v)
    on conflict (user_key, profile_scope, source_id, item_id)
    do update set sync_version = excluded.sync_version;
    return old;
  end if;

  rec := to_jsonb(new);
  scope := coalesce(rec ->> 'profile_id', '');
  v := public.mylist_bump_clock(rec ->> 'user_key', scope);
  new.sync_version := v;
  if new.sync_id is null then
    new.sync_id := gen_random_uuid();
  end if;
  return new;
end;
$$;

drop trigger if exists mylist_touch on public.mylist;
create trigger mylist_touch
  before insert or update or delete on public.mylist
  for each row execute function public.mylist_touch();

drop trigger if exists profile_mylist_touch on public.profile_mylist;
create trigger profile_mylist_touch
  before insert or update or delete on public.profile_mylist
  for each row execute function public.mylist_touch();

-- ---------------------------------------------------------------------------
-- 10. Storage: profile photos and covers
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do update set public = true;

drop policy if exists "avatars public read" on storage.objects;
create policy "avatars public read" on storage.objects
  for select using (bucket_id = 'avatars');

drop policy if exists "avatars owner insert" on storage.objects;
create policy "avatars owner insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "avatars owner update" on storage.objects;
create policy "avatars owner update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "avatars owner delete" on storage.objects;
create policy "avatars owner delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ---------------------------------------------------------------------------
-- Done. Next: Authentication → URL Configuration, add the app's redirect:
--   clearcut://open
-- (and zangetsu://open if older installs still use it).
-- ---------------------------------------------------------------------------
