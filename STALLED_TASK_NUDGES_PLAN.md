# Stalled Task Nudges Plan

## Summary

Improve the Obsidian TODOs menubar by helping notice and resolve stalled tasks without creating a second task-management system.

The app should stay lightweight: no tags, no project hierarchy, no hidden punt counter, and no automatic metadata written into task lines. It should expose friction at the right moment and make the next useful action easy.

## Behavior

Add a `Stalled Review` section derived from existing visible markdown dates. Stalled tasks appear only in this review surface so they do not inflate the visible workload by also appearing in an urgency bucket.

A task is considered stalled when:

- It is open or in progress.
- It has a due date overdue by at least 7 days, or a scheduled date older than 14 days.
- It is not done or cancelled.
- Undated tasks are not considered stalled, because the app cannot know their real age without hidden state.

Add a small review nudge to defer actions:

- When using `Due Tomorrow`, `Due in 7 Days`, or `Snooze 1 Week`, prefer a submenu flow that offers:
  - `Open to Rewrite`
  - `Cancel Task`
  - `Defer Anyway`
- The goal is to interrupt automatic deferral and make rewriting/cancelling easier than blindly punting.

## Non-Goals

Do not append punt counts like `rescheduled:: 3` to task lines.

Do not add a local Hammerspoon database or state file for first-seen dates or reschedule counts.

Do not introduce new Obsidian tags, project fields, or review metadata.

## Implementation Notes

Add stalled detection during task parsing or immediately after parsing, using existing `dueDate`, `scheduledDate`, `status`, and current time.

Add a `Stalled Review` menu section above the normal urgency buckets, limited to 5 items.

Keep the existing urgency classification, but remove stalled tasks from their normal bucket while they qualify for `Stalled Review`.

For defer actions, preserve the existing direct behavior behind a deliberate `Defer Anyway` action.

## Test Plan

Manually verify:

- A task due 8 days ago appears in `Stalled Review`.
- A task due yesterday does not appear just because it is overdue.
- A task scheduled 15 days ago appears.
- An in-progress task with an old due/scheduled date appears.
- Done and cancelled tasks do not appear.
- Undated tasks do not appear.
- Stalled tasks do not also appear in their normal urgency bucket.
- Existing actions still work: open, done, in progress, cancel, due tomorrow, due in 7 days, snooze.
- Hammerspoon reload still builds the menu and watcher refresh still works.

## Assumptions

The menubar app should support behavior change through small nudges, not become the system of record for task psychology.

Exact punt counts are less useful than interrupting the defer habit at the moment it happens.
