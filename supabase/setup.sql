-- Polaroid Maker: database setup
-- Paste this whole file into Supabase → SQL Editor → New query, then click Run.
-- It is safe to run more than once.

-- 1. The polaroids table: one row per saved polaroid.
create table if not exists public.polaroids (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  caption     text not null default '' check (char_length(caption) <= 80),
  font        text not null default 'Caveat',
  text_size   int  not null default 92 check (text_size between 40 and 130),
  ink         text not null default '#1f2023',
  frame       text not null default 'plain',
  pan_x       real not null default 0.5 check (pan_x between 0 and 1),
  pan_y       real not null default 0.5 check (pan_y between 0 and 1),
  photo_path  text,             -- original photo, private "photos" bucket
  render_path text,             -- finished polaroid PNG, private "photos" bucket
  share_token uuid unique,      -- empty = private; set = viewable at view.html?s=<token>
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists polaroids_user_id_idx on public.polaroids (user_id, updated_at desc);

-- Keep updated_at current on every edit.
create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists polaroids_touch on public.polaroids;
create trigger polaroids_touch before update on public.polaroids
  for each row execute function public.touch_updated_at();

-- 2. Row level security: you can only see and change your own polaroids.
alter table public.polaroids enable row level security;

drop policy if exists "Owners can read their polaroids" on public.polaroids;
create policy "Owners can read their polaroids" on public.polaroids
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "Owners can add polaroids" on public.polaroids;
create policy "Owners can add polaroids" on public.polaroids
  for insert to authenticated with check (user_id = (select auth.uid()));

drop policy if exists "Owners can edit their polaroids" on public.polaroids;
create policy "Owners can edit their polaroids" on public.polaroids
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists "Owners can delete their polaroids" on public.polaroids;
create policy "Owners can delete their polaroids" on public.polaroids
  for delete to authenticated using (user_id = (select auth.uid()));

-- 3. Viewers with a share link can look up that one polaroid, and nothing else.
--    They can't list polaroids or see anyone's private ones.
create or replace function public.get_shared_polaroid(token uuid)
returns table (caption text, updated_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select p.caption, p.updated_at
  from public.polaroids p
  where p.share_token = token;
$$;

revoke all on function public.get_shared_polaroid(uuid) from public;
grant execute on function public.get_shared_polaroid(uuid) to anon, authenticated;

-- 4. File storage.
--    "photos" is private: original photos and finished polaroids, one folder per user.
--    "shared" is public by link: a copy of each shared polaroid, named after its secret share token.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('photos', 'photos', false, 10485760, array['image/jpeg', 'image/png']),
  ('shared', 'shared', true,  10485760, array['image/png'])
on conflict (id) do nothing;

-- Private photos: only the owner can read or write files in their own folder.
drop policy if exists "Owners read own photos" on storage.objects;
create policy "Owners read own photos" on storage.objects
  for select to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists "Owners upload own photos" on storage.objects;
create policy "Owners upload own photos" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists "Owners replace own photos" on storage.objects;
create policy "Owners replace own photos" on storage.objects
  for update to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists "Owners delete own photos" on storage.objects;
create policy "Owners delete own photos" on storage.objects
  for delete to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- Shared copies: you can only publish a file for a polaroid you own that has sharing turned on.
-- Nobody can list this bucket; viewers open one file by its exact secret name.
drop policy if exists "Owners publish shared copies" on storage.objects;
create policy "Owners publish shared copies" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'shared'
    and exists (
      select 1 from public.polaroids p
      where p.user_id = (select auth.uid())
        and p.share_token is not null
        and name = p.share_token::text || '.png'
    )
  );

drop policy if exists "Owners see own shared copies" on storage.objects;
create policy "Owners see own shared copies" on storage.objects
  for select to authenticated
  using (bucket_id = 'shared' and owner_id = (select auth.uid())::text);

drop policy if exists "Owners replace own shared copies" on storage.objects;
create policy "Owners replace own shared copies" on storage.objects
  for update to authenticated
  using (bucket_id = 'shared' and owner_id = (select auth.uid())::text)
  with check (bucket_id = 'shared' and owner_id = (select auth.uid())::text);

drop policy if exists "Owners remove own shared copies" on storage.objects;
create policy "Owners remove own shared copies" on storage.objects
  for delete to authenticated
  using (bucket_id = 'shared' and owner_id = (select auth.uid())::text);
