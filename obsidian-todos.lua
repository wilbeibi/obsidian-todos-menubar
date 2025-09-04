-- Obsidian TODOs Menubar v1.1.0
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

local config = {
    vaultPath = os.getenv("HOME") .. "/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault",
    vaultName = nil, -- Override auto-detection if needed
    menubarTitle = "☑︎",
    debounceDelay = 2,
    menuLimits = { overdue = 15, today = 15, thisWeek = 10, others = 10 }
}

-- State persists across refreshes to avoid redundant work
local menubar = nil
local watcher = nil
local cachedTasks = {}
local lastScanTime = 0
local fileMtimeCache = {}

-- Parse a single task from ripgrep output
local function parseTask(filePath, lineNumber, taskText)
    local fileName = filePath:match("([^/]+)%.md$") or filePath:match("([^/]+)$")
    local cleanText = taskText:match("-%s*%[%s*%]%s*(.*)") or taskText
    cleanText = cleanText:match("^%s*(.-)%s*$") -- Trim whitespace

    -- Convert relative path to absolute path
    local absolutePath = filePath
    if filePath:match("^%./") then
        absolutePath = config.vaultPath .. "/" .. filePath:sub(3) -- Remove "./" prefix
    end

    local task = {
        path = absolutePath,
        file = fileName,
        line = lineNumber,
        text = cleanText,
        dueDate = nil,
        priority = 5,
        urgency = 99,
        mtime = 0
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
        local taskDay = os.date("%Y-%m-%d", task.dueDate)
        local oneWeekFromNow = now + (7 * 24 * 60 * 60)
        
        if task.dueDate < now then
            task.urgency = 1 -- Overdue
        elseif taskDay == today then
            task.urgency = 2 -- Today
        elseif task.dueDate <= oneWeekFromNow then
            task.urgency = 3 -- This week
        else
            task.urgency = 4 -- Later
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
    
    local cmd = "cd '" .. config.vaultPath .. "' && " .. rgPath .. " --no-heading --with-filename --line-number " ..
                "--glob '!Archive/**' --glob '!.obsidian/**' --glob '!Templates/**' --glob '!.trash/**' " ..
                "'^\\s*-\\s*\\[\\s*\\]\\s*.+' . 2>/dev/null"
    
    local handle = io.popen(cmd)
    if not handle then
        print("Error: Could not execute ripgrep")
        return {}
    end
    
    local tasks = {}
    for line in handle:lines() do
        local filePath, lineNumber, taskText = line:match("^([^:]+):(%d+):(.+)$")
        if filePath and lineNumber and taskText then
            table.insert(tasks, parseTask(filePath, tonumber(lineNumber), taskText))
        end
    end
    handle:close()
    
    -- Sort by weighted score (higher score = higher priority)
    table.sort(tasks, function(a, b)
        return calculateWeightedScore(a) > calculateWeightedScore(b)
    end)
    
    return tasks
end

function obsidianTodos.updateMenu()
    cachedTasks = obsidianTodos.scanVault()
    
    -- Badge shows urgent count: users need to know what can't wait
    local overdueCount = 0
    local todayCount = 0
    for _, task in ipairs(cachedTasks) do
        if task.urgency == 1 then overdueCount = overdueCount + 1 end
        if task.urgency == 2 then todayCount = todayCount + 1 end
    end
    
    -- Urgent tasks get priority in badge to create urgency awareness
    local badge = ""
    if (overdueCount + todayCount) > 0 then
        badge = " " .. (overdueCount + todayCount)
    elseif #cachedTasks > 0 then
        badge = " " .. #cachedTasks
    end
    
    menubar:setTitle(config.menubarTitle .. badge)
    menubar:setMenu(obsidianTodos.buildMenu())
    
    print("Refreshed - found " .. #cachedTasks .. " tasks")
end

-- Build menu structure
function obsidianTodos.buildMenu()
    local menu = {}
    
    if #cachedTasks == 0 then
        table.insert(menu, {title = "No pending tasks found!", disabled = true})
    else
        -- Separate buckets prevent overdue tasks from getting buried
        local overdue, today, thisWeek, others = {}, {}, {}, {}
        
        for _, task in ipairs(cachedTasks) do
            if task.urgency == 1 then
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
        
        table.insert(menu, {
            title = "   " .. priorityEmoji .. " " .. displayText .. " (" .. task.file .. ")",
            fn = function()
                obsidianTodos.openTaskInObsidian(task)
            end,
            menu = {
                {
                    title = "Mark as Done",
                    fn = function() obsidianTodos.markTaskDone(task) end
                },
                {
                    title = "Copy Task Text",
                    fn = function()
                        hs.pasteboard.setContents(task.text)
                        print("Task text copied to clipboard")
                    end
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

-- Mark a task as done by rewriting the file
function obsidianTodos.markTaskDone(task)
    local filePath = task.path
    local file = io.open(filePath, "r")
    if not file then
        print("Error: Could not open file to mark task done: " .. filePath)
        return
    end

    local lines = {}
    local lineNum = 1
    for line in file:lines() do
        if lineNum == task.line then
            -- Preserve original line format while marking done
            local doneText = line:gsub("%[ %]", "[x]")
            -- Date stamp provides completion history
            if not doneText:find("✅") then
                 doneText = doneText .. " ✅ " .. os.date("%Y-%m-%d")
            end
            table.insert(lines, doneText)
        else
            table.insert(lines, line)
        end
        lineNum = lineNum + 1
    end
    file:close()

    -- Atomic write would be better but adds complexity
    file = io.open(filePath, "w")
    if not file then
        print("Error: Could not write to file to mark task done: " .. filePath)
        return
    end

    for _, line in ipairs(lines) do
        file:write(line .. "\n")
    end
    file:close()

    print("Task marked as done: " .. task.text)

    -- Delay allows file watcher to catch change naturally
    hs.timer.doAfter(0.5, function()
        lastScanTime = 0
        obsidianTodos.updateMenu()
    end)
end

-- Initialize the application
function obsidianTodos.init()
    menubar = hs.menubar.new()
    if not menubar then
        print("Failed to create Obsidian TODOs menubar")
        return
    end
    
    -- File watcher eliminates polling overhead
    watcher = hs.pathwatcher.new(config.vaultPath, function()
        print("File change detected, refreshing...")
        -- Batch rapid saves into single refresh
        hs.timer.doAfter(config.debounceDelay, function()
            lastScanTime = 0
            obsidianTodos.updateMenu()
        end)
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
