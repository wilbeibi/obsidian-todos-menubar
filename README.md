# Obsidian TODOs Menubar

A fast, lightweight macOS menubar app for Hammerspoon that displays your Obsidian tasks with due dates and priorities. Click tasks to open them in Obsidian, or use the submenu to mark them done directly from the menubar.

## Features

- **⚡ Fast ripgrep scanning** - Single-pass vault scanning with built-in ignore patterns
- **📅 Smart due date parsing** - Supports multiple formats (`📅 2024-03-15`, `due:: [[2024-03-15]]`, etc.)
- **🔺 Priority recognition** - Visual priority levels with emoji indicators  
- **📊 Smart grouping** - Tasks organized by Overdue, Today, This Week, Others
- **🕒 Recent-first ordering** - Within each group, newer tasks appear first
- **🎯 Direct interaction** - Click to open in Obsidian, submenu to mark done
- **⚡ Instant updates** - File watcher triggers immediate menubar refresh
- **🔇 Quiet operation** - No popup alerts, console logging only

## Prerequisites

- **Hammerspoon** - Download from [hammerspoon.org](https://www.hammerspoon.org/)
- **ripgrep** - Install via Homebrew: `brew install ripgrep`

## Installation

### One-line install:
```bash
curl -L https://raw.githubusercontent.com/yourusername/obsidian-todos-menubar/main/obsidian-todos.lua -o ~/.hammerspoon/obsidian-todos.lua
```

### Manual install:
1. Download `obsidian-todos.lua` to your `~/.hammerspoon/` directory
2. Add this line to your `~/.hammerspoon/init.lua`:
   ```lua
   require('obsidian-todos')
   ```
3. Reload Hammerspoon config

## Usage

### Task Format
Write tasks in your Obsidian notes using standard markdown:

```markdown
- [ ] Basic task
- [ ] High priority task 🔺
- [ ] Task with due date 📅 2024-03-15
- [ ] Both priority and date ⏫ 📅 2024-03-15
- [ ] Dataview format due:: [[2024-03-15]]
```

### Menubar Interaction
- **Badge number**: Shows overdue + today's task count
- **Click task**: Opens the task in Obsidian
- **Hover over task**: Reveals submenu with "Mark as Done" and "Copy Text"
- **🔄 Refresh**: Manual refresh (auto-refresh via file watcher)
- **📂 Open Vault**: Opens vault folder in Finder

### Supported Due Date Formats
- `📅 YYYY-MM-DD`
- `due:: [[YYYY-MM-DD]]` (Dataview format)
- `due: YYYY-MM-DD`
- `@due(YYYY-MM-DD)`

### Priority Levels
- 🔺 Highest
- ⏫ High  
- 🔼 Medium
- 🔽 Low
- ⏬ Lowest

## Configuration

Edit the config section at the top of `obsidian-todos.lua`:

```lua
local config = {
    vaultPath = os.getenv("HOME") .. "/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault",
    menubarTitle = "☑︎",
    debounceDelay = 2, -- seconds to wait after file changes
    menuLimits = {
        overdue = 15,   -- items shown in Overdue
        today = 15,     -- items shown in Today
        thisWeek = 10,  -- items shown in This Week
        others = 10     -- items shown in Other Tasks
    }
}
```

### Auto-Detection
The script will automatically find your vault if it's in common locations:
- `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault` (iCloud)
- `~/Documents/Obsidian Vault`
- `~/Documents/Vault`

## Performance

- **Zero idle overhead** - Uses file watcher instead of periodic polling
- **Fast scanning** - ripgrep processes entire vault in milliseconds
- **Instant updates** - Changes appear in menubar immediately after saving
- **Minimal memory** - Small Lua tables, cleaned up automatically

## Troubleshooting

### Showing More Items
If you see "N more items" in a section, increase the limits in `menuLimits` in `obsidian-todos.lua` (e.g., set `overdue = 30`). Large values may make the menu tall.

### Tasks not appearing
1. Check vault path in config
2. Ensure tasks use format: `- [ ] Task text`
3. Verify ripgrep is installed: `which rg`

### File watcher not working
1. Check Hammerspoon has Full Disk Access in System Preferences
2. Verify vault path exists and is readable

### Advanced URI not working
Install the [Advanced URI](https://github.com/Vinzent03/obsidian-advanced-uri) plugin in Obsidian for best experience.

## Development

This is a single-file, self-contained Hammerspoon script. Core functions:

- `obsidianTodos.scanVault()` - ripgrep execution
- `obsidianTodos.parseTasks()` - date/priority parsing  
- `obsidianTodos.updateMenu()` - menubar refresh
- `obsidianTodos.markTaskDone()` - file editing

## License

MIT License - Feel free to modify and distribute.

## Contributing

Issues and pull requests welcome! This project follows Rob Pike's philosophy of simplicity and clarity.
