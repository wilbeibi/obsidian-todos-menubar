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
    menuLimits = { overdue = 15, today = 15, thisWeek = 10, others = 10 }
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
local fileMtimeCache = {}

-- Parse a single task from ripgrep output
local function parseTask(filePath, lineNumber, taskText)
    local fileName = filePath:match("([^/]+)%.md$") or filePath:match("([^/]+)$")
    
    -- Simple text extraction - remove checkbox part
    local cleanText = taskText
    cleanText = cleanText:gsub("-%s*%[%s*%]", "") -- Remove [ ]
    cleanText = cleanText:gsub("-%s*%[/%]", "") -- Remove [/]
    cleanText = cleanText:gsub("-%s*%[%-%]", "") -- Remove [-]
    cleanText = cleanText:gsub("-%s*%[[xX]%]", "") -- Remove [x]
    cleanText = cleanText:match("^%s*(.-)%s*$") -- Trim whitespace

    -- Convert relative path to absolute path
    local absolutePath = filePath
    if filePath:match("^%./") then
        absolutePath = config.vaultPath .. "/" .. filePath:sub(3) -- Remove "./" prefix
    end

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

    -- Cache file modification times
    if fileMtimeCache[absolutePath] == nil then
        local mattr = hs and hs.fs and hs.fs.attributes(absolutePath)
        fileMtimeCache[absolutePath] = mattr and mattr.modification or 0
    end
    task.mtime = fileMtimeCache[absolutePath]
    
    -- Parse due date from various formats
    local dateStr = task.text:match("📅%s*(%d%d%d%d%-%d%d%-%d%d)") or
                  task.text:match("due::%s*%[%[(%d%d%d%d%-%d%d%-%d%d)%]%]") or
                  task.text:match("due:%s*(%d%d%d%d%-%d%d%-%d%d)") or
                  task.text:match("@due%((%d%d%d%d%-%d%d%-%d%d)%)")
    
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
    
    -- 1) Urgency (highest weight: 10000 points per urgency level)
    score = score + (5 - task.urgency) * 10000
    
    -- 2) Priority (second highest weight: 1000 points per priority level)
    score = score + (6 - task.priority) * 1000
    
    -- 3) Recency + Due date (third weight: 100 points)
    local recencyScore = 0
    if task.mtime > 0 then
        local now = os.time()
        local daysSinceModified = (now - task.mtime) / (24 * 60 * 60)
        recencyScore = math.max(0, 100 - daysSinceModified)
    end
    
    local dueDateScore = 0
    if task.dueDate then
        local now = os.time()
        local daysUntilDue = (task.dueDate - now) / (24 * 60 * 60)
        if daysUntilDue < 0 then
            dueDateScore = 100 + math.abs(daysUntilDue) -- Overdue bonus
        else
            dueDateScore = math.max(0, 100 - daysUntilDue)
        end
    end
    
    score = score + (recencyScore + dueDateScore) * 1
    
    -- 4) Line number (lowest weight: 0.01 points per line)
    score = score + (1000 - task.line) * 0.01
    
    return score
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
        local cmd = "cd '" .. config.vaultPath .. "' && " .. rgPath .. " --no-heading --with-filename --line-number " ..
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
    
    -- Count tasks for the current week (overdue, today, this week)
    local weekCount = 0
    for _, task in ipairs(cachedTasks) do
        if task.status ~= 'x' and (task.urgency == 1 or task.urgency == 2 or task.urgency == 3) then
            weekCount = weekCount + 1
        end
    end
    
    -- Badge shows this week's task count
    local badge = ""
    if weekCount > 0 then
        badge = " " .. weekCount
    end
    
    menubar:setTitle(config.menubarTitle .. badge)
    
    print("Refreshed - found " .. #cachedTasks .. " tasks (" .. weekCount .. " this week)")
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
            hs.execute('open "' .. config.vaultPath .. '"')
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
        
        -- Keep menu items readable on small screens
        if #displayText > 45 then
            displayText = displayText:sub(1, 42) .. "..."
        end
        
        -- Visual priority indicator
        local priorityEmojis = {[1] = "🔺", [2] = "⏫", [3] = "🔼", [4] = "🔽", [5] = "⏬"}
        local priorityEmoji = priorityEmojis[task.priority] or ""
        
        -- Add in-progress indicator (cancelled tasks are not shown)
        local statusEmoji = ""
        if task.status == "/" then
            statusEmoji = "⏳ "
        elseif task.status == "x" then
            statusEmoji = "✅ "
        end
        
        table.insert(menu, {
            title = "   " .. statusEmoji .. priorityEmoji .. " " .. displayText .. " (" .. task.file .. ")",
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
    local filePath = task.path
    local file = io.open(filePath, "r")
    if not file then
        print("Error: Could not open file to snooze task: " .. filePath)
        return
    end

    local targetDate = os.date("%Y-%m-%d", os.time() + 7 * 24 * 60 * 60)
    local lines = {}
    local lineNum = 1

    for line in file:lines() do
        if lineNum == task.line then
            local newLine = line
            local tmp, count = newLine:gsub("🛫%s*%d%d%d%d%-%d%d%-%d%d", "🛫 " .. targetDate)
            if count == 0 then
                newLine = newLine .. " 🛫 " .. targetDate
            else
                newLine = tmp
            end
            table.insert(lines, newLine)
        else
            table.insert(lines, line)
        end
        lineNum = lineNum + 1
    end
    file:close()

    file = io.open(filePath, "w")
    if not file then
        print("Error: Could not write to file: " .. filePath)
        return
    end
    for _, l in ipairs(lines) do file:write(l .. "\n") end
    file:close()

    hs.timer.doAfter(0.5, function()
        lastScanTime = 0
        obsidianTodos.updateMenu()
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

-- Open task in Obsidian with fallback chain
function obsidianTodos.openTaskInObsidian(task)
    local vaultName = getVaultName()
    local fileName = task.file:gsub("%.md$", "") -- Remove .md extension for URIs
    
    -- Try URI schemes in order of preference
    local uris = {
        string.format("obsidian://open?vault=%s&file=%s", 
                     hs.http.encodeForQuery(vaultName), 
                     hs.http.encodeForQuery(fileName)),
        string.format("obsidian://advanced-uri?vault=%s&filepath=%s&line=%d",
                     hs.http.encodeForQuery(vaultName),
                     hs.http.encodeForQuery(task.file),
                     task.line),
        string.format("obsidian://open?vault=%s", hs.http.encodeForQuery(vaultName))
    }
    
    for _, uri in ipairs(uris) do
        if hs.urlevent.openURL(uri) then
            return
        end
    end
    
    -- Final fallback: direct file open
    hs.execute('open -a "Obsidian" "' .. task.path .. '"')
end

-- Helper to update a task status (done, in progress, cancelled)
local function updateTaskStatus(task, bracket, emoji)
    local filePath = task.path
    local file = io.open(filePath, "r")
    if not file then
        print("Error: Could not open file to update task status: " .. filePath)
        return
    end
    local lines = {}
    local lineNum = 1
    for line in file:lines() do
        if lineNum == task.line then
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
            table.insert(lines, newText)
        else
            table.insert(lines, line)
        end
        lineNum = lineNum + 1
    end
    file:close()

    file = io.open(filePath, "w")
    if not file then
        print("Error: Could not write to file: " .. filePath)
        return
    end
    for _, l in ipairs(lines) do file:write(l .. "\n") end
    file:close()

    -- Refresh the menu after a short delay
    hs.timer.doAfter(0.5, function()
        lastScanTime = 0
        obsidianTodos.updateMenu()
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

-- Helper to set or update a task's due date by day offset
local function setTaskDueByOffset(task, daysOffset)
    local filePath = task.path
    local file = io.open(filePath, "r")
    if not file then
        print("Error: Could not open file to set due date: " .. filePath)
        return
    end

    local targetDate = os.date("%Y-%m-%d", os.time() + daysOffset * 24 * 60 * 60)
    local lines = {}
    local lineNum = 1

    for line in file:lines() do
        if lineNum == task.line then
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

            table.insert(lines, newLine)
        else
            table.insert(lines, line)
        end
        lineNum = lineNum + 1
    end
    file:close()

    file = io.open(filePath, "w")
    if not file then
        print("Error: Could not write to file: " .. filePath)
        return
    end
    for _, l in ipairs(lines) do file:write(l .. "\n") end
    file:close()

    -- Refresh the menu after a short delay
    hs.timer.doAfter(0.5, function()
        lastScanTime = 0
        obsidianTodos.updateMenu()
    end)
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
        local function isIgnored(p)
            return p:find("/%.obsidian/") or p:find("/Archive/") or p:find("/Templates/") or p:find("/%.trash/")
        end

        local shouldRefresh = false
        if type(paths) == "table" then
            for _, p in ipairs(paths) do
                if not isIgnored(p) then
                    shouldRefresh = true
                    break
                end
            end
        else
            shouldRefresh = not isIgnored(paths or "")
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
