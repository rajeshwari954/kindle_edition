--[[
Daily reads: one tap downloads the morning editions built by the GitHub job.

Menu: Tools → Daily reads → Download today's reads
Files go to /mnt/us/documents/Daily reads/. Every edition is named
"YYYY-MM-DD Name.epub"; anything dated before the most recent Sunday is
deleted (with its KOReader progress folder) whenever you download.
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local lfs = require("libs/libkoreader-lfs")
local rapidjson = require("rapidjson")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")
local _ = require("gettext")

-- Set from the menu after the GitHub Pages site exists, e.g. https://<username>.github.io/kindle-edition/
local DEFAULT_URL = ""
local FOLDER = "/mnt/us/documents/Daily reads"

local DailyReads = WidgetContainer:extend{
    name = "dailyreads",
    is_doc_only = false,
}

function DailyReads:init()
    self.ui.menu:registerToMainMenu(self)
end

local function baseUrl()
    local u = G_reader_settings:readSetting("dailyreads_url") or DEFAULT_URL
    if u ~= "" and not u:match("/$") then u = u .. "/" end
    return u
end

local function get(url, sink)
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code = socket.skip(1, http.request{
        url = url, method = "GET", sink = sink, redirect = true,
        headers = { ["User-Agent"] = "KOReader DailyReads" },
    })
    socketutil:reset_timeout()
    return code
end

local function urlencode(path)
    return (path:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

local function removeTree(path)
    if lfs.attributes(path, "mode") == "directory" then
        for f in lfs.dir(path) do
            if f ~= "." and f ~= ".." then removeTree(path .. "/" .. f) end
        end
        lfs.rmdir(path)
    else
        os.remove(path)
    end
end

-- Date (YYYY-MM-DD) of the most recent Sunday, today included.
local function lastSunday()
    local t = os.date("*t")
    return os.date("%Y-%m-%d", os.time() - (t.wday - 1) * 86400)
end

function DailyReads:clearOld()
    local cutoff, removed = lastSunday(), 0
    if lfs.attributes(FOLDER, "mode") ~= "directory" then return 0 end
    for f in lfs.dir(FOLDER) do
        local d = f:match("^(%d%d%d%d%-%d%d%-%d%d) ")
        if d and d < cutoff then
            removeTree(FOLDER .. "/" .. f)
            if f:match("%.epub$") then removed = removed + 1 end
        end
    end
    return removed
end

function DailyReads:download(after)
    local base = baseUrl()
    if base == "" then
        UIManager:show(InfoMessage:new{ text = _("Set the edition address first: Daily reads → Edition address.") })
        return
    end
    local busy = InfoMessage:new{ text = _("Downloading today's reads…") }
    UIManager:show(busy)
    UIManager:forceRePaint()

    local removed = self:clearOld()
    local chunks = {}
    local code = get(base .. "today.json?t=" .. os.time(), ltn12.sink.table(chunks))
    local ok, manifest = pcall(rapidjson.decode, table.concat(chunks))
    if code ~= 200 or not ok or type(manifest) ~= "table" or type(manifest.files) ~= "table" then
        UIManager:close(busy)
        UIManager:show(InfoMessage:new{ text = _("Couldn't reach today's edition. Check Wi-Fi and try again.") })
        logger.warn("dailyreads: manifest failed", code)
        return
    end

    lfs.mkdir(FOLDER)
    local got, have, failed = 0, 0, 0
    for _i, f in ipairs(manifest.files) do
        local dest = FOLDER .. "/" .. f.file
        if lfs.attributes(dest, "mode") == "file" then
            have = have + 1
        else
            local tmp = dest .. ".part"
            local fh = io.open(tmp, "wb")
            local c = fh and get(base .. urlencode(f.url), ltn12.sink.file(fh))
            if c == 200 then
                os.rename(tmp, dest)
                got = got + 1
            else
                os.remove(tmp)
                failed = failed + 1
            end
        end
    end
    -- keep a copy of the manifest for the dashboard page (headlines, counts)
    local mf = io.open(FOLDER .. "/today.json", "w")
    if mf then mf:write(table.concat(chunks)); mf:close() end

    UIManager:close(busy)
    local lines = { string.format(_("%s: %d new, %d already here."), manifest.label or manifest.date, got, have) }
    if failed > 0 then table.insert(lines, string.format(_("%d failed — tap again to retry."), failed)) end
    if removed > 0 then table.insert(lines, string.format(_("Cleared %d from last week."), removed)) end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n"), timeout = 6 })
    if after then UIManager:scheduleIn(0.3, after) end
end

function DailyReads:addToMainMenu(menu_items)
    menu_items.dailyreads = {
        text = _("Daily reads"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Download today's reads"),
                callback = function()
                    NetworkMgr:runWhenOnline(function() self:download() end)
                end,
            },
            {
                text = _("Open Daily reads folder"),
                callback = function()
                    lfs.mkdir(FOLDER)
                    local FileManager = require("apps/filemanager/filemanager")
                    if FileManager.instance then
                        FileManager.instance:reinit(FOLDER)
                    else
                        FileManager:showFiles(FOLDER)
                    end
                end,
            },
            {
                text = _("Clear last week now"),
                callback = function()
                    local n = self:clearOld()
                    UIManager:show(InfoMessage:new{ text = string.format(_("Cleared %d editions."), n), timeout = 3 })
                end,
            },
            {
                text = _("Edition address"),
                keep_menu_open = true,
                callback = function()
                    local dlg
                    dlg = InputDialog:new{
                        title = _("Edition address"),
                        input = baseUrl(),
                        input_hint = "https://username.github.io/kindle-edition/",
                        buttons = {{
                            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
                            { text = _("Save"), is_enter_default = true, callback = function()
                                G_reader_settings:saveSetting("dailyreads_url", dlg:getInputText())
                                UIManager:close(dlg)
                            end },
                        }},
                    }
                    UIManager:show(dlg)
                    dlg:onShowKeyboard()
                end,
            },
        },
    }
end

return DailyReads
