-- Event behavior kind + absorption + people + timer columns.
--
-- Closes the four Event fields that round-trip-fail today (issues #38 and
-- #45). Until these columns exist the iOS upload path filters out any
-- event that uses them; the local interim guard is removed in the same
-- PR that ships this migration.
--
-- Columns:
--   1. `behavior_kind` — `Event.kind` (`'event'` or `'todo'`). This is the
--      calendar-todo-unification behavioral kind: `.event` is the legacy
--      default, `.todo` opts into explicit-completion / soft-time
--      semantics. NOT the same as the existing `kind` column on this
--      table, which is a routing label (`'calendar'` vs `'todo'`)
--      naming the *source store* that produced the row. Two distinct
--      concepts, hence the disambiguating `behavior_` prefix; reusing
--      `kind` would silently overload an already-load-bearing column.
--      Defaulted to `'event'` so existing rows decode unchanged.
--
--   2. `absorbed_into_event_id` — `Event.absorbedIntoEventID`. When set on
--      a `.todo`, this todo has been absorbed into the event with this
--      id and no longer renders independently on the canvas. No FK to
--      `events.id` because absorption is local UX state, not a referential
--      invariant — the parent may legitimately be missing during a
--      partial restore.
--
--   3. `people_ids` — `Event.peopleIDs`. The "with whom" list; holds
--      `Person` ids materialized at bind time (groups are expanded, not
--      stored by reference) so later edits to a group never rewrite this
--      event's history.
--
--   4. `timer_started_at` — `Event.timerStartedAt`. Non-nil while the
--      event's timer is running; cleared when the timer stops.
--
-- Operational note: adding these columns invalidates every existing
-- `rowHash` on the iOS client (the hash inputs change shape), so the
-- first sync after deploy will trigger a mass re-upsert of every
-- event row from every device. This is expected, not a bug — the
-- re-upsert converges within one sync window and is hash-gated again
-- on subsequent runs.

alter table public.events
  add column if not exists behavior_kind text not null default 'event'
    check (behavior_kind in ('event','todo')),
  add column if not exists absorbed_into_event_id uuid,
  add column if not exists people_ids uuid[],
  add column if not exists timer_started_at timestamptz;

create index if not exists idx_events_user_behavior_kind
  on public.events(user_id, behavior_kind);
create index if not exists idx_events_absorbed_parent
  on public.events(user_id, absorbed_into_event_id)
  where absorbed_into_event_id is not null;
