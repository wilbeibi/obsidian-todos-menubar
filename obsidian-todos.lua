-- Obsidian TODOs Menubar
-- A Hammerspoon menubar menu over the checkbox tasks in an Obsidian vault.
--
-- - One ripgrep scan per refresh, driven by a debounced file watcher
-- - Weighted sorting by urgency, priority, recency, and line number
-- - Due date parsing (📅 YYYY-MM-DD, due:: [[YYYY-MM-DD]], etc.)
-- - Priority levels from emoji indicators (🔺⏫🔼🔽⏬)
-- - Rows render the way Obsidian renders them; the note keeps the raw markers
-- - Click to open in Obsidian, submenu to mark done
-- - Stalled Review submenu and deliberate defer flow for long-neglected tasks
-- - No polling loop, no popup alerts
--
-- Installation:
-- 1. Ensure ripgrep is installed: brew install ripgrep
-- 2. Add to ~/.hammerspoon/init.lua: require('obsidian-todos')
-- 3. Reload Hammerspoon config
--
-- Repository: https://github.com/wilbeibi/obsidian-todos-menubar
-- License: MIT

local obsidianTodos = {}
local utf8 = utf8

-- Safe shell quoting for single-arg usage (e.g., paths)
local function shQuote(s)
    if type(s) ~= 'string' then return "''" end
    -- Wrap in single quotes and escape internal single quotes: ' -> '\''
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Resolve the vault path with overrides in this order:
-- 1) hs.settings.get('obsidianTodos.vaultPath')
-- 2) Environment variables OBSIDIAN_TODOS_VAULT, OBSIDIAN_VAULT_PATH, or OBSIDIAN_VAULT_ROOT
-- 3) Default iCloud Obsidian path
local function resolveVaultPath()
    local defaultPath = (os.getenv("HOME") or "")
        .. "/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault"

    local settingsPath = nil
    if hs and hs.settings and type(hs.settings.get) == "function" then
        settingsPath = hs.settings.get('obsidianTodos.vaultPath')
    end

    local envPath = os.getenv('OBSIDIAN_TODOS_VAULT')
        or os.getenv('OBSIDIAN_VAULT_PATH')
        or os.getenv('OBSIDIAN_VAULT_ROOT')
    local path = settingsPath or envPath or defaultPath

    -- Expand ~ if present
    if type(path) == 'string' and path:sub(1,1) == '~' then
        path = (os.getenv('HOME') or '') .. path:sub(2)
    end

    return path
end

local config = {
    vaultPath = resolveVaultPath(),
    vaultName = nil, -- Override auto-detection if needed
    menubarTitle = "☑︎",
    debounceDelay = 2,
    menuLimits = { overdue = 5, today = 5, thisWeek = 5, others = 6, donePreview = 3, stalled = 5 }
}

local IGNORE_FRONTMATTER_KEY = "obsidian-todos-ignore"

-- Check whether the configured vault path exists and is a directory
local function vaultPathExists()
    local attr = hs and hs.fs and hs.fs.attributes(config.vaultPath)
    return attr and attr.mode == 'directory'
end

-- State persists across refreshes to avoid redundant work
local menubar = nil
local watcher = nil
local cachedTasks = {}
local rgPath = nil
-- mtime cache removed to avoid stale recency sorting after edits

-- Hammerspoon's io.popen runs with a bare PATH (/usr/bin:/bin:/usr/sbin:/sbin),
-- so a package-manager rg is never on it. Probe absolute candidates directly --
-- macOS `which` only searches PATH by basename and always fails on an absolute
-- argument, so testing candidates with it silently matched nothing.
local function resolveRipgrepPath()
    local home = os.getenv("HOME") or ""
    local candidates = {
        "/opt/homebrew/bin/rg",
        "/usr/local/bin/rg",
        home .. "/.cargo/bin/rg",
        home .. "/.local/bin/rg",
    }
    for _, path in ipairs(candidates) do
        if hs.fs.attributes(path, "mode") == "file" then return path end
    end

    -- Fall back to whatever PATH the process did inherit
    local handle = io.popen("command -v rg 2>/dev/null")
    if handle then
        local result = handle:read("*a"):gsub("%s+$", "")
        handle:close()
        if result ~= "" then return result end
    end
    return nil
end

-- Shared small utilities
local function refreshSoon(delaySec)
    hs.timer.doAfter(delaySec or 0.3, function()
        obsidianTodos.updateMenu()
    end)
end

-- Constant mapping for rendering
local PRIORITY_EMOJIS = {[1] = "🔺", [2] = "⏫", [3] = "🔼", [4] = "🔽", [5] = "⏬"}

-- Tasks-plugin date markers, stripped from menu rows. Iterated one at a time
-- rather than collected into a character class -- see displayLabel.
local TASK_DATE_MARKERS = {"📅", "⏳", "🛫", "✅", "❌", "➕", "🔁"}

-- Stalled thresholds, in full days elapsed after the (end-of-day) date passed:
-- a task due 8 days ago has 7 full days elapsed, scheduled 15 days ago has 14.
local STALLED_DUE_DAYS = 7        -- due 8+ days ago
local STALLED_SCHEDULED_DAYS = 14 -- scheduled 15+ days ago

-- Match a YYYY-MM-DD date in any of the supported task-format styles
local function extractDate(text, emoji, keyword)
    return text:match(emoji .. "%s*(%d%d%d%d%-%d%d%-%d%d)")
        or text:match(keyword .. "::%s*%[%[(%d%d%d%d%-%d%d%-%d%d)%]%]")
        or text:match(keyword .. ":%s*(%d%d%d%d%-%d%d%-%d%d)")
        or text:match("@" .. keyword .. "%((%d%d%d%d%-%d%d%-%d%d)%)")
