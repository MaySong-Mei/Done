-- User settings + field-level backup gaps.
--
-- Adds:
--   1. `user_settings` — single-row-per-user JSON blob of UserDefaults values
--      that the iOS app considers user-specific (provider, API key, display
--      preferences, frozen reference time zone, etc.). One row per user so the
--      blob can grow without schema migrations as the app adds settings.
--
--   2. `events.wanna_notes` — wanna-feature field that was defined on the
--      model but never plumbed to the cloud row builder.
--
--   3. `events.agentic_intake` / `events.suggested_log_template_*` — AI-driven
--      fields that also weren't synced. Image *binaries* remain out of scope
--      (tracked in issue #16, CloudKit-based).
--
--   4. `event_feedback.chat_conversation_id` — links feedback to the agent
--      chat that produced it. Was never round-tripped.

-- ============================================================
-- user_settings
-- ============================================================
create table public.user_settings (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  settings   jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  synced_at  timestamptz not null default now()
);

alter table public.user_settings enable row level security;

create policy "Users can read their own settings"
  on public.user_settings for select
  using (auth.uid() = user_id);

create policy "Users can insert their own settings"
  on public.user_settings for insert
  with check (auth.uid() = user_id);

create policy "Users can update their own settings"
  on public.user_settings for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- ============================================================
-- events: wanna + agentic intake + suggested log template
-- ============================================================
alter table public.events
  add column if not exists wanna_notes jsonb,
  add column if not exists agentic_intake jsonb,
  add column if not exists suggested_log_template_id text,
  add column if not exists suggested_log_template_confidence double precision,
  add column if not exists suggested_log_template_updated_at timestamptz,
  add column if not exists suggested_log_template_source text;

-- ============================================================
-- event_feedback: chat conversation link
-- ============================================================
alter table public.event_feedback
  add column if not exists chat_conversation_id uuid;
