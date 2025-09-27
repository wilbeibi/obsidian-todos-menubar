-- Obsidian TODOs Menubar v1.0
-- A fast, lightweight macOS menubar app for Hammerspoon that displays your Obsidian tasks.
-- 
-- Features:
-- - Fast ripgrep scanning with file watcher for instant updates
-- - Weighted sorting by urgency, priority, recency, and line number
-- - Due date parsing (📅 YYYY-MM-DD, due:: [[YYYY-MM-DD]], etc.)
-- - Priority levels with emoji indicators (🔺⏫🔼🔽⏬)
-- - Click to open in Obsidian, submenu to mark done
-- - Zero idle overhead, no popup alerts
--
-- Installation:
-- 1. Ensure ripgrep is installed: brew install ripgrep
-- 2. Add to ~/.hammerspoon/init.lua: require('obsidian-todos')
-- 3. Reload Hammerspoon config
--
-- Repository: https://github.com/wilbeibi/obsidian-todos-menubar
-- License: MIT

local obsidianTodos = {}
local utf8 = _G.utf8 or require("utf8")

-- Safe shell quoting for single-arg usage (e.g., paths)
local function shQuote(s)
    if type(s) ~= 'string' then return "''" end
    -- Wrap in single quotes and escape internal single quotes: ' -> '\''
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Resolve the vault path with overrides in this order:
-- 1) hs.settings.get('obsidianTodos.vaultPath')
-- 2) Environment variables OBSIDIAN_TODOS_VAULT or OBSIDIAN_VAULT_PATH
-- 3) Default iCloud Obsidian path
local function resolveVaultPath()
    local defaultPath = (os.getenv("HOME") or "") .. "/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault"

    local settingsPath = nil
    if hs and hs.settings and type(hs.settings.get) == "function" then
        settingsPath = hs.settings.get('obsidianTodos.vaultPath')
    end

    local envPath = os.getenv('OBSIDIAN_TODOS_VAULT') or os.getenv('OBSIDIAN_VAULT_PATH')
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
    menuLimits = { overdue = 9, today = 9, thisWeek = 6, others = 6 }
}

-- Check whether the configured vault path exists and is a directory
local function vaultPathExists()
    local attr = hs and hs.fs and hs.fs.attributes(config.vaultPath)
    return attr and attr.mode == 'directory'
end

-- State persists across refreshes to avoid redundant work
local menubar = nil
local watcher = nil
local cachedTasks = {}
local lastScanTime = 0
-- mtime cache removed to avoid stale recency sorting after edits

-- Shared small utilities
local function refreshSoon(delaySec)
    hs.timer.doAfter(delaySec or 0.5, function()
        lastScanTime = 0
        obsidianTodos.updateMenu()
    end)
end

-- Constant mapping for rendering
local PRIORITY_EMOJIS = {[1] = "🔺", [2] = "⏫", [3] = "🔼", [4] = "🔽", [5] = "⏬"}

local function updateSingleLine(filePath, lineNumber, transformFn)
    local file = io.open(filePath, "r")
    if not file then
        print("Error: Could not open file: " .. tostring(filePath))
        return false
    end
    local lines = {}
    local ln = 1
    for line in file:lines() do
        if ln == lineNumber then
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

    file = io.open(filePath, "w")
    if not file then
        print("Error: Could not write to file: " .. tostring(filePath))
        return false
    end
    for _, l in ipairs(lines) do file:write(l .. "\n") end
    file:close()
    return true
end

