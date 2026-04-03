---
name: topic-orchestrator
description: Orchestrate a topic-driven discussion and execution loop for a project using `topics/topic.md` as the backlog and `topics/understanding.md` as the running project understanding. Use when Codex needs to pick one unfinished topic, discuss and confirm requirements, optionally implement the result, write a per-topic summary Markdown file, mark the topic complete, and keep the understanding document up to date.
---

# Topic Orchestrator

## Goal

Drive a repeatable, one-topic-at-a-time workflow for projects that maintain a Markdown backlog of discussion items and a separate Markdown record of current project understanding.

Prefer this skill when the user wants steady progress through a queue of feature discussions, implementation questions, or scoped execution tasks instead of ad hoc conversation.

## Expected Workspace

Work from the repository root unless the user says otherwise.

Expect these files under `topics/`:

- `topics/topic.md`: backlog of discussion or execution topics
- `topics/understanding.md`: running notes about the project and the latest confirmed understanding
- `topics/<topic-slug>.md`: per-topic summary file created after a topic is confirmed

Expect `topics/topic.md` to use Markdown checklist items:

```md
# Topics

- [ ] Improve calendar drag-create behavior
- [ ] Rework focus mode entry point
- [x] Clean up agenda empty state
```

Treat each unchecked checklist item as an unfinished topic. If an item has indented body lines below it, treat those lines as context for that topic.

If `topics/understanding.md` is missing, create it before closing the first completed topic. Use a minimal structure such as:

```md
# Project Understanding

## Product

## Architecture

## Current Decisions

## Open Questions
```

If `topics/topic.md` is missing, explain the expected format and offer to initialize it rather than guessing a backlog.

## Workflow

### 1. Read backlog and current understanding

Read `topics/topic.md` first. Then read `topics/understanding.md` if it exists. Also read an existing `topics/<topic-slug>.md` file before continuing work on a topic that was discussed previously.

Start by summarizing:

- what unfinished topics exist
- what the current understanding already says
- which topic you recommend taking next and why

### 2. Select one unfinished topic

Select only from unchecked topics.

Choose the next topic by judgment rather than strict file order. Prefer topics that are:

- simpler and lower risk
- self-contained and easy to close in one pass
- likely to clarify later work
- not blocked by missing decisions or major upstream dependencies

Break ties by choosing the topic that unlocks the most future work. If there is still a tie, prefer the earlier topic in `topics/topic.md`.

State explicitly why the chosen topic is the best next step.

### 3. Run discussion before execution

Use Plan Mode when it is available for the current conversation. If the current conversation is not in Plan Mode, say that this workflow works best in Plan Mode and ask the user to switch before detailed planning or execution.

Until the user switches to Plan Mode, limit work to:

- reading backlog and understanding files
- recommending the next topic
- clarifying what needs to be discussed

Do not pretend you changed the conversation mode yourself.

When discussion begins, drive it toward a decision-complete result:

- goal and success criteria
- scope and non-goals
- implementation need vs discussion-only outcome
- constraints and dependencies
- expected validation or acceptance checks

### 4. Write the per-topic summary before implementation

After the requirements are confirmed, create or update `topics/<topic-slug>.md` before implementation work starts.

Generate `<topic-slug>` from the topic title using a stable lowercase hyphenated slug.

Use this structure:

```md
# <Topic Title>

## Background

## Discussion Summary

## Decisions

## In Scope

## Out of Scope

## Execution Notes

## Impact on Understanding
```

If the topic is discussion-only, record the final outcome in `Execution Notes` as "No implementation required" and still close the topic.

### 5. Execute only when the confirmed result requires it

If the topic needs implementation, execute only after:

- discussion is confirmed
- the topic summary file exists
- the work can be described concretely enough to implement safely

Perform the implementation in the normal project workflow. Run relevant tests or checks when feasible. Then update the same `topics/<topic-slug>.md` file with:

- what changed
- what was verified
- any important follow-up items

### 6. Close the topic and update project understanding

When the topic is complete:

1. Update `topics/<topic-slug>.md` with the final result.
2. Update `topics/understanding.md` incrementally. Revise only the sections affected by the new decision or implementation.
3. Mark the topic as complete in `topics/topic.md` by changing `- [ ]` to `- [x]`.

Do not rewrite the whole understanding document if only one section changed.

If the work produces new follow-up items, add them as new unchecked topics instead of leaving the completed topic open.

## Output Rules

Keep file edits structured and predictable.

- Preserve unrelated topic ordering and notes in `topics/topic.md`.
- Reuse an existing `topics/<topic-slug>.md` file when returning to the same topic.
- Make the per-topic summary the main record of the discussion result.
- Treat `topics/understanding.md` as a living synthesis, not a full transcript.

When reporting progress to the user, separate:

- discussion status
- implementation status
- documentation updates

## Good Triggers

Use this skill for requests like:

- "Read `topics/topic.md` and pick the next thing we should discuss."
- "Work through one unfinished topic, confirm the requirements, then implement it."
- "Summarize the discussion in a topic file and update the project understanding."
- "Keep a running understanding document while we close topics one by one."