end

-- Convert YYYY-MM-DD to end-of-day epoch, or nil if input is nil/malformed
local function toEpoch(dateStr)
    if not dateStr then return nil end
    local y, m, d = dateStr:match("(%d%d%d%d)-(%d%d)-(%d%d)")
    if not y then return nil end
    return os.time({year=y, month=m, day=d, hour=23, min=59, sec=59})
end

-- Strip the leading checkbox marker (`- [ ]`, `- [x]`, `- [/]`) and surrounding
-- whitespace, yielding the bare task text. Shared by the scanner and the
-- stale-line guard so both agree on what "the same task" means.
local function stripCheckbox(text)
    local t = text or ""
    t = t:gsub("-%s*%[%s*%]", "")    -- [ ]
    t = t:gsub("-%s*%[/%]", "")       -- [/]
    t = t:gsub("-%s*%[[xX]%]", "")    -- [x]
    return t:match("^%s*(.-)%s*$")
end

-- Rewrite a single line of a file via transformFn.
-- When expectedText is provided, the target line is mutated only if its bare
-- task text still matches what we captured at scan time. Returns:
--   true            on success
--   false, "stale"  if the line moved/changed since the scan (no write)
--   false, "io"     on a read/write failure
local function updateSingleLine(filePath, lineNumber, transformFn, expectedText)
    local file = io.open(filePath, "r")
    if not file then
        print("Error: Could not open file: " .. tostring(filePath))
        return false, "io"
    end
    local lines = {}
    local ln = 1
    local found = false
    for line in file:lines() do
        if ln == lineNumber then
            found = true
            -- Guard against stale line numbers: the file may have changed since
            -- the scan that produced task.line. Refuse to edit a line that no
            -- longer holds the task we captured, rather than clobber whatever
            -- shifted into its place.
            if expectedText ~= nil and stripCheckbox(line) ~= expectedText then
                file:close()
                return false, "stale"
            end
            local ok, newLine = pcall(transformFn, line)
            if not ok then
                newLine = line
            end
            table.insert(lines, newLine)
        else
            table.insert(lines, line)
        end
        ln = ln + 1
    end
    file:close()

    -- Line number ran past the end of the file: also stale.
    if expectedText ~= nil and not found then
        return false, "stale"
    end

    file = io.open(filePath, "w")
    if not file then
        print("Error: Could not write to file: " .. tostring(filePath))
        return false, "io"
    end
    for _, l in ipairs(lines) do file:write(l .. "\n") end
    file:close()
    return true
end

-- Apply a single-line edit to a task's source line, guarding against stale
-- line numbers and refreshing the menu immediately afterward. Centralizes the
-- "edit, verify, refresh, give feedback" pattern shared by every task action.
local function applyLineEdit(task, transformFn)
    local ok, reason = updateSingleLine(task.path, task.line, transformFn, task.text)
    if ok then
        refreshSoon()
    elseif reason == "stale" then
        if hs and hs.alert then
            hs.alert.show("⚠️ Task changed on disk — refreshing")
        end
        refreshSoon()  -- resync the menu with the file's current state
    end
    return ok
end

local function isIgnoredPath(p)
    return p:find("/%.obsidian/") or p:find("/Archive/") or p:find("/Templates/") or p:find("/%.trash/")
end

local function findIgnoredNotes()
    local ignored = {}
    local cmdParts = {
        "cd " .. shQuote(config.vaultPath),
        "&&",
        rgPath,
        "--no-config",
        "--files-with-matches",
        "--glob '*.md'",
        "--glob '!Archive/**'",
        "--glob '!.obsidian/**'",
        "--glob '!Templates/**'",
        "--glob '!.trash/**'",
        "'^\\s*obsidian-todos-ignore:\\s*[\\x27\\x22]?true[\\x27\\x22]?\\s*$'",
        ".",
        "2>/dev/null"
    }
    local handle = io.popen(table.concat(cmdParts, " "))
    if not handle then return ignored end

    for line in handle:lines() do
        local rel = line
        if rel:sub(1, 2) == "./" then rel = rel:sub(3) end
        local abs = rel
        if rel:sub(1, 1) ~= "/" then
            abs = (config.vaultPath or "") .. "/" .. rel
        end
        ignored[abs] = true
    end
    handle:close()
    return ignored
end

local function setIgnoredTodosFrontmatter(filePath)
    local file = io.open(filePath, "r")
    if not file then
        print("Error: Could not open file: " .. tostring(filePath))
        return false
    end

    local lines = {}
    for line in file:lines() do
        table.insert(lines, line)
    end
    file:close()

    local propertyLine = IGNORE_FRONTMATTER_KEY .. ": true"
    if lines[1] == "---" then
        local closingLine = nil
        local propertyLineNumber = nil
        for i = 2, #lines do
            if lines[i] == "---" or lines[i] == "..." then
                closingLine = i
                break
            end
            if lines[i]:match("^%s*obsidian%-todos%-ignore%s*:") then
                propertyLineNumber = i
                break
            end
        end

        if propertyLineNumber then
            lines[propertyLineNumber] = propertyLine
        elseif closingLine then
            table.insert(lines, closingLine, propertyLine)
        else
            print("Error: Could not update malformed frontmatter in file: " .. tostring(filePath))
            return false
        end
    else
        table.insert(lines, 1, "---")
        table.insert(lines, 2, propertyLine)
        table.insert(lines, 3, "---")
    end

    file = io.open(filePath, "w")
    if not file then
        print("Error: Could not write to file: " .. tostring(filePath))
        return false
    end
    for _, line in ipairs(lines) do
        file:write(line .. "\n")
    end
    file:close()
    return true
