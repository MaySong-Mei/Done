-- Done MCP: Initial Schema
-- Human-owned tables (iOS syncs here, MCP reads only)
-- AI-owned tables (MCP can write, physically separated)

-- ============================================================
-- AUTH
-- ============================================================
-- We rely on Supabase Auth (auth.users). Each row in our tables
-- carries a user_id referencing auth.users.id. RLS enforces
-- per-user isolation.

-- ============================================================
-- HUMAN-OWNED TABLES  (source of truth: iOS app)
-- ============================================================

-- Event types defined by the user (e.g. "Study", "Exercise")
create table public.event_types (
  id          uuid primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  title       text not null,
  color_hex   text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  synced_at   timestamptz not null default now()
);

-- Todo lists
create table public.todo_lists (
  id          uuid primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  title       text not null,
  color_name  text not null,
  created_at  timestamptz not null default now(),
  synced_at   timestamptz not null default now()
);

-- Events: both calendar events and todos live here
create table public.events (
  id                        uuid primary key,
  user_id                   uuid not null references auth.users(id) on delete cascade,
  kind                      text not null check (kind in ('calendar', 'todo')),

  -- core
  title                     text not null default '',
  note                      text not null default '',
  location                  text not null default '',
  type                      text not null default '',
  additional_types          text[] default null,
  type_weights              jsonb default null,
  tags                      text[] not null default '{}',
  priority                  int not null default 0,
  status                    text not null default 'active'
                            check (status in ('active', 'completed', 'archived')),
  is_all_day                boolean not null default false,
  is_done                   boolean not null default false,
  color_depth               double precision not null default 1.0,

  -- time
  time_ranges               jsonb not null default '[]',   -- [{start, end}]
  deadline                  timestamptz,
  complete_at               timestamptz,

  -- recurrence
  repeat_unit               text not null default 'none'
                            check (repeat_unit in ('none','day','week','month','year')),
  repeat_interval           int not null default 1,
  repeat_end_type           text not null default 'none'
                            check (repeat_end_type in ('none','onDate','afterCount')),
  repeat_end_date           timestamptz,
  repeat_end_count          int,
  recurrence_parent_id      uuid,
  recurrence_instance_date  timestamptz,
  recurrence_exception_dates timestamptz[] not null default '{}',

  -- linking
  linked_calendar_event_id  uuid,
  linked_todo_event_id      uuid,
  list_id                   uuid,

  -- display / interrupt
  display_kind              text not null default 'regular'
                            check (display_kind in ('regular','interrupt')),
  interrupt_relation        jsonb,   -- {parentEventID, state, ...}

  -- timestamps
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  synced_at                 timestamptz not null default now()
);

create index idx_events_user_kind on public.events(user_id, kind);
create index idx_events_user_type on public.events(user_id, type);
create index idx_events_user_status on public.events(user_id, status);
create index idx_events_created on public.events(user_id, created_at);

-- Calendar event log records (activity logs with emotions/behaviors)
create table public.event_logs (
  id                      text primary key,  -- serialized CalendarOccurrenceKey
  user_id                 uuid not null references auth.users(id) on delete cascade,
  event_id                uuid not null,
  base_series_event_id    uuid,
  occurrence_date         timestamptz not null,
  completion_status       text check (completion_status in ('completed','partial','skipped')),
  actual_duration_minutes int,
  summary                 text not null default '',
  note                    text not null default '',
  effort                  int check (effort between 1 and 5),
  emotions                text[] not null default '{}',
  behaviors               text[] not null default '{}',
  suggested_template_id   text,
  selected_template_id    text,
  template_answers        jsonb not null default '{}',
  timeline_items          jsonb not null default '[]',
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  synced_at               timestamptz not null default now()
);

create index idx_event_logs_user on public.event_logs(user_id, occurrence_date);
create index idx_event_logs_event on public.event_logs(user_id, event_id);
create index idx_event_logs_emotions on public.event_logs using gin(emotions);
create index idx_event_logs_behaviors on public.event_logs using gin(behaviors);

-- Calendar event feedback records (legacy/structured feedback)
create table public.event_feedback (
  id                      text primary key,  -- serialized CalendarOccurrenceKey
  user_id                 uuid not null references auth.users(id) on delete cascade,
  event_id                uuid not null,
  base_series_event_id    uuid,
  occurrence_date         timestamptz not null,
  effort                  int check (effort between 1 and 5),
  emotions                text[] not null default '{}',
  behaviors               text[] not null default '{}',
  self_note               text not null default '',
  logs                    jsonb not null default '[]',
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  synced_at               timestamptz not null default now()
);

create index idx_event_feedback_user on public.event_feedback(user_id, occurrence_date);

-- Skill insights extracted from activities
create table public.skill_insights (
  id           uuid primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  skill_name   text not null,
  points       double precision not null,
  date         timestamptz not null,
  event_title  text not null,
  reasoning    text not null default '',
  created_at   timestamptz not null default now(),
  synced_at    timestamptz not null default now()
);

create index idx_skills_user on public.skill_insights(user_id, date);
create index idx_skills_name on public.skill_insights(user_id, skill_name);

-- ============================================================
-- AI-OWNED TABLES  (LLM writes here via MCP, humans read only)
-- ============================================================

create table public.ai_insights (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  insight_type       text not null,       -- 'pattern', 'trend', 'milestone', 'observation'
  content            text not null,
  related_event_ids  uuid[] default '{}',
  period_start       timestamptz,
  period_end         timestamptz,
  model              text,                -- which LLM generated this
  created_at         timestamptz not null default now()
);

create index idx_ai_insights_user on public.ai_insights(user_id, created_at);

create table public.ai_summaries (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  period_start  timestamptz not null,
  period_end    timestamptz not null,
  content       text not null,
  model         text,
  created_at    timestamptz not null default now()
);

create index idx_ai_summaries_user on public.ai_summaries(user_id, period_start);

create table public.ai_questions (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  content            text not null,
  related_event_ids  uuid[] default '{}',
  is_answered        boolean not null default false,
  answer             text,
  model              text,
  created_at         timestamptz not null default now()
);

create index idx_ai_questions_user on public.ai_questions(user_id, is_answered);

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================

alter table public.event_types enable row level security;
alter table public.todo_lists enable row level security;
alter table public.events enable row level security;
alter table public.event_logs enable row level security;
alter table public.event_feedback enable row level security;
alter table public.skill_insights enable row level security;
alter table public.ai_insights enable row level security;
alter table public.ai_summaries enable row level security;
alter table public.ai_questions enable row level security;

-- Users can only see their own data
create policy "users_own_data" on public.event_types
  for all using (auth.uid() = user_id);
create policy "users_own_data" on public.todo_lists
  for all using (auth.uid() = user_id);
create policy "users_own_data" on public.events
  for all using (auth.uid() = user_id);
create policy "users_own_data" on public.event_logs
  for all using (auth.uid() = user_id);
create policy "users_own_data" on public.event_feedback
  for all using (auth.uid() = user_id);
create policy "users_own_data" on public.skill_insights
  for all using (auth.uid() = user_id);
create policy "users_own_data" on public.ai_insights
  for all using (auth.uid() = user_id);
create policy "users_own_data" on public.ai_summaries
  for all using (auth.uid() = user_id);
create policy "users_own_data" on public.ai_questions
  for all using (auth.uid() = user_id);

-- Service role (used by MCP server) bypasses RLS by default,
-- but we still filter by user_id in queries for safety.
