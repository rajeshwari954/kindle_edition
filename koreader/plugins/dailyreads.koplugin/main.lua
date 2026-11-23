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

-- Sealed files (your subscriber e-paper) are encrypted on the web with your paper passphrase.
-- Same scheme as seal.py: key from sha256 rounds, then SHA-256 in counter mode.
local function hex2bin(h) return (h:gsub("..", function(c) return string.char(tonumber(c, 16)) end)) end

local function unseal(path, dest, passphrase)
    local ok, sha2 = pcall(require, "ffi/sha2")
    if not ok then return false, "no sha2" end
    local bit = require("bit")
    local fh = io.open(path, "rb")
    if not fh then return false, "missing" end
    local blob = fh:read("*a")
    fh:close()
    if blob:sub(1, 5) ~= "SVPK1" then return false, "not sealed" end
    local salt = blob:sub(6, 21)
    local pw = passphrase:match("^%s*(.-)%s*$")
    local k = hex2bin(sha2.sha256(salt .. pw))
    for _i = 1, 1000 do k = hex2bin(sha2.sha256(k .. pw)) end
    local data, n = blob:sub(22), #blob - 21
    local out = io.open(dest, "wb")
    if not out then return false, "can't write" end
    local buf, bytes = {}, {}
    local block = 0
    for pos = 1, n, 32 do
        local ctr = string.char(0, 0, 0, bit.band(bit.rshift(block, 24), 255), bit.band(bit.rshift(block, 16), 255),
            bit.band(bit.rshift(block, 8), 255), bit.band(block, 255))
        local ks = hex2bin(sha2.sha256(k .. "\0" .. ctr))
        local len = math.min(32, n - pos + 1)
        for j = 1, len do
            bytes[j] = bit.bxor(data:byte(pos + j - 1), ks:byte(j))
        end
        buf[#buf + 1] = string.char(unpack(bytes, 1, len))
        if #buf >= 2048 then out:write(table.concat(buf)); buf = {} end
        block = block + 1
    end
    out:write(table.concat(buf))
    out:close()
    local check = io.open(dest, "rb")
    local head = check and check:read(2)
    if check then check:close() end
    if head ~= "PK" then os.remove(dest); return false, "wrong passphrase" end
    return true
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
    local locked, badkey
    for _i, f in ipairs(manifest.files) do
      if f.file and f.url then
        local dir = FOLDER
        if f.folder then
            dir = "/mnt/us/documents/" .. f.folder  -- e.g. Books: kept, not cleared on Sunday
            lfs.mkdir(dir)
        end
        local dest = dir .. "/" .. f.file
        if lfs.attributes(dest, "mode") == "file" then
            have = have + 1
        else
            local tmp = dest .. ".part"
            local key = G_reader_settings:readSetting("selfv2_paper_key")
            if f.sealed and not (key and key ~= "") then
                locked = (locked or 0) + 1
                goto continue
            end
            local fh = io.open(tmp, "wb")
            local c = fh and get(base .. urlencode(f.url), ltn12.sink.file(fh))
            if c == 200 and f.sealed then
                local okk, why = unseal(tmp, dest, key)
                os.remove(tmp)
                if okk then got = got + 1 else
                    failed = failed + 1
                    if why == "wrong passphrase" then badkey = true end
                end
            elseif c == 200 then
                os.rename(tmp, dest)
                got = got + 1
            else
                os.remove(tmp)
                failed = failed + 1
            end
        end
      end
      ::continue::
    end
    -- keep a copy of the manifest for the dashboard page (headlines, counts)
    local mf = io.open(FOLDER .. "/today.json", "w")
    if mf then mf:write(table.concat(chunks)); mf:close() end

    UIManager:close(busy)
    local lines = { string.format(_("%s: %d new, %d already here."), manifest.label or manifest.date, got, have) }
    if failed > 0 then table.insert(lines, string.format(_("%d failed — tap again to retry."), failed)) end
    if removed > 0 then table.insert(lines, string.format(_("Cleared %d from last week."), removed)) end
    if locked then table.insert(lines, _("Your e-paper needs the paper passphrase: Settings → Paper passphrase.")) end
    if badkey then table.insert(lines, _("The paper passphrase doesn't match the one on GitHub: Settings → Paper passphrase.")) end
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
