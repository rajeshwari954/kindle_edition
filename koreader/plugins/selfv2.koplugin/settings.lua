--[[
Settings for self.v2 on the Kindle: light/dark switch, Wi-Fi networks, reading font and size,
passcode lock, and the greeting. Installed onto the plugin by main.lua.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local Blitbuffer = require("ffi/blitbuffer")
local _ = require("gettext")
local Screen = Device.screen

local M = {}

---------------------------------------------------------------- greeting

-- Changes with the time of day.
function M.greeting()
    local h = tonumber(os.date("%H"))
    local wday = tonumber(os.date("%w"))
    if h >= 1 and h < 4 then return "UP LATE?" end
    if h >= 4 and h < 12 then return wday == 0 and "HAPPY SUNDAY," or "GOOD MORNING," end
    if h >= 12 and h < 17 then return "GOOD AFTERNOON," end
    if h >= 17 and h < 23 then return "GOOD EVENING," end
    return "GOOD NIGHT,"  -- 11 pm to 1 am
end

---------------------------------------------------------------- light / dark

function M.isDark() return G_reader_settings:isTrue("night_mode") end

function M.toggleDark(plugin)
    G_reader_settings:flipNilOrFalse("night_mode")
    Screen:toggleNightMode()
    UIManager:setDirty("all", "full")
    if plugin.canvas and plugin.canvas.is_open then
        UIManager:scheduleIn(0.2, function() plugin.canvas:rebuild("full") end)
    end
end

---------------------------------------------------------------- Wi-Fi

function M.wifiMenu(plugin)
    local dlg
    local on = NetworkMgr:isWifiOn()
    local function close() UIManager:close(dlg) end
    dlg = ButtonDialog:new{
        title = on and _("Wi-Fi is on") or _("Wi-Fi is off"),
        buttons = {
            { { text = _("Choose a network…"), callback = function()
                close()
                local function show()
                    if NetworkMgr.showNetworkMenu then
                        NetworkMgr:showNetworkMenu()
                    elseif NetworkMgr.reconnectOrShowNetworkMenu then
                        NetworkMgr:reconnectOrShowNetworkMenu(nil, true)
                    else
                        UIManager:show(InfoMessage:new{ text = _("This KOReader version can't list networks here. Use KOReader menu → Network.") })
                    end
                end
                if NetworkMgr:isWifiOn() then show() else NetworkMgr:turnOnWifi(show) end
            end } },
            { { text = on and _("Turn Wi-Fi off") or _("Turn Wi-Fi on"), callback = function() close(); plugin:toggleWifi() end } },
            { { text = _("Close"), callback = close } },
        },
    }
    UIManager:show(dlg)
end

---------------------------------------------------------------- airplane mode

function M.isAirplane() return G_reader_settings:isTrue("selfv2_airplane") end

function M.setAirplane(on)
    local kindle = Device.isKindle and Device:isKindle()
    if on then
        if NetworkMgr:isWifiOn() then NetworkMgr:turnOffWifi(function() end) end
        if kindle then os.execute("lipc-set-prop com.lab126.cmd wirelessEnable 0 >/dev/null 2>&1") end
        G_reader_settings:saveSetting("selfv2_airplane", true)
    else
        if kindle then os.execute("lipc-set-prop com.lab126.cmd wirelessEnable 1 >/dev/null 2>&1") end
        G_reader_settings:delSetting("selfv2_airplane")
    end
end

-- Use instead of NetworkMgr:runWhenOnline, so airplane mode is respected.
function M.online(cb)
    if M.isAirplane() then
        UIManager:show(InfoMessage:new{ text = _("Airplane mode is on. Turn it off in the control centre to connect."), timeout = 3 })
        return
    end
    NetworkMgr:runWhenOnline(cb)
end

---------------------------------------------------------------- reading font and size

local SIZES = { { "Small", 20 }, { "Medium", 24 }, { "Large", 28 }, { "Extra large", 33 } }

local function fontFaces()
    local ok, faces = pcall(function()
        local CreDocument = require("document/credocument")
        CreDocument:engineInit()
        return require("libs/libkoreader-cre").getFontFaces()
    end)
    return ok and faces or {}
end

function M.fontMenu()
    local faces = fontFaces()
    if #faces == 0 then
        UIManager:show(InfoMessage:new{ text = _("Couldn't list fonts here. Open a book and use its font menu instead.") })
        return
    end
    local current = G_reader_settings:readSetting("cre_font")
    local Menu = require("ui/widget/menu")
    local menu
    local items = {}
    for _i, f in ipairs(faces) do
        table.insert(items, { text = f .. (f == current and "  ✓" or ""), callback = function()
            G_reader_settings:saveSetting("cre_font", f)
            UIManager:close(menu)
            UIManager:show(InfoMessage:new{ text = f .. _(" is now the reading font for books you open next. Books you've already set up keep their own font."), timeout = 4 })
        end })
    end
    menu = Menu:new{
        title = _("Reading font"),
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
    }
    menu.close_callback = function() UIManager:close(menu) end
    UIManager:show(menu)
end

function M.sizeMenu()
    local dlg
    local cur = G_reader_settings:readSetting("copt_font_size")
    local rows = {}
    for _i, s in ipairs(SIZES) do
        table.insert(rows, { { text = s[1] .. (cur == s[2] and "  (current)" or ""), callback = function()
            G_reader_settings:saveSetting("copt_font_size", s[2])
            UIManager:close(dlg)
            UIManager:show(InfoMessage:new{ text = _("Text size set for books you open next. Inside a book, tap the bottom of the page to change it there."), timeout = 4 })
        end } })
    end
    table.insert(rows, { { text = _("Close"), callback = function() UIManager:close(dlg) end } })
    dlg = ButtonDialog:new{ title = _("Text size in books"), buttons = rows }
    UIManager:show(dlg)
end

---------------------------------------------------------------- passcode

local function hash(pin)
    local ok, sha2 = pcall(require, "ffi/sha2")
    if ok and sha2 and sha2.sha256 then return "s:" .. sha2.sha256("selfv2:" .. pin) end
    -- fallback: a simple mix, still never stores the PIN itself
    local h = 5381
    for i = 1, #pin do h = (h * 33 + pin:byte(i)) % 4294967296 end
    return "d:" .. tostring(h)
end

function M.hasPin() return G_reader_settings:readSetting("selfv2_pin") ~= nil end

local function askPin(title, cb, allow_cancel)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    local buttons = {}
    if allow_cancel then
        table.insert(buttons, { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end })
    end
    table.insert(buttons, { text = _("OK"), is_enter_default = true, callback = function()
        local v = dlg:getInputText() or ""
        cb(v, dlg)
    end })
    dlg = InputDialog:new{ title = title, input = "", input_type = "number", text_type = "password", buttons = { buttons } }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
    return dlg
end

function M.pinMenu()
    local dlg
    local function close() UIManager:close(dlg) end
    local rows = {}
    if M.hasPin() then
        table.insert(rows, { { text = _("Change passcode"), callback = function() close(); M.setPin(true) end } })
        table.insert(rows, { { text = _("Turn passcode off"), callback = function()
            close()
            askPin(_("Enter your current passcode"), function(v, d)
                UIManager:close(d)
                if hash(v) == G_reader_settings:readSetting("selfv2_pin") then
                    G_reader_settings:delSetting("selfv2_pin")
                    UIManager:show(InfoMessage:new{ text = _("Passcode turned off."), timeout = 2 })
                else
                    UIManager:show(InfoMessage:new{ text = _("That passcode isn't right."), timeout = 2 })
                end
            end, true)
        end } })
    else
        table.insert(rows, { { text = _("Set a passcode"), callback = function() close(); M.setPin(false) end } })
    end
    table.insert(rows, { { text = _("Close"), callback = close } })
    dlg = ButtonDialog:new{
        title = M.hasPin() and _("Passcode is on. It's asked for when the Kindle wakes and when KOReader starts.")
            or _("Lock the Kindle with a passcode when it wakes and when KOReader starts."),
        buttons = rows,
    }
    UIManager:show(dlg)
end

function M.setPin(changing)
    local function choose()
        askPin(_("Choose a passcode (4–8 digits)"), function(first, d1)
            if not first:match("^%d%d%d%d%d?%d?%d?%d?$") then
                UIManager:show(InfoMessage:new{ text = _("Use 4 to 8 digits."), timeout = 2 })
                return
            end
            UIManager:close(d1)
            askPin(_("Type it again"), function(second, d2)
                UIManager:close(d2)
                if second == first then
                    G_reader_settings:saveSetting("selfv2_pin", hash(first))
                    UIManager:show(InfoMessage:new{ text = _("Passcode set."), timeout = 2 })
                else
                    UIManager:show(InfoMessage:new{ text = _("Those didn't match. Try again."), timeout = 2 })
                end
            end, true)
        end, true)
    end
    if changing then
        askPin(_("Enter your current passcode"), function(v, d)
            UIManager:close(d)
            if hash(v) == G_reader_settings:readSetting("selfv2_pin") then choose()
            else UIManager:show(InfoMessage:new{ text = _("That passcode isn't right."), timeout = 2 }) end
        end, true)
    else
        choose()
    end
end

-- A blank cover so nothing on screen shows while locked, with the passcode box on top.
local Cover = InputContainer:extend{ name = "selfv2_lock", covers_fullscreen = true, modal = true }
function Cover:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self[1] = FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, margin = 0,
        Widget:new{ dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() } } }
end

local locked = false
function M.lock()
    if locked or not M.hasPin() then return end
    locked = true
    local cover = Cover:new{}
    UIManager:show(cover, "full")
    local function ask()
        askPin(_("Passcode"), function(v, d)
            if hash(v) == G_reader_settings:readSetting("selfv2_pin") then
                UIManager:close(d)
                UIManager:close(cover, "full")
                locked = false
            else
                UIManager:close(d)
                UIManager:show(InfoMessage:new{ text = _("Not quite. Try again."), timeout = 1 })
                UIManager:scheduleIn(1.2, ask)
            end
        end, false)
    end
    ask()
end

return M