end


-- Parse a single task from ripgrep output
local function parseTask(filePath, lineNumber, taskText)
    -- Normalize vault-relative and absolute paths
    local vaultPath = config.vaultPath or ''
    local relPath = filePath
    if relPath:sub(1, 2) == './' then
        relPath = relPath:sub(3)
    elseif relPath:sub(1,1) == '/' then
        local prefix = vaultPath .. '/'
        if relPath:sub(1, #prefix) == prefix then
            relPath = relPath:sub(#prefix + 1)
        end
    end

    local absolutePath = relPath
    if relPath:sub(1,1) ~= '/' then
        absolutePath = (vaultPath ~= '' and (vaultPath .. '/' .. relPath)) or relPath
    end

    local fileName = relPath:match("([^/]+)%.md$") or relPath:match("([^/]+)$")

    -- Bare task text without the checkbox prefix (see stripCheckbox)
    local cleanText = stripCheckbox(taskText)

    -- Status detection ([-] cancelled is never fetched by rg, so omitted)
    local status = " "
    if taskText:find("%[/%]") then
        status = "/"
    elseif taskText:find("%[[xX]%]") then
        status = "x"
    end

    local task = {
        path = absolutePath,
        relativePath = relPath,
        file = fileName,
        line = lineNumber,
        text = cleanText,
        status = status,
        dueDate = nil,
        snoozeUntil = nil,
        scheduledDate = nil,
        stalled = false,
        priority = 5,
        urgency = 99,
        mtime = 0,
        completedAt = 0
    }

    -- Read file modification time fresh to avoid stale cache
    local mattr = hs and hs.fs and hs.fs.attributes(absolutePath)
    task.mtime = mattr and mattr.modification or 0

    -- Parse due date (with bare-date fallback when "due"/📅 is mentioned)
    local dueStr = extractDate(task.text, "📅", "due")
    if not dueStr and (task.text:find("[Dd]ue") or task.text:find("📅")) then
        dueStr = task.text:match("(%d%d%d%d%-%d%d%-%d%d)")
    end
    task.dueDate = toEpoch(dueStr)
    task.snoozeUntil = toEpoch(task.text:match("🛫%s*(%d%d%d%d%-%d%d%-%d%d)"))
    task.scheduledDate = toEpoch(extractDate(task.text, "⏳", "scheduled"))

    -- Parse priority from emoji indicators
    for priority, emoji in pairs(PRIORITY_EMOJIS) do
        if task.text:find(emoji) then
            task.priority = priority
            break
        end
    end

    -- Urgency from due date
    if task.dueDate then
        local now = os.time()
        local today = os.date("%Y-%m-%d")
        local taskDay = os.date("%Y-%m-%d", task.dueDate)
        local t = os.date("*t")
        t.hour, t.min, t.sec = 23, 59, 59
        local oneWeekFromEndOfToday = os.time(t) + 7 * 86400

        if task.dueDate < now then
            task.urgency = 1 -- Overdue
        elseif taskDay == today then
            task.urgency = 2 -- Today
        elseif task.dueDate <= oneWeekFromEndOfToday then
            task.urgency = 3 -- This week
        else
            task.urgency = 4 -- Later
        end
    end

    -- Urgency from scheduled date (only when no due date pinned one already)
    if not task.dueDate and task.scheduledDate then
        local diffDays = math.floor((task.scheduledDate - os.time()) / 86400)
        if diffDays <= 0 then
            if diffDays >= -1 then task.urgency = 2
            elseif diffDays >= -3 then task.urgency = 3
            else task.urgency = 4 end
        elseif diffDays <= 1 then
            task.urgency = 3
        elseif diffDays <= 7 then
            task.urgency = 4
        end
    end

    -- Stalled: open/in-progress tasks whose visible dates show prolonged
    -- neglect. Derived entirely from dates already on the line — undated
    -- tasks are never stalled because their real age is unknowable here.
    if status ~= "x" then
        local nowEpoch = os.time()
        if task.dueDate
            and math.floor((nowEpoch - task.dueDate) / 86400) >= STALLED_DUE_DAYS then
            task.stalled = true
        elseif task.scheduledDate
            and math.floor((nowEpoch - task.scheduledDate) / 86400) >= STALLED_SCHEDULED_DAYS then
            task.stalled = true
        end
    end

    -- Completion timestamp (falls back to file mtime)
    if status == "x" then
        task.completedAt = toEpoch(extractDate(task.text, "✅", "done")) or task.mtime
    end

    return task
end

-- Calculate weighted score for task sorting
local function calculateWeightedScore(task)
    local score = 0
    local now = os.time()

    -- bucket: Overdue(1) > Today(2) > ThisWeek(3) > Later(4) > None(5)
    score = score + (6 - math.min(task.urgency or 5, 5)) * 1000

    -- priority: 1..5
    score = score + (6 - (task.priority or 5)) * 100

    -- tie: time-to-due (closer is higher), clipped to 30 days; overdue gets a small nudge but not crazy
    local tieDue = 0
    if task.dueDate then
        local days = math.floor((task.dueDate - now) / 86400)
        if days < 0 then
            tieDue = 40 + math.min(10, math.abs(days))
        else
            tieDue = 40 - math.min(30, days)
        end
    end

    -- scheduled marker: reward tasks scheduled recently (or imminently)
    local scheduledBoost = 0
    if task.scheduledDate then
        local diffDays = math.floor((now - task.scheduledDate) / 86400)
        if diffDays >= 0 then
            if diffDays <= 1 then
                scheduledBoost = 70
            elseif diffDays <= 3 then
                scheduledBoost = 55
            elseif diffDays <= 7 then
                scheduledBoost = 40
            elseif diffDays <= 14 then
                scheduledBoost = 20
            else
                scheduledBoost = 10
            end
        else
            local daysAhead = math.abs(diffDays)
            if daysAhead <= 1 then
                scheduledBoost = 35
            elseif daysAhead <= 3 then
                scheduledBoost = 25
            elseif daysAhead <= 7 then
                scheduledBoost = 15
            else
                scheduledBoost = 5
            end
        end
        if task.dueDate then
            scheduledBoost = scheduledBoost * 0.4
        end
    end

    -- soft recency: only last 7 days matter
    local recency = 0
    if task.mtime and task.mtime > 0 then
        local days = math.floor((now - task.mtime) / 86400)
        recency = math.max(0, 7 - math.min(7, days))
    end

    -- tiny preference for earlier lines (stable within a note)
    local line = 1000 - (task.line or 1000)

    return score + tieDue + scheduledBoost + recency + (line * 0.01)
end

local function buildHoverTooltip(overdueCnt, todayCnt, thisWeekCnt)
    local lines = {}
    if overdueCnt > 0 then
        table.insert(lines, "Overdue: " .. tostring(overdueCnt))
    end
    if todayCnt > 0 then
        table.insert(lines, "Today: " .. tostring(todayCnt))
    end
    if thisWeekCnt > 0 then
        table.insert(lines, "This Week: " .. tostring(thisWeekCnt))
    end
    return table.concat(lines, "\n")
end

function obsidianTodos.scanVault()
    if not rgPath then
        print("Error: ripgrep (rg) not found. Install with: brew install ripgrep")
        return {}
    end

    local tasks = {}
    local now = os.time()
    local ignoredNotes = findIgnoredNotes()

    -- One pass over the vault: open `[ ]`, in-progress `[/]`, and done `[x]/[X]`
    -- checkboxes in a single character class. Cancelled `[-]` is intentionally
    -- excluded so it never reaches the menu.
    --
    -- --no-config on every rg call: a user-level ripgreprc is written for
    -- terminal use and may set --max-columns, which truncates matched lines
    -- and appends a literal "[... omitted end of long line]" marker. That
    -- mangled text lands in task.text, so the stale-line guard in
    -- applyLineEdit sees a permanent mismatch and refuses every edit on
    -- long (notably CJK, 3 bytes/char) tasks.
    local pattern = "'^\\s*-\\s*\\[[ xX/]\\]\\s*.+'"
    local cmdParts = {
        "cd " .. shQuote(config.vaultPath),
        "&&",
        rgPath,
        "--no-config",
        "--no-heading",
        "--with-filename",
        "--line-number",
        "--glob '!Archive/**'",
        "--glob '!.obsidian/**'",
        "--glob '!Templates/**'",
        "--glob '!.trash/**'",
        pattern,
        ".",
        "2>/dev/null"
    }

    local handle = io.popen(table.concat(cmdParts, " "))
    if handle then
        for line in handle:lines() do
            local filePath, lineNumber, taskText = line:match("^([^:]+):(%d+):(.+)$")
            if filePath and lineNumber and taskText then
                local task = parseTask(filePath, tonumber(lineNumber), taskText)
                -- Hide tasks snoozed into the future or in ignored notes
                if not ignoredNotes[task.path]
                    and not (task.snoozeUntil and task.snoozeUntil > now) then
                    table.insert(tasks, task)
                end
            end
        end
        handle:close()
    end

    -- Sort by weighted score (higher score = higher priority)
    table.sort(tasks, function(a, b)
        return calculateWeightedScore(a) > calculateWeightedScore(b)
    end)

    return tasks
end

function obsidianTodos.updateMenu()
    cachedTasks = obsidianTodos.scanVault()

    local overdueCnt, todayCnt, thisWeekCnt, backlogCnt = 0, 0, 0, 0
    for _, t in ipairs(cachedTasks) do
        if t.status ~= 'x' then
            if t.urgency == 1 then
                overdueCnt = overdueCnt + 1
            elseif t.urgency == 2 then
                todayCnt = todayCnt + 1
            elseif t.urgency == 3 then
                thisWeekCnt = thisWeekCnt + 1
            else
                backlogCnt = backlogCnt + 1
            end
        end
    end

    -- Tiered display: the glyph and count of the most urgent non-empty tier.
    -- The glyph is what makes the item identifiable as this app at a glance; a
    -- bare number in the menubar reads as a stray digit.
    local title
    if overdueCnt > 0 then
        title = "⚠️ " .. tostring(overdueCnt)
    elseif todayCnt > 0 then
        title = "🔔 " .. tostring(todayCnt)
    elseif thisWeekCnt > 0 then
        title = "📆 " .. tostring(thisWeekCnt)
    elseif backlogCnt > 0 then
        title = "📋 " .. tostring(backlogCnt)
    else
        title = config.menubarTitle  -- All done
    end

    menubar:setTitle(title)

    if menubar.setTooltip then
        menubar:setTooltip(buildHoverTooltip(overdueCnt, todayCnt, thisWeekCnt))
    end

end

-- Build menu structure
local function buildObsidianSearchItem(title, query)
    return {
        title = title,
        fn = function() obsidianTodos.openSearchInObsidian(query) end
    }
end

function obsidianTodos.buildMenu()
    local menu = {}

    if #cachedTasks == 0 then
        table.insert(menu, {title = "No pending tasks found!", disabled = true})
    else
        -- Separate buckets prevent overdue tasks from getting buried
        local overdue, today, thisWeek, others, doneTasks = {}, {}, {}, {}, {}
        local stalled = {}

        for _, task in ipairs(cachedTasks) do
            if task.status == 'x' then
                table.insert(doneTasks, task)
            elseif task.stalled then
                table.insert(stalled, task)
            elseif task.urgency == 1 then
                table.insert(overdue, task)
            elseif task.urgency == 2 then
                table.insert(today, task)
            elseif task.urgency == 3 then
                table.insert(thisWeek, task)
            else
                table.insert(others, task)
            end
        end


        -- Keep stalled work in one review surface so it does not inflate the
        -- visible workload by appearing again in its urgency bucket.
        if #stalled > 0 then
            obsidianTodos.addStalledReview(menu, stalled)
        end

        -- Only immediate work stays inline. Longer-horizon and history views
        -- remain one level away so the top-level menu stays glanceable.
        local sections = {
            { tasks = overdue, title = "Overdue", limit = config.menuLimits.overdue },
            { tasks = today, title = "Today", limit = config.menuLimits.today }
        }

        for _, section in ipairs(sections) do
            local tasks = section.tasks
            if #tasks > 0 then
                obsidianTodos.addMenuSection(
                    menu,
                    section.title .. " (" .. #tasks .. ")",
                    tasks,
                    section.limit
                )
            end
        end

        if #thisWeek > 0 then
            table.insert(menu, {
                title = "This Week (" .. #thisWeek .. ")",
                menu = obsidianTodos.buildTaskSubmenu(
                    thisWeek,
                    config.menuLimits.thisWeek,
                    buildObsidianSearchItem("Open All Pending Tasks in Obsidian", "task-todo:/./")
                )
            })
        end

        if #others > 0 then
            table.insert(menu, {
                title = "Later (" .. #others .. ")",
                menu = obsidianTodos.buildTaskSubmenu(
                    others,
                    config.menuLimits.others,
                    buildObsidianSearchItem("Open All Pending Tasks in Obsidian", "task-todo:/./")
                )
            })
        end

        -- Completion history belongs in Obsidian; keep only a short reassurance
        -- strip here and provide a single escape route to the full result set.
        if #doneTasks > 0 then
            table.sort(doneTasks, function(a, b)
                return (a.completedAt or 0) > (b.completedAt or 0)
            end)
            table.insert(menu, {
                title = "Recently Done",
                menu = obsidianTodos.buildTaskSubmenu(
                    doneTasks,
                    config.menuLimits.donePreview,
                    buildObsidianSearchItem("Open Completed Tasks in Obsidian", "task-done:/./")
                )
            })
        end
    end

    -- Action items
    table.insert(menu, { title = "-" })

    -- The modifiers are otherwise invisible: nothing on a row hints that the
    -- submenu can be skipped. State them once, quietly.
    table.insert(menu, {
        title = hs.styledtext.new("   Click to open  ·  ⌥ done  ·  ⌘ tomorrow", {
            color = {list = "System", name = "secondaryLabelColor"},
            font = {name = ".AppleSystemUIFont", size = 11}
        }),
        disabled = true
    })

    table.insert(menu, {
        title = "Refresh (" .. #cachedTasks .. " tasks)",
        fn = function()
            obsidianTodos.updateMenu()
        end
    })

    table.insert(menu, {
        title = "Open Vault Folder",
        fn = function()
            hs.execute('open ' .. shQuote(config.vaultPath))
        end
    })


    return menu
end

local function buildScheduleMenu(task)
    return {
        { title = "Due Tomorrow", fn = function() obsidianTodos.markTaskDueTomorrow(task) end },
        { title = "Due in 7 Days", fn = function() obsidianTodos.markTaskDueIn7Days(task) end },
        { title = "Snooze 1 Week", fn = function() obsidianTodos.markTaskSnoozeOneWeek(task) end }
    }
end

local function buildTaskActionMenu(task)
    if task.status == "x" then return nil end

    if task.stalled then
        return {
            { title = "Mark Done", fn = function() obsidianTodos.markTaskDone(task) end },
            { title = "Open to Rewrite", fn = function() obsidianTodos.openTaskInObsidian(task) end },
            { title = "Cancel Task", fn = function() obsidianTodos.markTaskCancelled(task) end },
            { title = "Defer Anyway…", menu = buildScheduleMenu(task) },
            {
                title = "More…",
                menu = {
                    {
                        title = "Ignore All Tasks in This Note",
                        fn = function() obsidianTodos.ignoreTodosInNote(task) end
                    }
                }
            }
        }
    end

    local actions = {
        { title = "Mark Done", fn = function() obsidianTodos.markTaskDone(task) end }
    }
    if task.status ~= "/" then
        table.insert(actions, {
            title = "Start",
            fn = function() obsidianTodos.markTaskInProgress(task) end
        })
    end
    table.insert(actions, { title = "Schedule…", menu = buildScheduleMenu(task) })
    table.insert(actions, {
        title = "More…",
        menu = {
            { title = "Cancel Task", fn = function() obsidianTodos.markTaskCancelled(task) end },
            {
                title = "Ignore All Tasks in This Note",
                fn = function() obsidianTodos.ignoreTodosInNote(task) end
            }
        }
    })
    return actions
end

-- Strip the Tasks-plugin metadata that belongs in the note but only adds noise
-- in a menu: the date markers and their dates, priority glyphs, and the
-- Dataview/TaskPaper spellings of the same fields. task.text keeps the raw line
-- (edits match against it); this is display only.
local function displayLabel(task)
    local text = task.text or ""

    for _, emoji in pairs(PRIORITY_EMOJIS) do
        text = text:gsub(emoji, "")
    end
    -- Marker + date pairs: due, scheduled, start, done, cancelled, created,
    -- recurrence. These must be matched one full sequence at a time: a Lua
    -- character class is a set of BYTES, so `[📅⏳…]` would also match the
    -- continuation bytes it shares with ordinary CJK characters (试 is
    -- E8 AF 95, and 95 is a byte of ➕) and shred them into invalid UTF-8.
    for _, marker in ipairs(TASK_DATE_MARKERS) do
        text = text:gsub(marker .. "%s*%d%d%d%d%-%d%d%-%d%d", "")
        text = text:gsub(marker, "")
    end
    -- Dataview inline fields and TaskPaper tags for the same dates
    text = text:gsub("%f[%w]%a+::%s*%[%[%d%d%d%d%-%d%d%-%d%d%]%]", "")
    text = text:gsub("%f[%w]%a+::%s*%d%d%d%d%-%d%d%-%d%d", "")
    text = text:gsub("@%a+%(%d%d%d%d%-%d%d%-%d%d%)", "")
    -- Links render as their label in Obsidian; do the same here rather than
    -- spending the row's width on a URL.
    text = text:gsub("%[%[([^%]|]*)|([^%]]*)%]%]", "%2")
    text = text:gsub("%[%[([^%]]*)%]%]", "%1")
    text = text:gsub("!?%[([^%]]*)%]%b()", "%1")
    -- Bare URLs keep the host only
    text = text:gsub("https?://([^%s/]+)%S*", "%1")

    text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

    -- Truncate on codepoint boundaries: head 26 + ellipsis + tail 16.
    -- Byte-slicing here would split multibyte chars and emit invalid UTF-8
    -- into the menu title.
    local len = utf8.len(text)
    if len and len > 45 then
        local headEnd = (utf8.offset(text, 27) or (#text + 1)) - 1
        local tailStart = utf8.offset(text, -16) or 1
        text = text:sub(1, headEnd) .. "…" .. text:sub(tailStart)
    end

    return text
end

-- The date a row is filed under, written the way a person would say it.
-- Year only when it is not the current one.
local function displayDate(task)
    local epoch = task.dueDate or task.scheduledDate
    if not epoch then return nil end

    local day = os.date("*t", epoch)
    local now = os.date("*t")
    local function midnight(t)
        return os.time({year = t.year, month = t.month, day = t.day, hour = 12})
    end
    local diffDays = math.floor((midnight(day) - midnight(now)) / 86400 + 0.5)

    if diffDays == 0 then return "today" end
    if diffDays == 1 then return "tomorrow" end
    if diffDays == -1 then return "yesterday" end
    -- Lua rejects strftime's %-d, so drop the padding zero here instead
    local monthDay = os.date("%b ", epoch) .. tostring(day.day)
    if day.year == now.year then return monthDay end
    return monthDay .. ", " .. tostring(day.year)
end

-- Daily and weekly notes are named after the period they cover, so a task
-- captured in the note for its own due date trails two spellings of one date:
-- "· Aug 10 · 2026-08-10 Mon". Recognise only that case. A note whose name
-- carries a title beyond the date, or whose period does not contain the date
-- ("· Aug 19 · 2026-07-20 Mon" — due next week, captured a month ago), is
-- telling you something the date cannot.
local function noteRestatesDate(file, epoch)
    if not file or not epoch then return false end

    local y, m, d = file:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)%s*%a*$")
    if y then
        return os.date("%Y-%m-%d", epoch) == y .. "-" .. m .. "-" .. d
    end
    -- ISO week, matched with %G/%V so a week spanning New Year still lines up
    local wy, wk = file:match("^(%d%d%d%d)%-W(%d%d)$")
    if wy then
        return os.date("%G-W%V", epoch) == wy .. "-W" .. wk
    end
    return false
end

-- Add a section of tasks to menu
local function buildTaskMenuItem(task)
    -- One marker, only where it changes what you do next: high priority.
    local marker = (task.priority and task.priority <= 2) and "! " or ""

    local parts = {}
    local dateLabel = displayDate(task)
    if dateLabel then parts[#parts + 1] = dateLabel end
    local noteLabel = task.file
    if noteLabel and noteLabel ~= ""
        and not (dateLabel and noteRestatesDate(noteLabel, task.dueDate or task.scheduledDate)) then
        parts[#parts + 1] = noteLabel
    end

    local title = "   " .. marker .. displayLabel(task)
    if #parts > 0 then
        title = title .. "  ·  " .. table.concat(parts, "  ·  ")
    end

    -- In-progress rows read as secondary text rather than carrying a glyph.
    if task.status == "/" then
        title = hs.styledtext.new(title, {
            color = {list = "System", name = "secondaryLabelColor"},
            font = {name = ".AppleSystemUIFont", size = 14}
        })
    end

    -- Reaching the submenu means steering the cursor the full width of the menu
    -- while staying inside one ~20pt row, and that cost is linear in the
    -- distance travelled rather than logarithmic like an ordinary click. The
    -- modifiers exist to skip that trip. hs.menubar passes the held modifiers
    -- as fn's first argument.
    --
    -- The bare click stays on open-the-note, the one action here that changes
    -- nothing: a stray click that files a task as done is expensive to notice
    -- and expensive to undo, so the writes are the ones that need a modifier.
    -- Completed rows have no actions at all (buildTaskActionMenu returns nil
    -- for them), so every gesture on them opens the note.
    local item = {
        title = title,
        fn = function(mods)
            mods = mods or {}
            if task.status == "x" then
                obsidianTodos.openTaskInObsidian(task)
            elseif mods.alt then
                obsidianTodos.markTaskDone(task)
            elseif mods.cmd then
                obsidianTodos.markTaskDueTomorrow(task)
            else
                obsidianTodos.openTaskInObsidian(task)
            end
        end
    }
    item.menu = buildTaskActionMenu(task)
    return item
end

function obsidianTodos.buildTaskSubmenu(tasks, maxShow, trailingItem)
    local items = {}
    local limit = math.min(#tasks, maxShow or #tasks)
    for i = 1, limit do
        table.insert(items, buildTaskMenuItem(tasks[i]))
    end
    if trailingItem then
        table.insert(items, { title = "-" })
        table.insert(items, trailingItem)
    end
    return items
end

-- Stalled Review: a single collapsed line above the urgency buckets, so the
-- review stays discoverable without crowding today's actionable items on
-- every menu open. Oldest dates first, capped to keep the review glanceable.
function obsidianTodos.addStalledReview(menu, stalledTasks)
    table.sort(stalledTasks, function(a, b)
        return (a.dueDate or a.scheduledDate or 0) < (b.dueDate or b.scheduledDate or 0)
    end)

    local items = {}
    local limit = math.min(#stalledTasks, config.menuLimits.stalled)
    for i = 1, limit do
        table.insert(items, buildTaskMenuItem(stalledTasks[i]))
    end
    if #stalledTasks > limit then
        table.insert(items, { title = "-" })
        table.insert(items, buildObsidianSearchItem(
            "Open All Pending Tasks in Obsidian",
            "task-todo:/./"
        ))
    end

    table.insert(menu, { title = "Stalled Review (" .. #stalledTasks .. ")", menu = items })
    table.insert(menu, { title = "-" })
end

function obsidianTodos.addMenuSection(menu, title, tasks, maxShow)
    table.insert(menu, { title = title, disabled = true })

    local limit = math.min(#tasks, maxShow or #tasks)
    for i = 1, limit do
        table.insert(menu, buildTaskMenuItem(tasks[i]))
    end

    if #tasks > limit then
        table.insert(menu, buildObsidianSearchItem(
            "   Open All Pending Tasks in Obsidian",
            "task-todo:/./"
        ))
    end

    table.insert(menu, { title = "-" })
end

-- Snooze a task by adding/updating 🛫 YYYY-MM-DD (7 days out)
function obsidianTodos.markTaskSnoozeOneWeek(task)
    local t = os.time() + 7 * 86400
    local dow = tonumber(os.date("%w", t))
    if dow == 0 then
        t = t + 1 * 86400
    elseif dow == 6 then
        t = t + 2 * 86400
    end
    local targetDate = os.date("%Y-%m-%d", t)
    applyLineEdit(task, function(line)
        local tmp, count = line:gsub("🛫%s*%d%d%d%d%-%d%d%-%d%d", "🛫 " .. targetDate)
        if count == 0 then
            return line .. " 🛫 " .. targetDate
        end
        return tmp
    end)
end

-- Get vault name from config or auto-detect from path
local function getVaultName()
    if config.vaultName then
        return config.vaultName
    end

    if config.vaultPath:match("iCloud~md~obsidian") then
        return config.vaultPath:match("Documents/([^/]+)$") or "Vault"
    end

    return config.vaultPath:match("([^/]+)$") or "Vault"
end

function obsidianTodos.openSearchInObsidian(query)
    local q = function(s) return hs.http.encodeForQuery(s or "") end
    local uri = string.format(
        "obsidian://search?vault=%s&query=%s",
        q(getVaultName()),
        q(query)
    )
    hs.urlevent.openURL(uri)
end

-- Detect if the Advanced URI plugin is installed in this vault
local function hasAdvancedURIPlugin()
    local pluginPath = (config.vaultPath or "") .. "/.obsidian/plugins/obsidian-advanced-uri"
    local attr = hs and hs.fs and hs.fs.attributes(pluginPath)
    return attr and attr.mode == 'directory'
end

-- Open task in Obsidian with fallback chain
function obsidianTodos.openTaskInObsidian(task)
    local q = function(s) return hs.http.encodeForQuery(s or "") end
    local vaultName = getVaultName()
    local relPath = task.relativePath or task.file -- prefer vault-relative path with extension

    -- Prefer basic Obsidian URI unless Advanced URI plugin is present
    if hasAdvancedURIPlugin() then
        local adv = string.format(
            "obsidian://advanced-uri?vault=%s&filepath=%s&line=%d",
            q(vaultName), q(relPath), tonumber(task.line) or 1
        )
        if hs.urlevent.openURL(adv) then return end
    end

    local basic = string.format("obsidian://open?vault=%s&file=%s", q(vaultName), q(relPath))
    if hs.urlevent.openURL(basic) then return end

    hs.execute('open -a "Obsidian" ' .. shQuote(task.path))
end

-- Helper to update a task status (done, in progress, cancelled)
local function updateTaskStatus(task, bracket, emoji)
    applyLineEdit(task, function(line)
        -- Replace the first checkbox at line start regardless of current status
        local pattern = "^(%s*%-%s*)%b[]"
        local newText, count = line:gsub(pattern, "%1[" .. bracket .. "]", 1)
        if count == 0 then
            -- Fallback: replace any bracket occurrence
            newText = line:gsub("%b[]", "[" .. bracket .. "]", 1)
        end
        if not newText:find(emoji, 1, true) then
            newText = newText .. " " .. emoji .. " " .. os.date("%Y-%m-%d")
        end
        return newText
    end)
end

-- Mark a task as done by rewriting the file
function obsidianTodos.markTaskDone(task)
    updateTaskStatus(task, "x", "✅")
end

-- Mark a task as In Progress by rewriting the file
function obsidianTodos.markTaskInProgress(task)
    updateTaskStatus(task, "/", "⏳")
end

-- Mark a task as Cancelled by rewriting the file
function obsidianTodos.markTaskCancelled(task)
    updateTaskStatus(task, "-", "❌")
end

function obsidianTodos.ignoreTodosInNote(task)
    if setIgnoredTodosFrontmatter(task.path) then
        refreshSoon()
    end
end

-- Helper to set or update a task's due date by day offset
local function setTaskDueByOffset(task, daysOffset)
    local targetDate = os.date("%Y-%m-%d", os.time() + daysOffset * 24 * 60 * 60)
    applyLineEdit(task, function(line)
        local newLine = line
        local replaced = false

        -- Replace common due date formats while preserving style
        local patterns = {
            {pat = "📅%s*%d%d%d%d%-%d%d%-%d%d", rep = "📅 " .. targetDate},
            {pat = "due::%s*%[%[%d%d%d%d%-%d%d%-%d%d%]%]", rep = "due:: [[" .. targetDate .. "]]"},
            {pat = "due:%s*%d%d%d%d%-%d%d%-%d%d", rep = "due: " .. targetDate},
            {pat = "@due%(%d%d%d%d%-%d%d%-%d%d%)", rep = "@due(" .. targetDate .. ")"}
        }

        for _, p in ipairs(patterns) do
            local tmp, count = newLine:gsub(p.pat, p.rep)
            if count > 0 then
                newLine = tmp
                replaced = true
            end
        end

        if not replaced then
            -- Append a due date if none was present
            newLine = newLine .. " 📅 " .. targetDate
        end

        return newLine
    end)
end

-- Set or update a task's due date to tomorrow
function obsidianTodos.markTaskDueTomorrow(task)
    setTaskDueByOffset(task, 1)
end

-- Set or update a task's due date to 7 days from now
function obsidianTodos.markTaskDueIn7Days(task)
    setTaskDueByOffset(task, 7)
end

-- Initialize the application
function obsidianTodos.init()
    menubar = hs.menubar.new()
    if not menubar then
        print("Failed to create Obsidian TODOs menubar")
        return
    end

    -- Validate vault path before wiring the watcher
    if not vaultPathExists() then
        print("[Obsidian TODOs] vaultPath does not exist: " .. tostring(config.vaultPath))
        print(
            "Configure via: hs.settings.set('obsidianTodos.vaultPath','/absolute/path/to/YourVault'); "
            .. "hs.reload()"
        )

        menubar:setTitle(config.menubarTitle .. " !")
        menubar:setMenu({
            { title = "Vault path not found", disabled = true },
            { title = tostring(config.vaultPath), disabled = true },
            { title = "-" },
            { title = "Set with hs.settings in Console", disabled = true },
            { title = "hs.settings.set('obsidianTodos.vaultPath', '/path')", disabled = true },
            { title = "-" },
            { title = "Reload", fn = function() hs.reload() end }
        })
        return
    end

    rgPath = resolveRipgrepPath()
    if not rgPath then
        print("[Obsidian TODOs] ripgrep (rg) not found. Install with: brew install ripgrep")
    end

    -- Build menu on-demand to avoid closing an open menu during refresh
    menubar:setMenu(function()
        return obsidianTodos.buildMenu()
    end)

    -- File watcher eliminates polling overhead
    watcher = hs.pathwatcher.new(config.vaultPath, function(paths)
        local sawMarkdown = false

        local function considerPath(p)
            if type(p) ~= "string" or p == "" then return end
            local path = p
            if path:sub(1, 1) ~= "/" and config.vaultPath and config.vaultPath ~= "" then
                path = config.vaultPath .. "/" .. path
            end
            if isIgnoredPath(path) then return end
            if path:lower():match("%.md$") then
                sawMarkdown = true
            end
        end

        if type(paths) == "table" then
            for _, p in ipairs(paths) do considerPath(p) end
        else
            considerPath(paths)
        end

        if sawMarkdown then
            refreshSoon(config.debounceDelay)
        end
    end):start()

    -- Populate menu immediately on load
    obsidianTodos.updateMenu()

end

-- Prevent resource leaks on reload
function obsidianTodos.cleanup()
    if watcher then
        watcher:stop()
        watcher = nil
    end
    if menubar then
        menubar:delete()
        menubar = nil
    end
end

-- Start immediately when loaded
obsidianTodos.init()

-- Module pattern allows clean require() usage
return obsidianTodos