local function isIgnoredPath(p)
    return p:find("/%.obsidian/") or p:find("/Archive/") or p:find("/Templates/") or p:find("/%.trash/")
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
    
    -- Simple text extraction - remove checkbox part
    local cleanText = taskText
    cleanText = cleanText:gsub("-%s*%[%s*%]", "") -- Remove [ ]
    cleanText = cleanText:gsub("-%s*%[/%]", "") -- Remove [/]
    cleanText = cleanText:gsub("-%s*%[%-%]", "") -- Remove [-]
    cleanText = cleanText:gsub("-%s*%[[xX]%]", "") -- Remove [x]
    cleanText = cleanText:match("^%s*(.-)%s*$") -- Trim whitespace

    -- Keep both absolute and vault-relative paths

    -- Simple status detection
    local status = " " -- default todo
    if taskText:find("%[/%]") then
        status = "/" -- in progress
    elseif taskText:find("%[%-%]") then
        status = "-" -- cancelled
    elseif taskText:find("%[[xX]%]") then
        status = "x" -- done
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
        priority = 5,
        urgency = 99,
        mtime = 0,
        completedAt = 0
    }

    -- Read file modification time fresh to avoid stale cache
    local mattr = hs and hs.fs and hs.fs.attributes(absolutePath)
    task.mtime = mattr and mattr.modification or 0
    
    -- Parse due date from various formats
    local dateStr = task.text:match("📅%s*(%d%d%d%d%-%d%d%-%d%d)") or
                  task.text:match("due::%s*%[%[(%d%d%d%d%-%d%d%-%d%d)%]%]") or
                  task.text:match("due:%s*(%d%d%d%d%-%d%d%-%d%d)") or
                  task.text:match("@due%((%d%d%d%d%-%d%d%-%d%d)%)")

    if not dateStr then
        if task.text:find("[Dd]ue") or task.text:find("📅") then
            dateStr = task.text:match("(%d%d%d%d%-%d%d%-%d%d)")
        end
    end

    if dateStr then
        local y, m, d = dateStr:match("(%d%d%d%d)-(%d%d)-(%d%d)")
        if y and m and d then
            task.dueDate = os.time({year=y, month=m, day=d, hour=23, min=59, sec=59})
        end
    end

    -- Parse snooze until date (🛫 YYYY-MM-DD)
    local snoozeStr = task.text:match("🛫%s*(%d%d%d%d%-%d%d%-%d%d)")
    if snoozeStr then
        local y, m, d = snoozeStr:match("(%d%d%d%d)-(%d%d)-(%d%d)")
        if y and m and d then
            task.snoozeUntil = os.time({year=y, month=m, day=d, hour=23, min=59, sec=59})
        end
    end
    
    -- Parse priority from emoji indicators
    local priorityMap = {["🔺"] = 1, ["⏫"] = 2, ["🔼"] = 3, ["🔽"] = 4, ["⏬"] = 5}
    for emoji, priority in pairs(priorityMap) do
        if task.text:find(emoji) then
            task.priority = priority
            break
        end
    end
    
    -- Calculate urgency based on due date
    if task.dueDate then
        local now = os.time()
        local today = os.date("%Y-%m-%d")
        local tomorrow = os.date("%Y-%m-%d", now + 24 * 60 * 60)
        local taskDay = os.date("%Y-%m-%d", task.dueDate)
        -- Calculate one week from end of today to include full 7 days
        local oneWeekFromEndOfToday = os.time({year=os.date("%Y"), month=os.date("%m"), day=os.date("%d"), hour=23, min=59, sec=59}) + (7 * 24 * 60 * 60)
        
        if task.dueDate < now then
            task.urgency = 1 -- Overdue
        elseif taskDay == today then
            task.urgency = 2 -- Today
        elseif taskDay == tomorrow then
            task.urgency = 3 -- Tomorrow
        elseif task.dueDate <= oneWeekFromEndOfToday then
            task.urgency = 3 -- This week
        else
            task.urgency = 4 -- Later
        end
        
    end
    
    -- Parse completion date if marked done
    if status == "x" then
        local doneStr = task.text:match("✅%s*(%d%d%d%d%-%d%d%-%d%d)") or
                        task.text:match("done::%s*%[%[(%d%d%d%d%-%d%d%-%d%d)%]%]") or
                        task.text:match("done:%s*(%d%d%d%d%-%d%d%-%d%d)") or
                        task.text:match("@done%((%d%d%d%d%-%d%d%-%d%d)%)")
        if doneStr then
            local y, m, d = doneStr:match("(%d%d%d%d)-(%d%d)-(%d%d)")
            if y and m and d then
                task.completedAt = os.time({year=y, month=m, day=d, hour=23, min=59, sec=59})
            end
        end
        if task.completedAt == 0 then
            task.completedAt = task.mtime
        end
    end
    
    return task
end

-- Calculate weighted score for task sorting
local function calculateWeightedScore(task)
    local score = 0

    -- bucket: Overdue(1) > Today(2) > ThisWeek(3) > Later(4) > None(5)
    score = score + (6 - math.min(task.urgency or 5, 5)) * 1000

    -- priority: 1..5
    score = score + (6 - (task.priority or 5)) * 100

    -- tie: time-to-due (closer is higher), clipped to 30 days; overdue gets a small nudge but not crazy
    local tieDue = 0
    if task.dueDate then
        local days = math.floor((task.dueDate - os.time()) / 86400)
        if days < 0 then
            tieDue = 40 + math.min(10, math.abs(days))
        else
            tieDue = 40 - math.min(30, days)
        end
    end

    -- soft recency: only last 7 days matter
    local recency = 0
    if task.mtime and task.mtime > 0 then
        local days = math.floor((os.time() - task.mtime) / 86400)
        recency = math.max(0, 7 - math.min(7, days))
    end

    -- tiny preference for earlier lines (stable within a note)
    local line = 1000 - (task.line or 1000)

    return score + tieDue + recency + (line * 0.01)
end

