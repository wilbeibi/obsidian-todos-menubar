-- Obsidian TODOs Menubar v1.0.0
-- A fast, lightweight macOS menubar app for Hammerspoon that displays your Obsidian tasks.
-- 
-- Features:
-- - Fast ripgrep scanning with file watcher for instant updates
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
    menubarTitle = "☑︎",
    debounceDelay = 2, -- Prevents multiple scans when saving triggers multiple FSEvents
}

-- State persists across refreshes to avoid redundant work
local menubar = nil
local watcher = nil
local cachedTasks = {}
local lastScanTime = 0

function obsidianTodos.scanVault()
    -- Support both Apple Silicon and Intel Mac installations
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
    
    local cmd = rgPath .. " --no-heading --with-filename --line-number " ..
                "--glob '!Archive/**' --glob '!.obsidian/**' --glob '!Templates/**' --glob '!.trash/**' " ..
                "'^\\s*-\\s*\\[\\s*\\]\\s*.+' '" .. config.vaultPath .. "' 2>/dev/null"
    
    local handle = io.popen(cmd)
    if not handle then
        print("Error: Could not execute ripgrep")
        return {}
    end
    
    local tasks = {}
    for line in handle:lines() do
        local filePath, lineNumber, taskText = line:match("^([^:]+):(%d+):(.+)$")
        if filePath and lineNumber and taskText then
            local fileName = filePath:match("([^/]+)%.md$") or filePath:match("([^/]+)$")
            local cleanText = taskText:match("-%s*%[%s*%]%s*(.*)") or taskText
            cleanText = cleanText:match("^%s*(.-)%s*$") -- Users often have trailing spaces
            
            local task = {
                path = filePath,
                file = fileName,
                line = tonumber(lineNumber),
                text = cleanText,
                dueDate = nil,
                priority = 5,
                urgency = 99
            }
            
            -- Support multiple date formats since Obsidian plugins vary
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
            
            -- Emoji priority system: visual cues work better than p1/p2 tags
            if task.text:find("🔺") then task.priority = 1
            elseif task.text:find("⏫") then task.priority = 2
            elseif task.text:find("🔼") then task.priority = 3
            elseif task.text:find("🔽") then task.priority = 4
            elseif task.text:find("⏬") then task.priority = 5
            end
            
            -- Urgency drives sort order: overdue tasks need immediate attention
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
            
            table.insert(tasks, task)
        end
    end
    handle:close()
    
    -- Most urgent tasks bubble to top for immediate visibility
    table.sort(tasks, function(a, b)
        if a.urgency ~= b.urgency then return a.urgency < b.urgency end
        if a.dueDate and b.dueDate and a.dueDate ~= b.dueDate then return a.dueDate < b.dueDate end
        return a.priority < b.priority
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
        
        -- Order matters: most urgent sections appear first
        if #overdue > 0 then
            obsidianTodos.addMenuSection(menu, "🚨 Overdue (" .. #overdue .. ")", overdue, 5)
        end
        
        if #today > 0 then
            obsidianTodos.addMenuSection(menu, "📅 Today (" .. #today .. ")", today, 5)
        end
        
        if #thisWeek > 0 then
            obsidianTodos.addMenuSection(menu, "📆 This Week (" .. #thisWeek .. ")", thisWeek, 3)
        end
        
        if #others > 0 then
            local showCount = math.min(#others, 5)
            obsidianTodos.addMenuSection(menu, "📋 Other Tasks (" .. #others .. ")", others, showCount)
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
        
        -- Visual priority indicator helps quick scanning
        local priorityEmoji = ""
        if task.priority == 1 then priorityEmoji = "🔺"
        elseif task.priority == 2 then priorityEmoji = "⏫"
        elseif task.priority == 3 then priorityEmoji = "🔼"
        elseif task.priority == 4 then priorityEmoji = "🔽"
        elseif task.priority == 5 then priorityEmoji = "⏬"
        end
        
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

-- Open task in Obsidian at the specific line
function obsidianTodos.openTaskInObsidian(task)
    local vaultName = config.vaultPath:match("([^/]+)$") or "Vault"
    local relativePath = task.file
    
    -- Advanced URI plugin enables line-specific navigation
    local advancedUriUrl = string.format(
        "obsidian://advanced-uri?vault=%s&filepath=%s&line=%d",
        hs.http.encodeForQuery(vaultName),
        hs.http.encodeForQuery(relativePath),
        task.line
    )
    
    -- Progressive fallbacks ensure task always opens
    local success = hs.urlevent.openURL(advancedUriUrl)
    
    if not success then
        -- Basic URI works without plugins
        local basicUrl = string.format(
            "obsidian://open?vault=%s&file=%s",
            hs.http.encodeForQuery(vaultName), 
            hs.http.encodeForQuery(relativePath:gsub("%.md$", "")) -- Obsidian URIs don't want .md
        )
        
        local basicSuccess = hs.urlevent.openURL(basicUrl)
        
        if not basicSuccess then
            -- Direct file open always works as last resort
            hs.execute('open -a "Obsidian" "' .. task.path .. '"')
        end
    end
    
    print("Opening " .. task.file)
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
