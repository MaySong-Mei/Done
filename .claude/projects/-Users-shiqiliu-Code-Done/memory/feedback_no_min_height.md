---
name: No minimum height for events
description: Do not set minimumHeight for timeline event blocks — user explicitly wants no minimum height enforcement
type: feedback
---

Do not set minimumHeight (e.g. hourHeight / 4) for event blocks in the timeline.

**Why:** User does not want events to have an enforced minimum height — they should render at their natural calculated height.

**How to apply:** When adding or modifying event block frames in TimelineView, always use `minimumHeight: 0` in `timelineEventHeight()` calls.
