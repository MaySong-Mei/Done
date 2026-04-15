-- OAuth authorization code flow tables

create table public.oauth_codes (
  code         text primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  client_id    text not null,
  redirect_uri text not null,
  expires_at   timestamptz not null,
  used         boolean not null default false,
  created_at   timestamptz not null default now()
);

create index idx_oauth_codes_expires on public.oauth_codes(expires_at);

create table public.oauth_clients (
  client_id     text primary key,
  client_secret text not null,
  label         text not null default '',
  created_at    timestamptz not null default now()
);

insert into public.oauth_clients (client_id, client_secret, label)
values ('done-chatgpt', 'done-chatgpt-secret-2026', 'ChatGPT Actions');