function obsidianTodos.scanVault()
    -- Find ripgrep executable - try multiple common locations
    local rgPath = nil
    local possiblePaths = {"/opt/homebrew/bin/rg", "/usr/local/bin/rg", "rg"}
    
    for _, path in ipairs(possiblePaths) do
        local handle = io.popen("which " .. path .. " 2>/dev/null")
        if handle then
            local result = handle:read("*a"):gsub("\n", "")
            handle:close()
            if result ~= "" then
                rgPath = path
                break
            end
        end
    end
    
    if not rgPath then
        print("Error: ripgrep (rg) not found. Install with: brew install ripgrep")
        return {}
    end
    
    local tasks = {}
    local now = os.time()
    
    -- Simple patterns for different task types we show
    -- Note: Cancelled tasks `[-]` are recognized but not displayed in the menu
    local patterns = {
        "'^\\s*-\\s*\\[\\s*\\]\\s*.+'",  -- [ ] todo
        "'^\\s*-\\s*\\[/\\]\\s*.+'",      -- [/] in-progress
        "'^\\s*-\\s*\\[[xX]\\]\\s*.+'"   -- [x] done
    }
    
    for _, pattern in ipairs(patterns) do
        local cmd = "cd " .. shQuote(config.vaultPath) .. " && " .. rgPath .. " --no-heading --with-filename --line-number " ..
                    "--glob '!Archive/**' --glob '!.obsidian/**' --glob '!Templates/**' --glob '!.trash/**' " ..
                    pattern .. " . 2>/dev/null"
        
        local handle = io.popen(cmd)
        if handle then
            for line in handle:lines() do
                local filePath, lineNumber, taskText = line:match("^([^:]+):(%d+):(.+)$")
                if filePath and lineNumber and taskText then
                    local task = parseTask(filePath, tonumber(lineNumber), taskText)
                    -- Hide tasks snoozed into the future
                    if not (task.snoozeUntil and task.snoozeUntil > now) then
                        table.insert(tasks, task)
                    end
                end
            end
            handle:close()
        end
    end
    
    -- Sort by weighted score (higher score = higher priority)
    table.sort(tasks, function(a, b)
        return calculateWeightedScore(a) > calculateWeightedScore(b)
    end)
    
    return tasks
end

