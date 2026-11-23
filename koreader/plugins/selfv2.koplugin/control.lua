--[[
Control centre: pulls down over any self.v2 screen (swipe down from the top, or tap the handle).
Clock and battery, Wi-Fi, dark mode, today's reads, lock, brightness, sleep, restart and Blackhole.
Installed onto Canvas by main.lua: dofile("control.lua")(Canvas, ctx).
]]

local ConfirmBox = require("ui/widget/confirmbox")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

return function(Canvas, ctx)
local S = ctx.S
local BLACK, WHITE, GREY, LIGHT = ctx.BLACK, ctx.WHITE, ctx.GREY, ctx.LIGHT
local PANEL_H = 712

local function powerd()
    local ok, p = pcall(function() return Device:getPowerDevice() end)
    return ok and p or nil
end

local function battery()
    local p = powerd()
    if not p then return nil end
    local ok, cap = pcall(p.getCapacity, p)
    local ok2, chg = pcall(p.isCharging, p)
    return ok and cap or nil, ok2 and chg or false
end

local function lightLevel()
    local p = powerd()
    if not p or not Device:hasFrontlight() then return nil end
    local ok, v = pcall(p.frontlightIntensity, p)
    return ok and v or nil, p.fl_min or 0, p.fl_max or 24
end

local function setLight(v)
    local p = powerd()
    if p then pcall(p.setIntensity, p, v) end
end

-- the little handle at the top of every self.v2 screen
function Canvas:drawHandle()
    if self.control or self.sheet then return end
    self:box(319, 6, 120, 10, BLACK, 5)
    self:zone({ 290, 0, 178, 19 }, function() self:openControl() end)
end

function Canvas:openControl()
    self.control = true
    self:rebuild("ui")
end

function Canvas:closeControl()
    if self.overlay then
        -- opened over a book: close it and show the page again
        self.is_open = false
        UIManager:close(self)
        UIManager:setDirty("all", "ui")
        return
    end
    self.control = nil
    self:rebuild("ui")
end

-- leave the control centre before doing something else (works on Home and over a book)
function Canvas:leaveControl()
    if self.overlay then self.is_open = false; UIManager:close(self) else self.control = nil; self:rebuild("ui") end
end

function Canvas:tile(x, y, w, h, title, sub, on, cb)
    self:box(x, y, w, h, on and BLACK or LIGHT, 24)
    local fg = on and WHITE or BLACK
    self:text(title, "sans", 17, x + 16, y + h - 58, fg, true)
    self:text(sub, "sans", 13, x + 16, y + h - 32, on and LIGHT or GREY)
    self:zone({ x, y, w, h }, cb)
end

