<div align="center">

# Obsidian TODOs Menubar

### Your vault's overdue and today tasks, one click from the menubar.

</div>

Obsidian holds your tasks, but it is rarely the app you're in when you wonder what's due. This single Hammerspoon script scans your vault with ripgrep and keeps a badge of the most urgent thing you owe: `⚠️ 2` overdue, else `🔔` due today, else `📆` this week, else `📋` backlog, else `✓`. Click it, and every task is one hover away from Mark Done, Start, or a reschedule, written straight back into the note as `[x]`, `✅ 2026-08-11`, or a new due date.

Everything runs locally: one `rg` scan, a file watcher, no daemon and no sync. The only thing it ever writes is the single task line you acted on, and only after checking that the line on disk still matches what the menu showed. If the note changed underneath, it refreshes instead of guessing.

<div align="center">

<img src="assets/demo.gif" width="850" alt="The menubar badge shows 2 overdue tasks; Mark Done is picked from a task's submenu; the badge drops to 1 and the note's checkbox line flips to done with a ✅ completion date.">

</div>

*The demo runs against a staged vault; the menu, the badge, and the edit to `Personal.md` are all real.*

## Install

1. Install [Hammerspoon](https://www.hammerspoon.org/) and ripgrep (`brew install ripgrep`)
2. Download the script:
   ```bash
   curl -L https://raw.githubusercontent.com/wilbeibi/obsidian-todos-menubar/main/obsidian-todos.lua -o ~/.hammerspoon/obsidian-todos.lua
   ```
3. Add to `~/.hammerspoon/init.lua`:
   ```lua
   require('obsidian-todos')
   ```
4. If your vault isn't in the default iCloud location, point at it from the Hammerspoon Console:
   ```lua
   hs.settings.set('obsidianTodos.vaultPath', '/absolute/path/to/YourVault')
   hs.reload()
   ```
5. Give Hammerspoon Full Disk Access (System Settings → Privacy & Security) so ripgrep can read iCloud vaults.

Optional: install the [Advanced URI plugin](https://github.com/Vinzent03/obsidian-advanced-uri) in Obsidian, and clicking a task opens the exact line instead of just the file.

## Task format

Plain markdown checkboxes, anywhere in the vault:

```markdown
- [ ] Basic task
- [/] In-progress task (shows ⏳ in the menu)
- [-] Cancelled task (hidden)
- [ ] High priority 🔺
- [ ] Due date 📅 2026-08-15
- [ ] Dataview style due:: [[2026-08-15]]
- [ ] TaskPaper style @due(2026-08-15)
- [/] Snoozed 🛫 2026-08-20
```

Priorities `🔺⏫🔼🔽⏬` weight the sort order. A bare `YYYY-MM-DD` also counts as a due date when the line mentions "due". Rescheduling rewrites whichever notation the line already uses.

## What the menu does

<div align="center">

<img src="assets/menu.png" width="640" alt="The open menu: Overdue and Today tasks inline with priority markers and due dates, This Week / Later / Recently Done as submenus, and a task's hover submenu showing Mark Done, Start, Schedule and More.">

</div>

- The badge shows only the most urgent tier's count; the hover tooltip breaks down Overdue / Today / This Week.
- Overdue and Today stay inline. This Week, Later, and Recently Done collapse into submenus, each ending in an Obsidian search link for the full list.
- Hovering a task reveals **Mark Done**, **Start**, **Schedule…** (Due Tomorrow, Due in 7 Days, Snooze 1 Week — snoozes land on a weekday), and **More…** (Cancel Task, Ignore All Tasks in This Note).
- Actions write markers into the note: done appends `✅ 2026-08-11`, start `⏳`, cancel `❌`, snooze `🛫 2026-08-18`.
- **Stalled Review** appears at the top when a task has sat 8+ days past due (or 15+ past scheduled). Its submenu pushes you to finish, rewrite, or cancel; kicking the can is still allowed, but only through an explicit **Defer Anyway…**.
- Clicking a task opens it in Obsidian. Saving any note refreshes the menu about 2 seconds later via the file watcher; `🔄 Refresh` exists for impatience.

## Configuration

Vault path resolution order: `hs.settings.get('obsidianTodos.vaultPath')`, then the environment variables `OBSIDIAN_TODOS_VAULT` / `OBSIDIAN_VAULT_PATH` / `OBSIDIAN_VAULT_ROOT`, then the default iCloud vault.

Tweakables at the top of `obsidian-todos.lua`:

- `menubarTitle` — the all-clear icon (default `☑︎`)
- `menuLimits` — tasks shown per section
- `debounceDelay` — seconds between a file change and the rescan
- `vaultName` — override the vault name used in `obsidian://` links

## Limitations

- macOS with Hammerspoon only; this is a script, not a standalone app.
- Watches one vault at a time.
- Only checkbox lines are tasks: no recurring tasks, and it's a menu, not a notifier — nothing pops up when a task comes due.
- Scans skip `Archive/`, `Templates/`, `.obsidian/`, and `.trash/`. Notes with `obsidian-todos-ignore: true` in their frontmatter are excluded entirely.

## Troubleshooting

- **Menu says vault missing** — check `hs.settings.get('obsidianTodos.vaultPath')` in the Hammerspoon Console.
- **A task doesn't show up** — the line must start with a markdown checkbox, and `rg` must exist (`which rg`).
- **Menu feels stale** — use `🔄 Refresh`; if that fixes it, the watcher is likely blocked by missing Full Disk Access.

## Development

Everything lives in `obsidian-todos.lua`; `make lint` runs luacheck. Core helpers: `scanVault` (ripgrep + parsing), `buildMenu` / `updateMenu` (sections and badge), and the `markTask*` family (guarded single-line edits).

The demo GIF was recorded against a synthetic vault: `demo/seed-vault.sh` seeds it with dates relative to today, so the recording can be reproduced any day.

Issues and pull requests welcome. MIT license.
