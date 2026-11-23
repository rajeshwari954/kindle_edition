--[[
self.v2 dashboard on the Kindle: Today and Check-in, matching the finalised designs.
Reads and writes the self.v2 Notion databases through notion.lua.
Installed onto the Canvas class by main.lua: dofile("dash.lua")(Canvas, ctx).
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local _ = require("gettext")

return function(Canvas, ctx)
local N, px, py, face = ctx.N, ctx.px, ctx.py, ctx.face
local BLACK, WHITE, GREY, LIGHT = ctx.BLACK, ctx.WHITE, ctx.GREY, ctx.LIGHT
local TIMETABLE = ctx.timetable or {}
local TRACK = Blitbuffer.Color8(0x4A)

---------------------------------------------------------------- drawing helpers

-- a plain rectangle (rounded), optionally outlined
function Canvas:box(x, y, w, h, bg, radius, border, bcolor)
    self:put(FrameContainer:new{
        background = bg, bordersize = border or 0, color = bcolor or BLACK, radius = radius and px(radius) or 0,
        padding = 0, margin = 0,
        Widget:new{ dimen = Geom:new{ w = math.max(1, px(w) - 2 * (border or 0)), h = math.max(1, py(h) - 2 * (border or 0)) } },
    }, x, y)
end

function Canvas:centerText(str, kind, size, x, y, w, h, color, bold)
    local tw = TextWidget:new{ text = str, face = face(kind, size), fgcolor = color or BLACK, bold = bold, max_width = px(w) }
    self:put(CenterContainer:new{ dimen = Geom:new{ w = px(w), h = py(h) }, tw }, x, y)
end

local TABS = { { "Today", "today" }, { "Check-in", "checkin" }, { "Log", "log" }, { "Week", "week" }, { "Work", "work" } }

function Canvas:navBar(active, L)
    local x0, w = L.nav[1] + 5, (L.nav[3] - 10 - 16) / 5
    for i, t in ipairs(TABS) do
        local x = x0 + (i - 1) * (w + 4)
        if t[2] == active then
            self:box(x, L.tab_y, w, L.tab_h, BLACK, L.tab_h / 2)
            self:centerText(t[1], "sans", 17, x, L.tab_y, w, L.tab_h, WHITE, true)
        else
            self:centerText(t[1], "sans", 17, x, L.tab_y, w, L.tab_h, BLACK, true)
        end
        self:zone({ x, L.tab_y - 4, w, L.tab_h + 8 }, function()
            if t[2] then
                if t[2] ~= self.mode then self.ddate = self.ddate; self:go(t[2]) end
            else
                UIManager:show(InfoMessage:new{ text = t[1] .. " is coming in the next update.", timeout = 3 })
            end
        end)
    end
end

---------------------------------------------------------------- the day being shown

function Canvas:dday() return self.ddate or N.today() end
function Canvas:isTodayShown() return self:dday() == N.today() end

function Canvas:dashFresh()
    return self.dash and self.dash.date == self:dday() and self.dash.loaded
end

function Canvas:homePill(r)
    self:pill("‹ Home", r[1], r[2], r[4], "outline", 15, r[3])
    self:zone({ r[1], r[2] - 6, r[3], r[4] + 12 }, function() self:go("home") end)
end

function Canvas:datePill(x, y, w, h)
    local label = (os.date("%a %d %b", N.dateTime(self:dday())):gsub(" 0", " "))
    self:pill(label, x, y, h, "light", 15, w)
    self:zone({ x, y - 4, w, h + 8 }, function() self:pickDate() end)
end

function Canvas:pickDate()
    local dlg
    local function go(date)
        UIManager:close(dlg)
        self.ddate = date
        self.dash, self.sheet, self.logd, self.periodd = nil, nil, nil, nil
        self:go(self.mode)
    end
    local today = N.today()
    dlg = ButtonDialog:new{
        title = _("Show which day?"),
        buttons = {
            { { text = _("Yesterday"), callback = function() go(N.prevDay(today)) end },
              { text = _("Today"), callback = function() go(today) end },
              { text = _("Tomorrow"), callback = function() go(N.nextDay(today)) end } },
            { { text = _("‹ Day before"), callback = function() go(N.prevDay(self:dday())) end },
              { text = _("Day after ›"), callback = function() go(N.nextDay(self:dday())) end } },
            { { text = _("Close"), callback = function() UIManager:close(dlg) end } },
        },
    }
    UIManager:show(dlg)
end

---------------------------------------------------------------- Notion: load and write

function Canvas:notionError(err)
    if err == "no_token" or err == "bad_token" then
        self.plugin:notionSetup(err == "bad_token")
    elseif err == "not_shared" then
        UIManager:show(InfoMessage:new{ text = _("Notion says the self.v2 page isn't shared with the Kindle connection yet. In Notion, open self.v2 → ••• → Connections → add Kindle.") })
    else
        UIManager:show(InfoMessage:new{ text = "Notion: " .. tostring(err) .. "\nCheck Wi-Fi and try again.", timeout = 6 })
    end
end

function Canvas:loadDash()
    if not N.token() then self.plugin:notionSetup(false) return end
    ctx.online(function()
        local busy = InfoMessage:new{ text = _("Loading from Notion…") }
        UIManager:show(busy)
        UIManager:forceRePaint()
        local day = self:dday()
        local nxt = N.nextDay(day)
        local d = { date = day, blocks = {}, todos = {}, attend = {}, lectures = {} }
        local ok, res = N.query(N.DS.checkin, { property = "Date", date = { equals = day } })
        if not ok then UIManager:close(busy); self:notionError(res); return end
        d.checkin = res[1]
        ok, res = N.query(N.DS.blocks, { ["or"] = {
            { ["and"] = {
                { property = "Planned", date = { on_or_after = day .. "T00:00:00+05:30" } },
                { property = "Planned", date = { before = nxt .. "T00:00:00+05:30" } } } },
            { property = "Repeat", select = { equals = "Every day" } },
            { property = "Repeat", select = { equals = "Weekdays" } },
            { property = "Repeat", select = { equals = "Mon to Sat" } },
        } })
        if ok then d.blocks = res end
        local todoFilter = { property = "Date", date = { equals = day } }
        if day == N.today() then
            todoFilter = { ["or"] = { todoFilter,
                { ["and"] = { { property = "Date", date = { before = day } }, { property = "Done", checkbox = { equals = false } } } } } }
        end
        ok, res = N.query(N.DS.todos, todoFilter)
        if ok then d.todos = res end
        ok, res = N.query(N.DS.attend, { property = "Date", date = { equals = day } })
        if ok then for _i, pg in ipairs(res) do d.attend[N.get(pg, "Type") or "?"] = pg end end
        ok, res = N.query(N.DS.lectures, { property = "Date", date = { equals = day } })
        if ok then for _i, pg in ipairs(res) do d.lectures[N.get(pg, "Subject") or "?"] = pg end end
        if d.checkin then
            ok, res = N.query(N.DS.sleep, { property = "Check-in day", relation = { contains = d.checkin.id } })
            if ok then d.sleep = res[1] end
        end
        d.loaded = true
        self.dash = d
        UIManager:close(busy)
        self:rebuild("full")
    end)
end

function Canvas:write(fn, after)
    ctx.online(function()
        local ok, res = fn()
        if not ok then self:notionError(res) return end
        if after then after(res) end
        self:rebuild("ui")
    end)
end

function Canvas:checkinRow(cb)
    if self.dash.checkin then return cb(self.dash.checkin) end
    self:write(function()
        return N.create(N.DS.checkin, { Day = N.title(N.dayTitle(self:dday())), Date = N.date(self:dday()) })
    end, function(pg) self.dash.checkin = pg; cb(pg) end)
end

function Canvas:setProp(pg, name, value)
    pg.properties = pg.properties or {}
    local p = pg.properties[name] or {}
    if type(value) == "boolean" then p.type = "checkbox"; p.checkbox = value
    elseif type(value) == "number" then p.type = "number"; p.number = value
    elseif type(value) == "string" then p.type = "select"; p.select = { name = value }
    elseif type(value) == "table" then p.type = "date"; p.date = value end
    pg.properties[name] = p
end

local function rel(pg) return pg and { relation = { { id = pg.id } } } or nil end

---------------------------------------------------------------- Today: blocks

local WEEKDAYS = { Weekdays = { [2] = 1, [3] = 1, [4] = 1, [5] = 1, [6] = 1 },
    ["Mon to Sat"] = { [2] = 1, [3] = 1, [4] = 1, [5] = 1, [6] = 1, [7] = 1 } }

local function wdayOf(date) return tonumber(os.date("%w", N.dateTime(date))) + 1 end

function Canvas:dayBlocks()
    local day = self:dday()
    local wday = wdayOf(day)
    local out, syncedKinds = {}, {}
    for _i, pg in ipairs(self.dash.blocks or {}) do
        local pl = N.get(pg, "Planned")
        local rep = N.get(pg, "Repeat")
        local s, sd = N.localTime(pl and pl.start)
        local e = N.localTime(pl and pl.finish)
        local include = (sd == day)
        if rep == "Every day" then include = true
        elseif WEEKDAYS[rep] then include = WEEKDAYS[rep][wday] ~= nil end
        if include and s then
            local synced = N.get(pg, "Source") == "From check-in"
            local b = { pg = pg, title = N.get(pg, "Block") or "", start = s, finish = e or (s + 60), date = sd,
                cat = N.get(pg, "Category") or "", status = N.get(pg, "Status") or "Planned",
                rep = rep or "Once", synced = synced }
            if synced then syncedKinds[N.get(pg, "Category") or b.title] = b end
            table.insert(out, b)
        end
    end
    -- show college / work from the check-in even before a synced block exists
    for kind, att in pairs(self.dash.attend or {}) do
        if not syncedKinds[kind] and N.get(att, "Status") == "Attended" then
            local i, o = N.get(att, "In"), N.get(att, "Out")
            local s, e = N.localTime(i and i.start), N.localTime(o and o.start)
            if s and e then
                table.insert(out, { title = kind == "Work" and "Internship" or kind, start = s, finish = e, cat = kind,
                    synced = true, status = "Done", rep = "Once", att = att })
            end
        end
    end
    for _i, b in ipairs(out) do
        if b.synced then
            local att = self.dash.attend[b.cat] or b.att
            local st = att and N.get(att, "Status") or "Went"
            b.sub = (st == "Attended" and "Went" or st) .. " · in " .. N.hhmm(b.start) .. ", out " .. N.hhmm(b.finish)
        else
            b.sub = N.hhmm(b.start) .. " – " .. N.hhmm(b.finish) .. (b.rep ~= "Once" and (" · " .. b.rep) or "")
        end
    end
    table.sort(out, function(a, b) return a.start < b.start end)
    return out
end

local function hourLabel(h)
    local hh = h % 12 == 0 and 12 or h % 12
    return hh .. (h % 24 >= 12 and " pm" or " am")
end

---------------------------------------------------------------- Today

function Canvas:buildToday()
    local L = self.L.today
    local hr = tonumber(os.date("%H"))
    self:text(ctx.greeting and ctx.greeting() or "HELLO,", "sans", 15, L.label[1], L.label[2], GREY, true)
    self:pill("Focus board", L.focus[1], L.focus[2], L.focus[4], "dark", 15, L.focus[3])
    self:zone(L.focus, function() self:go("focus") end)
    self:datePill(L.date[1], L.date[2], L.date[3], L.date[4])
    self:homePill(L.home)
    self:navBar("today", L)
    if not self:dashFresh() then
        self:lines("Loading from Notion…", "sans", 17, 52, L.grid_top + 20, 340, 1, GREY)
        return
    end
    local blocks = self:dayBlocks()
    local nowm = tonumber(os.date("%H")) * 60 + tonumber(os.date("%M"))
    local isToday = self:isTodayShown()

    -- summary chips: lectures, work, tasks
    local chips = {}
    local lec = TIMETABLE[wdayOf(self:dday())]
    if lec then table.insert(chips, #lec .. " lectures") end
    for _i, b in ipairs(blocks) do
        if b.cat == "Work" then table.insert(chips, b.title .. " " .. N.hhmm(b.start) .. "–" .. N.hhmm(b.finish)) break end
    end
    local open = 0
    for _i, t in ipairs(self.dash.todos or {}) do if not N.get(t, "Done") then open = open + 1 end end
    table.insert(chips, open .. (open == 1 and " task due" or " tasks due"))
    local cx = L.label[1]
    for _i, c in ipairs(chips) do cx = cx + self:pill(c, cx, L.chips_y, 30, "light", 14) + 6 end

    -- time grid: a 14-hour window, moved 6 hours at a time
    local H, PX = L.hours, L.px
    if not self.tl_start then
        self.tl_start = isToday and math.max(0, math.min(24 - H, hr - 2)) or 6
    end
    local ws = self.tl_start
    for i = 0, H - 1 do
        local y = L.grid_top + i * PX
        self:text(hourLabel(ws + i), "sans", 12, 44, y - 8, Blitbuffer.Color8(0x44))
        local h = ws + i
        self:zone({ L.grid_x, y, L.grid_r - L.grid_x, PX }, function()
            self:openSheet({ new = true, title = "", cat = "Personal", start = h * 60, finish = (h + 1) * 60, rep = "Once" })
        end)
    end
    self:pill("▲", L.up[1], L.up[2], L.up[4], "outline", 14, L.up[3])
    self:pill("▼", L.down[1], L.down[2], L.down[4], "outline", 14, L.down[3])
    self:zone(L.up, function() self.tl_start = math.max(0, ws - 6); self:rebuild("ui") end)
    self:zone(L.down, function() self.tl_start = math.min(24 - H, ws + 6); self:rebuild("ui") end)
    local gw = L.grid_r - L.grid_x - 4
    for _i, b in ipairs(blocks) do
        local s, e = b.start / 60, b.finish / 60
        if e > ws and s < ws + H then
            local top = L.grid_top + math.max(0, (s - ws)) * PX
            local bottom = L.grid_top + math.min(H, (e - ws)) * PX
            local h = math.max(30, bottom - top - 3)
            if b.synced then
                self:box(L.grid_x, top, gw, h, BLACK, 14)
                self:lines(b.title, "sans", 15, L.grid_x + 10, top + 5, gw - 20, 1, WHITE, nil, true)
                if h > 46 then self:lines(b.sub, "sans", 12, L.grid_x + 10, top + 26, gw - 20, 1, WHITE) end
            else
                self:box(L.grid_x, top, gw, h, WHITE, 14, 3)
                self:box(L.grid_x, top, 8, h, BLACK, 4)
                self:lines(b.title, "sans", 15, L.grid_x + 16, top + 5, gw - 26, 1, BLACK, nil, true)
                if h > 46 then self:lines(b.sub, "sans", 12, L.grid_x + 16, top + 26, gw - 26, 1, GREY) end
            end
            self:zone({ L.grid_x, top, gw, h }, function() self:openSheet(b) end)
        end
    end
    if isToday and nowm / 60 >= ws and nowm / 60 < ws + H then
        local ny = L.grid_top + (nowm / 60 - ws) * PX
        self:box(L.grid_x - 6, ny - 1, L.grid_r - L.grid_x + 6, 3, BLACK)
        self:box(L.grid_x - 11, ny - 6, 12, 12, BLACK, 6)
    end

    -- now card
    local nw = L.now
    local cur, nxt
    for _i, b in ipairs(blocks) do
        if isToday and b.start <= nowm and b.finish > nowm then cur = cur or b end
        if isToday and b.start > nowm and not nxt then nxt = b end
    end
    if not isToday then nxt = blocks[1] end
    local fg = self.texfg
    if cur then
        self:text("NOW · " .. N.hhmm(cur.start) .. " – " .. N.hhmm(cur.finish), "sans", 13, nw[1] + 20, nw[2] + 18, fg, true)
        self:lines(cur.title, "serif", 28, nw[1] + 20, nw[2] + 42, nw[3] - 40, 1, fg)
        self:lines(cur.cat, "sans", 15, nw[1] + 20, nw[2] + 84, nw[3] - 40, 1, fg)
        local frac = (nowm - cur.start) / math.max(1, cur.finish - cur.start)
        self:box(nw[1] + 20, nw[2] + 118, nw[3] - 40, 10, TRACK, 5)
        self:box(nw[1] + 20, nw[2] + 118, math.max(10, (nw[3] - 40) * frac), 10, fg, 5)
    else
        self:text(isToday and "NOW · FREE" or "PLANNED", "sans", 13, nw[1] + 20, nw[2] + 18, fg, true)
        self:lines(isToday and "Free time" or (#blocks .. " blocks"), "serif", 28, nw[1] + 20, nw[2] + 42, nw[3] - 40, 1, fg)
    end
    self:lines(nxt and ("Next: " .. nxt.title .. ", " .. N.hhmm(nxt.start)) or "Nothing else planned", "sans", 14, nw[1] + 20, nw[2] + 146, nw[3] - 40, 2, fg, 20)

    -- to-dos
    local T = L.todos
    local todos = {}
    for _i, pg in ipairs(self.dash.todos or {}) do
        table.insert(todos, { pg = pg, task = N.get(pg, "Task") or "", done = N.get(pg, "Done") or false })
    end
    table.sort(todos, function(a, b) if a.done ~= b.done then return not a.done end return a.task < b.task end)
    local done = 0
    for _i, t in ipairs(todos) do if t.done then done = done + 1 end end
    self:pill(done .. "/" .. #todos, T[1] + T[3] - 86, T[2] + 16, 30, "dark", 14, 68)
    local per = L.todo_rows
    self.todo_page = self.todo_page or 1
    local pages = math.max(1, math.ceil(#todos / per))
    if self.todo_page > pages then self.todo_page = pages end
    for k = 1, per do
        local t = todos[(self.todo_page - 1) * per + k]
        if not t then break end
        local y = L.todo_y + (k - 1) * L.todo_h
        self:box(T[1] + 18, y + 8, 30, 30, t.done and BLACK or WHITE, 9, 3)
        self:lines(t.task, "sans", 16, T[1] + 60, y + 4, T[3] - 80, 2, t.done and GREY or BLACK, 20)
        self:zone({ T[1] + 8, y, T[3] - 16, L.todo_h }, function()
            local new = not t.done
            self:write(function() return N.update(t.pg.id, { Done = N.check(new) }) end,
                function() self:setProp(t.pg, "Done", new) end)
        end)
    end
    if pages > 1 then
        local y = L.todo_y + per * L.todo_h - 6
        self:text("Page " .. self.todo_page .. "/" .. pages .. "  ·  tap for more", "sans", 13, T[1] + 20, y, GREY)
        self:zone({ T[1] + 8, y - 6, T[3] - 16, 30 }, function() self.todo_page = self.todo_page % pages + 1; self:rebuild("ui") end)
    end
    if #todos == 0 then self:lines("Nothing on the list.", "sans", 15, T[1] + 20, L.todo_y + 8, T[3] - 40, 1, GREY) end
    self:zone(L.todo_add, function() self:addTodo() end)

    if self.sheet then self:drawSheet() end
end

function Canvas:addTodo()
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = _("New to-do"),
        input_hint = _("What needs doing?"),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Add"), is_enter_default = true, callback = function()
                local task = dlg:getInputText()
                UIManager:close(dlg)
                if not task or not task:match("%S") then return end
                self:write(function()
                    return N.create(N.DS.todos, { Task = N.title(task), Date = N.date(self:dday()), Done = N.check(false),
                        ["Check-in day"] = rel(self.dash.checkin) })
                end, function(pg) table.insert(self.dash.todos, pg) end)
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

---------------------------------------------------------------- the block editor sheet

local CATS = { "College", "Work", "Range", "Athlete", "Quiet Mind", "Personal", "Travel", "Nutrition" }
local REPEATS = { { "Once", "Once" }, { "Weekdays", "Weekdays" }, { "Mon to Sat", "Mon–Sat" }, { "Every day", "Every day" } }
local Y0 = 456 -- top of the sheet

function Canvas:openSheet(b)
    self.sheet = {
        new = b.new, pg = b.pg, synced = b.synced, title = b.title or "", cat = (b.cat ~= "" and b.cat) or "Personal",
        start = b.start, finish = b.finish, rep = b.rep or "Once", date = b.date, status = b.status,
    }
    self:rebuild("ui")
end

function Canvas:drawSheet()
    local d = self.sheet
    -- tapping above the sheet closes it; the sheet itself swallows stray taps
    self:zone({ 0, 0, 758, Y0 }, function() self.sheet = nil; self:rebuild("ui") end)
    self:zone({ 0, Y0, 758, 1024 - Y0 }, function() end)
    self:box(0, Y0, 758, 1024 - Y0 + 30, WHITE, 30, 4)
    self:lines(d.new and "New block" or (d.synced and d.title or "Edit block"), "serif", 26, 30, Y0 + 24, 560, 1)
    self:pill("×", 680, Y0 + 18, 48, "outline", 20, 48)
    self:zone({ 674, Y0 + 12, 60, 60 }, function() self.sheet = nil; self:rebuild("ui") end)

    if d.synced then
        self:box(30, Y0 + 90, 698, 190, BLACK, 22)
        self:text("FROM YOUR CHECK-IN", "sans", 13, 52, Y0 + 108, WHITE, true)
        self:lines(d.title .. " · " .. (d.status == "Done" and "Went" or (d.status or "")), "sans", 22, 52, Y0 + 134, 640, 1, WHITE, nil, true)
        self:text("In " .. N.hhmm(d.start) .. "  →  Out " .. N.hhmm(d.finish), "sans", 16, 52, Y0 + 168, WHITE)
        self:lines("This block follows what you log in Check-in. Mark it Missed or Holiday there, or change the in and out times, and it updates here.",
            "sans", 15, 52, Y0 + 200, 650, 3, WHITE, 21)
        self:pill("Open Check-in", 30, Y0 + 300, 60, "dark", 19, 698)
        self:zone({ 30, Y0 + 300, 698, 60 }, function() self.sheet = nil; self:go("checkin") end)
        return
    end

    -- title
    self:text("TITLE", "sans", 13, 30, Y0 + 82, GREY, true)
    self:box(30, Y0 + 102, 698, 52, LIGHT, 16)
    self:lines(d.title ~= "" and d.title or "What's this block for?", "sans", 19, 48, Y0 + 115, 660, 1, d.title ~= "" and BLACK or GREY)
    self:zone({ 30, Y0 + 98, 698, 60 }, function()
        local InputDialog = require("ui/widget/inputdialog")
        local dlg
        dlg = InputDialog:new{ title = _("Block title"), input = d.title,
            buttons = { { { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
                { text = _("OK"), is_enter_default = true, callback = function()
                    d.title = dlg:getInputText() or ""; UIManager:close(dlg); self:rebuild("ui") end } } } }
        UIManager:show(dlg)
        dlg:onShowKeyboard()
    end)
    -- category
    self:text("CATEGORY", "sans", 13, 30, Y0 + 166, GREY, true)
    local cw = (698 - 24) / 4
    for i, c in ipairs(CATS) do
        local x = 30 + ((i - 1) % 4) * (cw + 8)
        local y = Y0 + 188 + math.floor((i - 1) / 4) * 48
        self:pill(c, x, y, 40, d.cat == c and "dark" or "outline", 14, cw)
        self:zone({ x, y - 3, cw, 46 }, function() d.cat = c; self:rebuild("ui") end)
    end
    -- starts / ends, 15 minutes at a time
    for k, field in ipairs({ "start", "finish" }) do
        local x = 30 + (k - 1) * 355
        self:box(x, Y0 + 288, 343, 96, LIGHT, 20)
        self:text(k == 1 and "STARTS" or "ENDS", "sans", 13, x + 14, Y0 + 298, GREY, true)
        self:pill("–", x + 14, Y0 + 324, 48, "outline", 22, 52)
        self:centerText(N.hhmm(d[field]), "sans", 28, x + 70, Y0 + 324, 203, 48, BLACK, true)
        self:pill("+", x + 277, Y0 + 324, 48, "dark", 22, 52)
        self:zone({ x + 8, Y0 + 318, 62, 60 }, function()
            d[field] = math.max(0, d[field] - 15)
            if field == "start" and d.finish <= d.start then d.finish = d.start + 15 end
            self:rebuild("ui")
        end)
        self:zone({ x + 271, Y0 + 318, 66, 60 }, function()
            d[field] = math.min(24 * 60 - 1, d[field] + 15)
            if field == "start" and d.finish <= d.start then d.finish = d.start + 15 end
            self:rebuild("ui")
        end)
    end
    -- repeat
    self:text("REPEAT", "sans", 13, 30, Y0 + 396, GREY, true)
    for i, r in ipairs(REPEATS) do
        local x = 30 + (i - 1) * (cw + 8)
        self:pill(r[2], x, Y0 + 418, 40, d.rep == r[1] and "dark" or "outline", 14, cw)
        self:zone({ x, Y0 + 415, cw, 46 }, function() d.rep = r[1]; self:rebuild("ui") end)
    end
    -- save / delete
    local by = Y0 + 476
    if not d.new then
        self:pill("Delete", 30, by, 52, "outline", 17, 200)
        self:zone({ 30, by, 200, 52 }, function()
            self:write(function() return N.trash(d.pg.id) end, function()
                for i, pg in ipairs(self.dash.blocks) do if pg == d.pg then table.remove(self.dash.blocks, i) break end end
                self.sheet = nil
            end)
        end)
    end
    local sx = d.new and 30 or 242
    local sw = d.new and 698 or 486
    self:pill(d.new and "Add block" or "Save", sx, by, 52, "dark", 17, sw)
    self:zone({ sx, by, sw, 52 }, function() self:saveSheet() end)
end

function Canvas:saveSheet()
    local d = self.sheet
    local date = d.date or self:dday() -- a repeating block keeps its original date
    local props = {
        Block = N.title(d.title ~= "" and d.title or "Untitled block"),
        Category = N.select(d.cat),
        Repeat = N.select(d.rep),
        Planned = N.date(N.isoAt(date, N.hhmm(d.start)), N.isoAt(date, N.hhmm(d.finish))),
    }
    if d.new then
        props.Kind = N.select("Block")
        props.Status = N.select("Planned")
        props.Source = N.select("Added by me")
        props["Check-in day"] = rel(self.dash.checkin)
        self:write(function() return N.create(N.DS.blocks, props) end, function(pg)
            table.insert(self.dash.blocks, pg); self.sheet = nil
        end)
    else
        self:write(function() return N.update(d.pg.id, props) end, function(pg)
            for i, old in ipairs(self.dash.blocks) do if old == d.pg then self.dash.blocks[i] = pg end end
            self.sheet = nil
        end)
    end
end

---------------------------------------------------------------- Check-in

local MOODS = { "Foggy", "Low", "Okay", "Calm", "Bright" } -- saved as Calm 1–5
local SUPPS = { "Vit B12", "Vit D3", "Magnesium" }
local DEFAULT_TIMES = { College = { "07:30", "13:00" }, Work = { "14:00", "18:30" } }
local SLOTS = { ["7:30"] = "7:30-8:30", ["8:30"] = "8:30-9:30", ["9:45"] = "9:45-10:45", ["10:45"] = "10:45-11:45", ["12:00"] = "12:00-1:00" }

function Canvas:timeDialog(title, current, cb)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = title, input = current or "", input_hint = "HH:MM, e.g. 07:30",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Now"), callback = function() UIManager:close(dlg); cb(os.date("%H:%M")) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local v = (dlg:getInputText() or ""):gsub("%.", ":")
                UIManager:close(dlg)
                local h, m = v:match("^(%d%d?):?(%d%d)$")
                if h and tonumber(h) < 24 and tonumber(m) < 60 then cb(string.format("%02d:%s", tonumber(h), m)) end
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- Keep the "From check-in" time block in step with the attendance row.
function Canvas:syncBlock(kind)
    local att = self.dash.attend[kind]
    if not att then return end
    local status = N.get(att, "Status")
    local i, o = N.get(att, "In"), N.get(att, "Out")
    local blk
    for _i, pg in ipairs(self.dash.blocks) do
        if N.get(pg, "Source") == "From check-in" and N.get(pg, "Category") == kind then
            local pl = N.get(pg, "Planned")
            local _m, sd = N.localTime(pl and pl.start)
            if sd == self:dday() then blk = pg end
        end
    end
    local def = DEFAULT_TIMES[kind]
    local props = {
        Block = N.title(kind == "Work" and "Internship" or "College"),
        Category = N.select(kind), Kind = N.select("Block"), Source = N.select("From check-in"),
        Status = N.select(status == "Attended" and "Done" or "Skipped"),
        Planned = N.date(i and i.start or N.isoAt(self:dday(), def[1]), o and o.start or N.isoAt(self:dday(), def[2])),
        Attendance = rel(att), ["Check-in day"] = rel(self.dash.checkin),
    }
    if blk then
        local ok, pg = N.update(blk.id, props)
        if ok then for k, old in ipairs(self.dash.blocks) do if old == blk then self.dash.blocks[k] = pg end end end
    elseif status == "Attended" then
        local ok, pg = N.create(N.DS.blocks, props)
        if ok then table.insert(self.dash.blocks, pg) end
    end
end

-- Mark today's lectures to follow College: went = attended (unless skipped), otherwise missed/holiday.
function Canvas:syncLectures(status)
    local lec = TIMETABLE[wdayOf(self:dday())] or {}
    for _i, l in ipairs(lec) do
        local pg = self.dash.lectures[l[1]]
        local want = status == "Attended" and "Attended" or (status == "Holiday" and "Holiday" or "Skipped")
        if pg then
            local cur = N.get(pg, "Status")
            if status ~= "Attended" or cur == "Holiday" then
                local ok = N.update(pg.id, { Status = N.select(want) })
                if ok then self:setProp(pg, "Status", want) end
            end
        else
            local props = { Lecture = N.title(l[2] .. " · " .. N.dayTitle(self:dday())), Subject = N.select(l[1]),
                Date = N.date(self:dday()), Status = N.select(want), Slot = N.select(SLOTS[l[3]]) }
            if l[4] then props.Faculty = N.select(l[4]) end
            local ok, newpg = N.create(N.DS.lectures, props)
            if ok then self.dash.lectures[l[1]] = newpg end
        end
    end
end

function Canvas:setAttendance(kind, props, apply)
    local pg = self.dash.attend[kind]
    local statusChange = props.Status and props.Status.select and props.Status.select.name
    self:write(function()
        local ok, res
        if pg then
            ok, res = N.update(pg.id, props)
        else
            local def = DEFAULT_TIMES[kind]
            props.Day = N.title(kind .. " · " .. N.dayTitle(self:dday()))
            props.Date = N.date(self:dday())
            props.Type = N.select(kind)
            props.Status = props.Status or N.select("Attended")
            props.In = props.In or N.date(N.isoAt(self:dday(), def[1]))
            props.Out = props.Out or N.date(N.isoAt(self:dday(), def[2]))
            ok, res = N.create(N.DS.attend, props)
        end
        if not ok then return ok, res end
        self.dash.attend[kind] = res
        if kind == "College" and (statusChange or not pg) then self:syncLectures(N.get(res, "Status")) end
        self:syncBlock(kind)
        return true, res
    end, function() if apply and self.dash.attend[kind] then apply(self.dash.attend[kind]) end end)
end

function Canvas:placeRow(kind, y)
    local L = self.L.checkin
    local att = self.dash.attend[kind]
    local status = att and N.get(att, "Status")
    local x = 140
    for _i, o in ipairs({ { "Went", "Attended" }, { "Missed", "Missed" }, { "Holiday", "Holiday" } }) do
        local on = status == o[2]
        local w = self:pill(o[1], x, y + 4, 44, on and "light" or "ghost", 15)
        self:zone({ x, y, w, 52 }, function() self:setAttendance(kind, { Status = N.select(o[2]) }) end)
        x = x + w + 8
    end
    local def = DEFAULT_TIMES[kind]
    for k, field in ipairs({ "In", "Out" }) do
        local v = att and N.get(att, field)
        local m = v and N.localTime(v.start)
        local label = m and N.hhmm(m) or def[k]
        local bx = 520 + (k - 1) * 98
        self:box(bx, y, 90, 54, WHITE, 16)
        self:centerText(field:upper(), "sans", 11, bx, y + 4, 90, 16, GREY, true)
        self:centerText(label, "sans", 18, bx, y + 20, 90, 28, m and BLACK or GREY, true)
        self:zone({ bx - 2, y - 4, 94, 62 }, function()
            self:timeDialog(kind .. " · time " .. field:lower(), label, function(hhmm)
                self:setAttendance(kind, { [field] = N.date(N.isoAt(self:dday(), hhmm)) })
            end)
        end)
    end
end

function Canvas:buildCheckin()
    local L = self.L.checkin
    self:datePill(L.date[1], L.date[2], L.date[3], L.date[4])
    self:homePill(L.home)
    self:navBar("checkin", L)
    if not self:dashFresh() then
        self:lines("Loading from Notion…", "sans", 17, 52, L.supp[2] + 60, 600, 1, GREY)
        return
    end
    local fg = self.texfg
    self:placeRow("College", L.college_y)
    self:placeRow("Work", L.work_y)

    -- lectures
    local lec = TIMETABLE[wdayOf(self:dday())]
    local catt = self.dash.attend.College
    local cstatus = catt and N.get(catt, "Status")
    if lec then
        local attended = 0
        local tw = (698 - 44 - 4 * 8) / 5
        for i, l in ipairs(lec) do
            if i > 5 then break end
            local pg = self.dash.lectures[l[1]]
            local st = pg and N.get(pg, "Status") or (cstatus == "Attended" and "Attended" or nil)
            local on = st == "Attended"
            if on then attended = attended + 1 end
            local x = 52 + (i - 1) * (tw + 8)
            local meta = l[3] .. (l[4] and (" · " .. l[4]:match("(%S+)$")) or "")
            if not cstatus then meta = l[3] elseif cstatus ~= "Attended" then meta = (cstatus == "Missed" and "Missed" or cstatus) elseif not on then meta = st or "Skipped" end
            if on then self:box(x, L.lect_y, tw, 56, WHITE, 16) else self:box(x, L.lect_y, tw, 56, nil, 16, 2, fg) end
            self:centerText(l[2], "sans", 15, x, L.lect_y + 6, tw, 22, on and BLACK or fg, true)
            self:centerText(meta, "sans", 12, x, L.lect_y + 30, tw, 18, on and GREY or fg)
            self:zone({ x, L.lect_y - 4, tw, 64 }, function()
                local new = on and "Skipped" or "Attended"
                self:write(function()
                    if pg then return N.update(pg.id, { Status = N.select(new) }) end
                    local props = { Lecture = N.title(l[2] .. " · " .. N.dayTitle(self:dday())), Subject = N.select(l[1]),
                        Date = N.date(self:dday()), Status = N.select(new), Slot = N.select(SLOTS[l[3]]) }
                    if l[4] then props.Faculty = N.select(l[4]) end
                    return N.create(N.DS.lectures, props)
                end, function(res)
                    if pg then self:setProp(pg, "Status", new) else self.dash.lectures[l[1]] = res end
                end)
            end)
        end
        local cnt = attended .. "/" .. math.min(5, #lec) .. " attended"
        self:text(cnt, "sans", 14, 706 - 110, L.lect_label_y - 2, fg, true)
    else
        self:lines("No timetable for this day yet. Send Claude your weekly timetable to see lectures here.", "sans", 14, 52, L.lect_y + 6, 640, 2, fg, 20)
    end

    -- supplements
    local row = self.dash.checkin
    local sw = (698 - 44 - 20) / 3
    for i, sname in ipairs(SUPPS) do
        local on = row and N.get(row, sname) or false
        local x = 52 + (i - 1) * (sw + 10)
        self:pill(sname, x, L.supp_y, 46, on and "dark" or "outline", 17, sw)
        self:zone({ x, L.supp_y - 4, sw, 54 }, function()
            self:checkinRow(function(pg)
                local new = not (N.get(pg, sname) or false)
                self:write(function() return N.update(pg.id, { [sname] = N.check(new) }) end,
                    function() self:setProp(pg, sname, new) end)
            end)
        end)
    end
    -- period day
    local period = row and N.get(row, "Period day") or false
    local P = L.period
    self:pill("Period day", P[1], P[2], P[4], period and "dark" or "outline", 15, P[3])
    self:zone(P, function()
        self:checkinRow(function(pg)
            local new = not (N.get(pg, "Period day") or false)
            self:write(function() return N.update(pg.id, { ["Period day"] = N.check(new) }) end,
                function() self:setProp(pg, "Period day", new) end)
        end)
    end)
    -- mood (saved as Calm 1–5)
    local calm = row and N.get(row, "Calm")
    local mw = (698 - 44 - 32) / 5
    for i, m in ipairs(MOODS) do
        local x = 52 + (i - 1) * (mw + 8)
        self:pill(m, x, L.mood_y, 40, calm == i and "dark" or "outline", 16, mw)
        self:zone({ x, L.mood_y - 4, mw, 48 }, function()
            self:checkinRow(function(pg)
                self:write(function() return N.update(pg.id, { Calm = N.num(i) }) end,
                    function() self:setProp(pg, "Calm", i) end)
            end)
        end)
    end

    -- herbal tea
    local tea = row and N.get(row, "Herbal tea") or 0
    local Tt = L.tea
    self:centerText(tostring(tea), "sans", 26, Tt[1] + 18, Tt[2] + 40, 70, 70, BLACK, true)
    self:pill("–", Tt[1] + 108, Tt[2] + 88, 40, "outline", 22, 50)
    self:pill("+", Tt[1] + 166, Tt[2] + 88, 40, "dark", 22, 50)
    local function setTea(v)
        self:checkinRow(function(pg)
            self:write(function() return N.update(pg.id, { ["Herbal tea"] = N.num(v) }) end,
                function() self:setProp(pg, "Herbal tea", v) end)
        end)
    end
    self:zone({ Tt[1] + 104, Tt[2] + 82, 56, 54 }, function() if tea > 0 then setTea(tea - 1) end end)
    self:zone({ Tt[1] + 162, Tt[2] + 82, 56, 54 }, function() setTea(tea + 1) end)

    -- sleep (Sleep Log, linked to today's check-in)
    local S = L.sleep
    local sl = self.dash.sleep
    local span = sl and N.get(sl, "Sleep")
    local s0, s1 = span and N.localTime(span.start), span and N.localTime(span.finish)
    local hours = (s0 and s1) and (((s1 - s0) % 1440) / 60) or nil
    self:centerText(hours and string.format("%g", math.floor(hours * 2 + 0.5) / 2) or "–", "sans", 24, S[1] + 18, S[2] + 40, 70, 70, BLACK, true)
    self:pill("–", S[1] + 108, S[2] + 88, 40, "outline", 22, 50)
    self:pill("+", S[1] + 166, S[2] + 88, 40, "dark", 22, 50)
    local function setSleep(h)
        self:checkinRow(function(pg)
            local wake = s1 or (7 * 60)
            local bed = wake - math.floor(h * 60 + 0.5)
            local bedDate = self:dday()
            if bed < 0 then bed = bed + 1440; bedDate = N.prevDay(self:dday()) end
            local props = { Sleep = N.date(N.isoAt(bedDate, N.hhmm(bed)), N.isoAt(self:dday(), N.hhmm(wake))) }
            self:write(function()
                if sl then return N.update(sl.id, props) end
                props.Night = N.title("Night before " .. N.dayTitle(self:dday()))
                props["Check-in day"] = rel(pg)
                return N.create(N.DS.sleep, props)
            end, function(res) self.dash.sleep = res end)
        end)
    end
    self:zone({ S[1] + 104, S[2] + 82, 56, 54 }, function() setSleep(math.max(0, (hours or 8) - 0.5)) end)
    self:zone({ S[1] + 162, S[2] + 82, 56, 54 }, function() setSleep(math.min(14, (hours or 7) + 0.5)) end)

    -- save
    self:zone(L.save, function()
        UIManager:show(InfoMessage:new{ text = _("Check-in saved to Notion."), timeout = 2 })
        self:go("today")
    end)
end

end
