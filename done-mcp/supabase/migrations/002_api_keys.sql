-- API keys for long-lived access (ChatGPT Actions, external integrations).
-- Keys are stored as SHA-256 hashes; the plaintext is shown once at creation.

create table public.api_keys (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  key_hash     text not null,
  label        text not null default '',
  created_at   timestamptz not null default now(),
  last_used_at timestamptz
);

create index idx_api_keys_hash on public.api_keys(key_hash);
alter table public.api_keys enable row level security;
create policy "users_own_data" on public.api_keys for all using (auth.uid() = user_id);
