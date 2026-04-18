-- MCP connect codes: short-lived codes for linking OAuth sessions to real accounts.
-- Generated in-app, entered in the OAuth browser page during Claude.ai/ChatGPT MCP setup.

create table public.mcp_connect_codes (
  code       text primary key,           -- 6-char alphanumeric
  user_id    uuid not null references auth.users(id) on delete cascade,
  expires_at timestamptz not null,
  used       boolean not null default false,
  created_at timestamptz not null default now()
);

create index idx_mcp_connect_codes_expires on public.mcp_connect_codes(expires_at);

alter table public.mcp_connect_codes enable row level security;

create policy "Users can create their own connect codes"
  on public.mcp_connect_codes for insert
  with check (auth.uid() = user_id);
