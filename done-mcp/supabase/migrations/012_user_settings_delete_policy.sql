-- Belt-and-suspenders for the user-JWT migration (#28 Stage 1).
--
-- All seven iOS-client tables already have RLS enabled with the correct
-- `auth.uid() = user_id` shape from migration 001 / 006. Six of them use
-- `for all` policies which cover SELECT/INSERT/UPDATE/DELETE. The lone
-- gap: `user_settings` (migration 006) only declared SELECT / INSERT /
-- UPDATE policies — no DELETE.
--
-- Today this is harmless because the iOS client's `diffSync` delete
-- branch only fires when a row's ID disappears from the local set, and
-- `user_settings` follows a single-row hash-replacement path that never
-- DELETEs. Under user-JWT auth that stays harmless. Adding the policy
-- now means future call sites can rely on the symmetric pattern without
-- a silent 403.
--
-- Idempotent (drop-if-exists + create). Safe to re-run.

drop policy if exists "Users can delete their own user_settings" on user_settings;
create policy "Users can delete their own user_settings"
  on user_settings for delete
  using (auth.uid() = user_id);
