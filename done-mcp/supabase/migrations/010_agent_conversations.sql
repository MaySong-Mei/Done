-- Phase 3 of full-backup completion: sync agent chat history.
--
-- The agent's conversation list (recent chats with the AI) lived only
-- in `UserDefaults` under the `agentConversations` key. After restore
-- on a new device, the user lost all chat context. Closes audit gap #3.
--
-- Shape: one row per user, with the full conversations array as jsonb.
-- Same rationale as `agent_preferences`: nested Swift model shape, low
-- ceiling on size (chats are short text, capped retention in client).
-- If a future user's history blows past ~10MB we'll revisit either
-- per-conversation rows or a trim-by-age policy on the client.

create table if not exists agent_conversations (
  user_id uuid primary key references auth.users(id) on delete cascade,
  conversations jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  synced_at timestamptz not null default now()
);

alter table agent_conversations enable row level security;

drop policy if exists "Users can manage own agent_conversations" on agent_conversations;
create policy "Users can manage own agent_conversations"
  on agent_conversations for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
