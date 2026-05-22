-- Event image binaries → Supabase Storage.
--
-- This is the L2 (cross-platform / cross-Apple-ID) layer for image backup,
-- per the architecture decided in issue #21. Issue #16 (CloudKit) will
-- eventually add an L1 same-Apple-ID fast path on top of this; today this
-- bucket is the only cloud-side image backup.
--
-- Safety properties:
--   - Bucket creation is idempotent (ON CONFLICT DO NOTHING) so re-running
--     this migration won't fail if the bucket was created out-of-band.
--   - Bucket is private; no anonymous access. All reads/writes must
--     authenticate.
--   - File size capped at 5 MB to match the compressed JPEG ceiling we
--     produce in `AgenticIntakeAssetStore` (resized to 2048px,
--     `jpegQuality: 0.82`, typically 200–500 KB). The 5 MB ceiling
--     catches accidental upload of uncompressed raw images while leaving
--     enough headroom for the occasional larger photo.
--   - MIME types restricted to JPEG / PNG (the only formats we currently
--     produce). HEIC isn't on the list because the asset store converts
--     incoming HEIC to JPEG before storing.
--   - RLS policies use the path's first folder segment as the user-id
--     prefix. The bucket name is stored separately in `storage.objects.bucket_id`,
--     so the `name` column actually contains `{user_id}/{eventID}/{imageID}.jpg`
--     (no leading `event-images/`). `storage.foldername(name)[1]` returns
--     the first segment, which equals `auth.uid()::text` when the path was
--     written by the right user. The iOS client uploads to the URL
--     `…/storage/v1/object/event-images/{user_id}/{eventID}/{imageID}.jpg`,
--     and Supabase Storage parses out `bucket_id = 'event-images'` and
--     `name = '{user_id}/{eventID}/{imageID}.jpg'`.
--
-- Auth note: the iOS client for these operations MUST pass the user's
-- session JWT in `Authorization: Bearer <user_jwt>` for `auth.uid()` to
-- resolve correctly. Existing PostgREST code in `SupabaseSyncService`
-- uses the project's service_role key for both headers, which bypasses
-- RLS — that's a separate security gap unrelated to this migration. New
-- image-storage code uses user-JWT auth from day one (see
-- `SupabaseImageStorageService`).

-- ============================================================
-- Bucket
-- ============================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'event-images',
  'event-images',
  false,                              -- private
  5 * 1024 * 1024,                    -- 5 MB ceiling
  array['image/jpeg', 'image/png']    -- only what AgenticIntakeAssetStore produces
)
on conflict (id) do nothing;

-- ============================================================
-- RLS — per-user folder isolation
-- ============================================================
-- `storage.objects.name` contains the path WITHIN the bucket (the bucket
-- itself lives in `bucket_id`), so the stored value is
-- `{user_id}/{eventID}/{imageID}.jpg`. `storage.foldername(name)` returns
-- the path as a 1-indexed array; `[1]` is the first segment (= user_id).
-- Comparing against `auth.uid()::text` restricts access to the
-- authenticated user's own folder.
--
-- All four operations (SELECT/INSERT/UPDATE/DELETE) get policies even
-- though the iOS client only currently issues SELECT/INSERT/DELETE — an
-- explicit UPDATE policy is cheap insurance against future code paths.

drop policy if exists "Users can read their own event images" on storage.objects;
create policy "Users can read their own event images"
  on storage.objects for select
  using (
    bucket_id = 'event-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Users can insert their own event images" on storage.objects;
create policy "Users can insert their own event images"
  on storage.objects for insert
  with check (
    bucket_id = 'event-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Users can update their own event images" on storage.objects;
create policy "Users can update their own event images"
  on storage.objects for update
  using (
    bucket_id = 'event-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'event-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Users can delete their own event images" on storage.objects;
create policy "Users can delete their own event images"
  on storage.objects for delete
  using (
    bucket_id = 'event-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
