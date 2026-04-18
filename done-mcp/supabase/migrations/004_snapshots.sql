-- AI context snapshot tokens
-- Each token is a short-lived key that lets an AI fetch a user's data as Markdown.

create table public.snapshots (
  token      text primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index idx_snapshots_expires on public.snapshots(expires_at);

-- Users can insert their own tokens (RLS)
alter table public.snapshots enable row level security;

create policy "Users can create their own snapshots"
  on public.snapshots for insert
  with check (auth.uid() = user_id);

-- Edge functions use service role key, bypasses RLS
