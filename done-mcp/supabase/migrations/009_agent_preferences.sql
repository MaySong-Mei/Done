-- Phase 2 of full-backup completion: sync `AgentPreferenceStore`.
--
-- The agent's learned-rules table and recent decision history were
-- file-based local-only (Application Support/AgentRuntime/*.json). After
-- restore on a new device, the agent forgot the user's preferences
-- (e.g. "don't keep asking me to create templates for this type") and
-- had no history of past decisions. Closes audit gap #2.
--
-- Shape: one row per user. Both arrays are stored as jsonb. Encoding
-- chosen for two reasons:
--   1. The rule + decision data models are nested Swift structs with
--      enums and associated values; emitting them as relational columns
--      would require either a schema migration on every model change or
--      reflective serialization. jsonb lets the iOS client own the
--      shape end-to-end.
--   2. Total size per user is small (~hundreds of rules max, 300-row
--      decision history cap). Well under jsonb's practical limits.

create table if not exists agent_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  rules jsonb not null default '[]'::jsonb,
  decision_history jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  synced_at timestamptz not null default now()
);

alter table agent_preferences enable row level security;

drop policy if exists "Users can manage own agent_preferences" on agent_preferences;
create policy "Users can manage own agent_preferences"
  on agent_preferences for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
