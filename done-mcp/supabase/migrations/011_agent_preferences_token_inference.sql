-- Extend `agent_preferences` to also carry `TokenInferenceRepository`'s
-- learned state. These three blobs were the largest unbackedup data
-- bucket per the full-backup audit: the agent's accumulated dynamic /
-- meta hypotheses + per-occurrence projections drive every token-class
-- recommendation, and restoring on a fresh device without them means
-- the agent re-learns everything from zero.
--
-- Schema choice: extend the existing single-row-per-user table rather
-- than spawning a fourth blob table. Token inference state is "agent's
-- learned model", same conceptual neighborhood as rules + decision
-- history. One row, one sync path, one restore path.
--
-- Columns default to NULL (vs jsonb '[]') so existing rows aren't
-- mutated by the ALTER. Client decodes NULL as "no cloud state yet".

alter table agent_preferences
  add column if not exists token_dynamic_hypotheses jsonb,
  add column if not exists token_meta_hypotheses jsonb,
  add column if not exists token_projections jsonb;
