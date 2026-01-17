# Obsidian TODOs Menubar

[![Version](https://img.shields.io/badge/version-1.0-blue)](#)

A fast, lightweight macOS menubar app for Hammerspoon that keeps your Obsidian todos at your fingertips. Open notes with one click or update task status without leaving the menu.

## Quick Look

- Groups todos into Overdue, Today, This Week, and Later so you can focus on what matters
- Highlights priority emojis (`🔺⏫🔼🔽⏬`) and shows in-progress (`[/]`) or recently completed (`[x]`) tasks
- Parses due dates from common notations (`📅 2024-03-15`, `due:: [[2024-03-15]]`, `@due(2024-03-15)`, etc.)
- Menubar submenu lets you mark done, in progress, cancel, reschedule, or snooze tasks in place
- File watcher keeps the menu current moments after you save a note (no manual rescans needed)

## Setup

1. Install [Hammerspoon](https://www.hammerspoon.org/)
2. Install ripgrep: `brew install ripgrep`
3. (Optional) Install the [Advanced URI plugin](https://github.com/Vinzent03/obsidian-advanced-uri) in Obsidian for direct line links
4. Download the script:
   ```bash
   curl -L https://raw.githubusercontent.com/wilbeibi/obsidian-todos-menubar/main/obsidian-todos.lua -o ~/.hammerspoon/obsidian-todos.lua
   ```
5. Add to `~/.hammerspoon/init.lua`:
   ```lua
   require('obsidian-todos')
   ```
6. Reload Hammerspoon (Console → `hs.reload()`)

## Usage

### Task Format
Write tasks in your Obsidian notes using standard markdown checkboxes:

```markdown
- [ ] Basic task
- [/] In-progress task (shows ⏳ hourglass)
- [-] Cancelled task (hidden in menu)
- [ ] High priority task 🔺
- [ ] Task with due date 📅 2024-03-15
- [ ] Both priority and date ⏫ 📅 2024-03-15
- [ ] Dataview format due:: [[2024-03-15]]
- [/] In-progress with snooze 🛫 2024-03-20
```

### Menubar Interaction
- **Badge number**: Shows overdue + today's task count
- **Hover tooltip**: Shows non-zero counts for Overdue, Today, This Week
- **Click task**: Opens the task in Obsidian (Advanced URI plugin used automatically when available)
- **⏳ Hourglass icon**: Indicates in-progress tasks (`[/]`)
- **Hover over task**: Reveals submenu with actions:
  - ✅ Mark as Done (appends `✅ YYYY-MM-DD`)
  - ⏳ Mark In Progress
  - ❌ Mark Cancelled
  - 📆 Due Tomorrow (updates or appends due date)
  - 📆 Due in 7 Days (sets due date 7 days out)
  - 🛫 Snooze 1 Week (skips to the next weekday if the exact date is a weekend)
- **🔄 Refresh**: Manual refresh (auto-refresh via debounced file watcher)
- **📂 Open Vault**: Opens the vault folder in Finder
- **✅ Done (latest 2)**: Shows the two most recently completed tasks

A few reminders while you use it:

- Checkbox rows drive everything. Todos (`- [ ]`), in-progress (`- [/]`), done (`- [x]`), and cancelled (`- [-]`) are all recognised.
- The badge in the menubar shows one count: overdue first, then today, then pending. Submenus expose quick actions (done, in progress, cancel, due tomorrow, due in 7 days, snooze one week).
- Done tasks get `✅ YYYY-MM-DD` appended automatically.

## Configuration

If your vault isn't in the default iCloud location, point the script to it in the Hammerspoon Console:

```lua
hs.settings.set('obsidianTodos.vaultPath', '/absolute/path/to/YourVault')
hs.reload()
```

The script also honours the environment variables `OBSIDIAN_TODOS_VAULT` and `OBSIDIAN_VAULT_PATH`. Give Hammerspoon Full Disk Access so ripgrep can read the vault.

Other tweaks near the top of `obsidian-todos.lua`:

- `menubarTitle` — change the icon (default `☑︎`)
- `menuLimits` — how many tasks to show per section
- `debounceDelay` — delay before rescanning after file changes

## Troubleshooting

- **Menu says vault missing** — double-check the path set with `hs.settings.get('obsidianTodos.vaultPath')`.
- **Task not showing up** — confirm the line starts with a markdown checkbox and that ripgrep exists (`which rg`).
- **Menu feels stale** — use the `🔄 Refresh` item, then verify the watcher isn't blocked by missing Full Disk Access.

## Development

Everything lives in `obsidian-todos.lua`. Core helpers you might touch:

- `scanVault` — runs ripgrep and parses task metadata
- `updateMenu` / `buildMenu` — assemble sections and badge counts
- `markTask*` helpers — update checkboxes, due dates, or snooze markers in place

## License

MIT License - Feel free to modify and distribute.

## Contributing

Issues and pull requests welcome! This project follows Rob Pike's philosophy of simplicity and clarity.