function Canvas:drawControl()
    -- tapping below the panel closes it; the panel itself swallows stray taps
    self:zone({ 0, PANEL_H, 758, 1024 - PANEL_H }, function() self:closeControl() end)
    self:zone({ 0, 0, 758, PANEL_H }, function() end)
    self:box(0, 0, 758, PANEL_H, WHITE, 30, 4)

    -- clock, date, battery
    self:text(os.date("%H:%M"), "serif", 52, 30, 24)
    self:text((os.date("%A, %d %B"):gsub(" 0", " ")), "sans", 16, 32, 92, GREY)
    local cap, charging = battery()
    if cap then
        self:box(608, 38, 96, 40, nil, 10, 3)
        self:box(704, 50, 6, 16, BLACK, 2)
        self:box(612, 42, math.max(4, 88 * cap / 100), 32, BLACK, 7)
        self:text(cap .. "%" .. (charging and " · charging" or ""), "sans", 14, 608, 86, GREY, true)
    end

    -- small round power button: sleep, showing your lock screen
    self:box(530, 34, 56, 56, BLACK, 28)
    self:box(545, 49, 26, 26, nil, 13, 3, WHITE)
    self:box(553, 44, 10, 14, BLACK)
    self:box(556, 43, 4, 18, WHITE, 2)
    self:zone({ 522, 26, 72, 72 }, function()
        self:leaveControl()
        if UIManager.suspend then UIManager:suspend() end
    end)

    -- tiles: two rows of four
    local ui = self.plugin and self.plugin.ui
    local inBook = ui and ui.document and true or false
    local air = S.isAirplane()
    local wifi = (not air) and NetworkMgr:isWifiOn()
    local dark = S.isDark()
    local night = S.isNight()
    local tw, th, gap = 163, 120, 15
    local col = function(i) return 30 + (i - 1) * (tw + gap) end
    local r1, r2 = 124, 256
    self:tile(col(1), r1, tw, th, "Wi-Fi", air and "Off · airplane" or (wifi and "On" or "Off"), wifi, function()
        if air then
            UIManager:show(InfoMessage:new{ text = _("Turn airplane mode off first."), timeout = 2 })
        elseif wifi then S.wifiMenu(self.plugin)
        else NetworkMgr:turnOnWifi(function() self:rebuild("ui") end) end
    end)
    self:tile(col(2), r1, tw, th, "Airplane", air and "On" or "Off", air, function()
        S.setAirplane(not air)
        self:rebuild("ui")
    end)
    self:tile(col(3), r1, tw, th, dark and "Dark" or "Light", "Tap to switch", dark, function()
        self.control = true
        S.toggleDark(self.plugin)
        if self.overlay then UIManager:scheduleIn(0.25, function() self:rebuild("full") end) end
    end)
    self:tile(col(4), r1, tw, th, "Night", night and "On · softer" or "Off", night, function()
        S.toggleNight(ui, ctx.plugin_dir)
        self:rebuild("full")
    end)
    self:tile(col(1), r2, tw, th, "Today's reads", "Download", false, function()
        self:leaveControl()
        self.plugin:download(function() if not self.overlay then self:rebuild("ui") end end)
    end)
    self:tile(col(2), r2, tw, th, "Lock", S.hasPin() and "Lock now" or "Set passcode", false, function()
        if S.hasPin() then self:leaveControl(); S.lock() else S.pinMenu() end
    end)
    self:tile(col(3), r2, tw, th, "Home", "self.v2 Home", false, function()
        if self.overlay then
            self.is_open = false
            UIManager:close(self)
            self.plugin:readerHome()
            return
        end
        self.control = nil
        if self.mode ~= "home" then self:go("home") else self:rebuild("ui") end
    end)
    local fname = S.fontName(ui)
    self:tile(col(4), r2, tw, th, "Font", #fname > 14 and (fname:sub(1, 13) .. "…") or fname, false, function()
        S.fontMenu(ui)
    end)

    -- brightness
    local ly = 398
    local lvl, lo, hi = lightLevel()
    if lvl then
        self:text("Light", "sans", 16, 32, ly, BLACK, true)
        self:pill("–", 30, ly + 26, 46, "outline", 22, 64)
        self:pill("+", 664, ly + 26, 46, "dark", 22, 64)
        self:box(108, ly + 44, 542, 10, LIGHT, 5)
        self:box(108, ly + 44, math.max(10, 542 * (lvl - lo) / math.max(1, hi - lo)), 10, BLACK, 5)
        self:text(lvl .. "/" .. hi, "sans", 13, 600, ly, GREY)
        local step = math.max(1, math.floor((hi - lo) / 8))
        self:zone({ 26, ly + 20, 72, 58 }, function() setLight(math.max(lo, lvl - step)); self:rebuild("ui") end)
        self:zone({ 660, ly + 20, 72, 58 }, function() setLight(math.min(hi, lvl + step)); self:rebuild("ui") end)
        self:zone({ 108, ly + 20, 542, 58 }, function() end)
    end

    -- text size
    local sy = 492
    local size = S.fontSize(ui)
    self:text("Text size", "sans", 16, 32, sy + 12, BLACK, true)
    self:text(inBook and (ui.rolling and "this book" or "books only") or "next book", "sans", 13, 140, sy + 15, GREY)
    self:pill("A–", 470, sy, 46, "outline", 18, 76)
    self:centerText(tostring(size or "–"), "sans", 20, 552, sy, 100, 46, BLACK, true)
    self:pill("A+", 652, sy, 46, "dark", 18, 76)
    local function size_step(d)
        if inBook and not ui.rolling then
            UIManager:show(InfoMessage:new{ text = _("Text size works in books (EPUB and similar), not in PDFs."), timeout = 3 })
            return
        end
        S.stepSize(ui, d)
        self:rebuild("ui")
    end
    self:zone({ 466, sy - 6, 84, 58 }, function() size_step(-2) end)
    self:zone({ 648, sy - 6, 84, 58 }, function() size_step(2) end)

    -- paper tone
    local py0 = 556
    self:text("Paper", "sans", 16, 32, py0 + 12, BLACK, true)
    local cur = S.paper()
    local cw = (728 - 140 - 3 * 8) / 4
    for i, p in ipairs(S.PAPERS) do
        local x = 140 + (i - 1) * (cw + 8)
        self:pill(p[2], x, py0, 46, cur == p[1] and "dark" or "outline", 15, cw)
        self:zone({ x, py0 - 6, cw, 58 }, function()
            local ok = S.setPaper(ui, ctx.plugin_dir, p[1])
            if inBook and not ok then
                UIManager:show(InfoMessage:new{ text = _("Paper tones work in books (EPUB and similar), not in PDFs. Saved for your next book."), timeout = 3 })
            elseif not inBook then
                UIManager:show(InfoMessage:new{ text = _("Saved. Books you open will use this paper."), timeout = 2 })
            end
            self:rebuild("full")
        end)
    end

    -- restart, blackhole
    local by, bw = 630, 339
    self:pill("Restart KOReader", 30, by, 52, "outline", 17, bw)
    self:zone({ 30, by, bw, 52 }, function()
        if UIManager.restartKOReader then UIManager:restartKOReader() end
    end)
    self:pill("Blackhole", 389, by, 52, "dark", 17, bw)
    self:zone({ 389, by, bw, 52 }, function()
        UIManager:show(ConfirmBox:new{
            text = _("Blackhole: close KOReader and go back to the Kindle's own home screen?"),
            ok_text = _("Exit"),
            ok_callback = function() UIManager:quit() end,
        })
    end)
end

end