function obsidianTodos.updateMenu()
    cachedTasks = obsidianTodos.scanVault()

    local overdueCnt, todayCnt = 0, 0
    for _, t in ipairs(cachedTasks) do
        if t.status ~= 'x' then
            if t.urgency == 1 then
                overdueCnt = overdueCnt + 1
            elseif t.urgency == 2 then
                todayCnt = todayCnt + 1
            end
        end
    end

    local badge = ""
    if overdueCnt > 0 or todayCnt > 0 then
        local parts = {}
        if overdueCnt > 0 then table.insert(parts, tostring(overdueCnt)) end
        if todayCnt > 0 then table.insert(parts, tostring(todayCnt)) end
        badge = " " .. table.concat(parts, "•")
    end

    menubar:setTitle(config.menubarTitle .. badge)

    print("Refreshed - found " .. #cachedTasks .. " tasks (" .. overdueCnt .. " overdue, " .. todayCnt .. " today)")
end

-- Build menu structure
function obsidianTodos.buildMenu()
    local menu = {}
    
    if #cachedTasks == 0 then
        table.insert(menu, {title = "No pending tasks found!", disabled = true})
    else
        -- Separate buckets prevent overdue tasks from getting buried
        local overdue, today, thisWeek, others, doneTasks = {}, {}, {}, {}, {}
        
        for _, task in ipairs(cachedTasks) do
            if task.status == 'x' then
                table.insert(doneTasks, task)
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
        
        
        -- Add sections in order of urgency
        local sections = {
            {overdue, "🚨 Overdue", config.menuLimits.overdue},
            {today, "📅 Today", config.menuLimits.today},
            {thisWeek, "📆 This Week", config.menuLimits.thisWeek},
            {others, "📋 Other Tasks", config.menuLimits.others}
        }
        
        for _, section in ipairs(sections) do
            local tasks, title, limit = section[1], section[2], section[3]
            if #tasks > 0 then
                obsidianTodos.addMenuSection(menu, title .. " (" .. #tasks .. ")", tasks, limit)
            end
        end

        -- Recently completed tasks (latest 2)
        if #doneTasks > 0 then
            table.sort(doneTasks, function(a, b)
                return (a.completedAt or 0) > (b.completedAt or 0)
            end)
            obsidianTodos.addMenuSection(menu, "✅ Done (latest 2)", doneTasks, 2)
        end
    end
    
    -- Action items
    table.insert(menu, { title = "-" })
    
    table.insert(menu, {
        title = "🔄 Refresh (" .. #cachedTasks .. " tasks)",
        fn = function()
            lastScanTime = 0 -- Bypass debounce for manual refresh
            obsidianTodos.updateMenu()
        end
    })
    
    table.insert(menu, {
        title = "📂 Open Vault Folder",
        fn = function()
            hs.execute('open ' .. shQuote(config.vaultPath))
        end
    })
    
    
    return menu
end

-- Add a section of tasks to menu
function obsidianTodos.addMenuSection(menu, title, tasks, maxShow)
    table.insert(menu, { title = title, disabled = true })
    
    for i = 1, math.min(#tasks, maxShow) do
        local task = tasks[i]
        local displayText = task.text
        if utf8.len(displayText or "") > 45 then
            displayText = displayText:sub(1, 26) .. "…" .. displayText:sub(-16)
        end

        local priorityEmoji = ""
        if task.priority and task.priority <= 2 then
            priorityEmoji = (PRIORITY_EMOJIS[task.priority] or "") .. " "
        end

        local context = task.file or ""
        local statusEmoji = (task.status == "/" and "⏳ ") or (task.status == "x" and "✅ ") or ""

        table.insert(menu, {
            title = "   " .. statusEmoji .. priorityEmoji .. displayText .. "  ·  " .. context,
            fn = function()
                obsidianTodos.openTaskInObsidian(task)
            end,
            menu = {
                {
                    title = "✅ Mark as Done",
                    fn = function() obsidianTodos.markTaskDone(task) end
                },
                {
                    title = "⏳ Mark In Progress",
                    fn = function() obsidianTodos.markTaskInProgress(task) end
                },
                {
                    title = "❌ Mark Cancelled",
                    fn = function() obsidianTodos.markTaskCancelled(task) end
                },
                {
                    title = "📆 Due Tomorrow",
                    fn = function() obsidianTodos.markTaskDueTomorrow(task) end
                },
                {
                    title = "📆 Due This Week",
                    fn = function() obsidianTodos.markTaskDueThisWeek(task) end
                },
                {
                    title = "🛫 Snooze 1 Week",
                    fn = function() obsidianTodos.markTaskSnoozeOneWeek(task) end
                }
            }
        })
    end
    
    -- Indicate hidden items so users know to check vault
    if #tasks > maxShow then
        table.insert(menu, { 
            title = "   ... " .. (#tasks - maxShow) .. " more items",
            disabled = true 
        })
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
    local ok = updateSingleLine(task.path, task.line, function(line)
        local newLine = line
        local tmp, count = newLine:gsub("🛫%s*%d%d%d%d%-%d%d%-%d%d", "🛫 " .. targetDate)
        if count == 0 then
            newLine = newLine .. " 🛫 " .. targetDate
        else
            newLine = tmp
        end
        return newLine
    end)
    if ok then
        hs.timer.doAfter(0.5, function()
            lastScanTime = 0
            obsidianTodos.updateMenu()
        end)
    end
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
    local ok = updateSingleLine(task.path, task.line, function(line)
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
    if ok then refreshSoon(0.5) end
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

-- Helper to set or update a task's due date by day offset
local function setTaskDueByOffset(task, daysOffset)
    local targetDate = os.date("%Y-%m-%d", os.time() + daysOffset * 24 * 60 * 60)
    local ok = updateSingleLine(task.path, task.line, function(line)
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
    if ok then refreshSoon(0.5) end
end

-- Set or update a task's due date to tomorrow
function obsidianTodos.markTaskDueTomorrow(task)
    setTaskDueByOffset(task, 1)
end

-- Set or update a task's due date to 7 days from now
function obsidianTodos.markTaskDueThisWeek(task)
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
        print("Configure via: hs.settings.set('obsidianTodos.vaultPath','/absolute/path/to/YourVault'); hs.reload()")

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

    -- Build menu on-demand to avoid closing an open menu during refresh
    menubar:setMenu(function()
        return obsidianTodos.buildMenu()
    end)
    
    -- File watcher eliminates polling overhead
    watcher = hs.pathwatcher.new(config.vaultPath, function(paths)
        -- Ignore changes in folders we don't scan to avoid needless refreshes
        local shouldRefresh = false
        if type(paths) == "table" then
            for _, p in ipairs(paths) do
                if not isIgnoredPath(p) then
                    shouldRefresh = true
                    break
                end
            end
        else
            shouldRefresh = not isIgnoredPath(paths or "")
        end

        if shouldRefresh then
            print("File change detected, refreshing...")
            -- Batch rapid saves into single refresh
            hs.timer.doAfter(config.debounceDelay, function()
                lastScanTime = 0
                obsidianTodos.updateMenu()
            end)
        end
    end):start()
    
    -- Populate menu immediately on load
    obsidianTodos.updateMenu()
    
    hs.timer.doAfter(2, function()
        print("Obsidian TODOs ready - " .. #cachedTasks .. " tasks loaded")
    end)
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
