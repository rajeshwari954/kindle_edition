--[[
Log and Work screens, matching the finalised designs (Log.dc.html, Cases.dc.html).
Log writes to the Strength, Food, Sleep, Talk, Reading and Expenses logs; Reading also syncs what
you read on the Kindle (KOReader's statistics) into the Reading Log. Work reads and edits the Work database.
Installed onto Canvas by main.lua: dofile("logwork.lua")(Canvas, ctx).
]]

local DataStorage = require("datastorage")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

return function(Canvas, ctx)
local N, px, py = ctx.N, ctx.px, ctx.py
local BLACK, WHITE, GREY, LIGHT = ctx.BLACK, ctx.WHITE, ctx.GREY, ctx.LIGHT

---------------------------------------------------------------- shared form bits

function Canvas:askText(title, value, cb, numeric)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = title, input = value or "", input_type = numeric and "number" or nil,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("OK"), is_enter_default = true, callback = function()
                local v = dlg:getInputText() or ""
                UIManager:close(dlg)
                cb(v)
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- a labelled input box; tapping it opens the keyboard
function Canvas:field(label, value, hint, x, y, w, cb, numeric)
    if label then self:text(label, "sans", 13, x, y, GREY, true) end
    local by = label and (y + 20) or y
    self:box(x, by, w, 50, LIGHT, 16)
    local shown = (value and tostring(value) ~= "") and tostring(value) or hint
    self:lines(shown or "", "sans", 17, x + 14, by + 14, w - 28, 1, (value and tostring(value) ~= "") and BLACK or GREY)
    self:zone({ x, by - 4, w, 58 }, function()
        self:askText(label or hint or "", value, function(v) cb(v) self:rebuild("ui") end, numeric)
    end)
end

-- a row of choice pills; returns nothing. opts = list of labels (or {value, label})
function Canvas:choices(opts, current, x, y, w, cols, h, cb, multi)
    local gap = 8
    local cw = (w - gap * (cols - 1)) / cols
    for i, o in ipairs(opts) do
        local v, label = o, o
        if type(o) == "table" then v, label = o[1], o[2] end
        local on
        if multi then on = current and current[v] else on = current == v end
        local cx = x + ((i - 1) % cols) * (cw + gap)
        local cy = y + math.floor((i - 1) / cols) * (h + gap)
        self:pill(tostring(label), cx, cy, h, on and "dark" or "outline", 14, cw)
        self:zone({ cx, cy - 3, cw, h + 6 }, function() cb(v) self:rebuild("ui") end)
    end
end

local function num(v) return tonumber((tostring(v or "")):match("[%d%.]+")) end

-- today's Daily Check-in row (for linking); found or created when needed
function Canvas:checkinFor(day, cb)
    if self.dash and self.dash.date == day and self.dash.checkin then return cb(self.dash.checkin) end
    local ok, res = N.query(N.DS.checkin, { property = "Date", date = { equals = day } })
    if ok and res[1] then return cb(res[1]) end
    local ok2, pg = N.create(N.DS.checkin, { Day = N.title(N.dayTitle(day)), Date = N.date(day) })
    cb(ok2 and pg or nil)
end

local function rel(pg) return pg and { relation = { { id = pg.id } } } or nil end

---------------------------------------------------------------- Kindle reading (KOReader statistics)

local PAPERS = { "The Times of India", "The Hindu", "The Economic Times", "LiveLaw" }

local function kindleToday()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then return {} end
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(path, "mode") ~= "file" then return {} end
    local t = os.date("*t")
    local midnight = os.time{ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 }
    local sql = string.format([[
        SELECT book.title, count(DISTINCT page_stat_data.page), sum(page_stat_data.duration),
               max(page_stat_data.page), max(page_stat_data.total_pages)
        FROM page_stat_data JOIN book ON book.id = page_stat_data.id_book
        WHERE page_stat_data.start_time >= %d
        GROUP BY book.id ORDER BY max(page_stat_data.start_time) DESC]], midnight)
    local okc, conn = pcall(SQ3.open, path)
    if not okc or not conn then return {} end
    local okq, res = pcall(conn.exec, conn, sql)
    pcall(conn.close, conn)
    if not okq or not res or not res[1] then return {} end
    local out = {}
    for i = 1, #res[1] do
        local title = tostring(res[1][i] or "")
        local kind, name = "Book", title
        for _j, p in ipairs(PAPERS) do
            if title:find(p, 1, true) then kind, name = "Newspaper", p end
        end
        if title:match("^Substacks") then kind, name = "Substack", "Substack digest" end
        local pages = tonumber(res[2][i]) or 0
        local mins = math.max(1, math.floor((tonumber(res[3][i]) or 0) / 60 + 0.5))
        local page, total = tonumber(res[4][i]) or 0, tonumber(res[5][i]) or 0
        local pct = (total > 0) and math.min(1, page / total) or nil
        table.insert(out, { title = name, kind = kind, pages = pages, mins = mins, pct = pct,
            amount = kind == "Book" and (pages .. " pages" .. (pct and (" · " .. math.floor(pct * 100) .. "%") or "")) or (mins .. " min") })
    end
    return out
end

---------------------------------------------------------------- calorie goals by where you are

-- Your daily targets. "loc" is what's written to the check-in's Location.
local GOALS = {
    home1 = { name = "Home 1 · Mumbai", loc = "Mumbai", kcal = 1900, protein = 120, carbs = 200, fat = 65 },
    home2 = { name = "Home 2 / travel", loc = "Home 2/travel", kcal = 1500, protein = 100, carbs = 140, fat = 60 },
}
ctx.GOALS = GOALS

local function profileFromText(t)
    t = (t or ""):lower()
    if t == "" then return nil end
    if t:find("mumbai") or t:find("home 1") or t:find("home1") then return "home1" end
    return "home2"
end

-- the Wi-Fi network the Kindle is on (nil when offline or not on a Kindle)
local function wifiName()
    local ok, p = pcall(io.popen, "lipc-get-prop com.lab126.wifid currentEssid 2>/dev/null")
    if not ok or not p then return nil end
    local name = (p:read("*a") or ""):match("^%s*(.-)%s*$")
    p:close()
    return (name ~= "" and name) or nil
end

-- where you are today: the check-in's Location, else the Wi-Fi network you've linked, else your last choice
function Canvas:goalProfile()
    local ci = self.logd and self.logd.checkin
    local fromCheckin = ci and profileFromText(N.get(ci, "Location"))
    if fromCheckin then return fromCheckin, "check-in" end
    local ssid = wifiName()
    local known = G_reader_settings:readSetting("selfv2_wifi_place") or {}
    if ssid and known[ssid] then return known[ssid], "Wi-Fi" end
    return G_reader_settings:readSetting("selfv2_place") or "home1", nil
end

-- choose where you are: remembered, linked to this Wi-Fi network, and saved on today's check-in
function Canvas:setPlace(key)
    G_reader_settings:saveSetting("selfv2_place", key)
    local ssid = wifiName()
    if ssid then
        local known = G_reader_settings:readSetting("selfv2_wifi_place") or {}
        known[ssid] = key
        G_reader_settings:saveSetting("selfv2_wifi_place", known)
    end
    local day = self:dday()
    ctx.online(function()
        self:checkinFor(day, function(ci)
            if not ci then return end
            local ok, res = N.update(ci.id, { Location = N.text(GOALS[key].loc) })
            if ok and self.logd then self.logd.checkin = res end
            self:rebuild("ui")
        end)
    end)
    self:rebuild("ui")
end

function Canvas:placeMenu()
    local ButtonDialog = require("ui/widget/buttondialog")
    local cur = self:goalProfile()
    local dlg
    local function opt(key)
        local g = GOALS[key]
        return { { text = g.name .. string.format("  ·  %d kcal", g.kcal) .. (cur == key and "  ✓" or ""),
            callback = function() UIManager:close(dlg); self:setPlace(key) end } }
    end
    dlg = ButtonDialog:new{
        title = "Where are you today? Your calorie goal follows this. On Wi-Fi, the Kindle remembers this network for next time.",
        buttons = { opt("home1"), opt("home2"), { { text = "Close", callback = function() UIManager:close(dlg) end } } },
    }
    UIManager:show(dlg)
end

---------------------------------------------------------------- Log: data

function Canvas:logFresh() return self.logd and self.logd.date == self:dday() and self.logd.loaded end

function Canvas:loadLog()
    if not N.token() then self.plugin:notionSetup(false) return end
    ctx.online(function()
        local day = self:dday()
        local d = { date = day, food = {}, reading = {} }
        local ok, res = N.query(N.DS.food, { property = "Date", date = { equals = day } })
        if not ok then self:notionError(res) return end
        d.food = res
        ok, res = N.query(N.DS.reading, { property = "Date", date = { equals = day } })
        if ok then d.reading = res end
        ok, res = N.query(N.DS.checkin, { property = "Date", date = { equals = day } })
        if ok then d.checkin = res[1] end
        d.loaded = true
        self.logd = d
        self:rebuild("full")
    end)
end

-- Put what was read on the Kindle today into the Reading Log (one row per book, updated as you read).
function Canvas:syncReading()
    if self:dday() ~= N.today() then return end
    local items = kindleToday()
    if #items == 0 then return end
    ctx.online(function()
        self:checkinFor(N.today(), function(ci)
            for _i, it in ipairs(items) do
                local existing
                for _j, pg in ipairs(self.logd.reading) do
                    if N.get(pg, "Title") == it.title and N.get(pg, "Source") == "From Kindle" then existing = pg end
                end
                local props = {
                    ["Pages / Minutes"] = N.num(it.kind == "Book" and it.pages or it.mins),
                    Progress = it.pct and N.num(math.floor(it.pct * 100) / 100) or nil,
                }
                if existing then
                    N.update(existing.id, props)
                else
                    props.Title = N.title(it.title)
                    props.Type = N.select(it.kind)
                    props.Date = N.date(N.today())
                    props.Source = N.select("From Kindle")
                    if it.kind == "Newspaper" then props.Area = N.select("Current Affairs") end
                    props["Check-in day"] = rel(ci)
                    local ok, pg = N.create(N.DS.reading, props)
                    if ok then table.insert(self.logd.reading, pg) end
                end
            end
            self.logd.synced = os.date("%H:%M")
            self:rebuild("ui")
        end)
    end)
end

---------------------------------------------------------------- Log: screen

local KINDS = {
    { "Strength", "Lower · Upper" }, { "Food", "Meals · calories" }, { "Sleep", "Bed · Wake" },
    { "Speech", "Self-talk practice" }, { "Reading", "Synced from Kindle" }, { "Expense", "This month" },
}
local SESSIONS = { "Lower", "Upper", "Plyometrics", "Cardio", "Walk", "Skipped" }
local MEALS = { "Breakfast", "Brunch", "Lunch", "Snack", "Dinner" }
local READ_TYPES = { "Book", "Article", "Judgement", "Newspaper", "Substack" }
local EXP_CATS = { "Food", "Transport", "Shopping", "Health", "Subscriptions", "Travel", "Rent", "Other" }

function Canvas:logIcon(kind, x, y, bg)
    self:box(x, y, 40, 40, bg, 20)
    local cx, cy = x + 20, y + 20
    if kind == "Strength" then
        self:box(cx - 10, cy - 1, 20, 3, BLACK)
        self:box(cx - 12, cy - 6, 4, 13, BLACK, 1)
        self:box(cx + 8, cy - 6, 4, 13, BLACK, 1)
    elseif kind == "Food" then
        self:box(cx - 9, cy - 9, 18, 18, nil, 9, 2)
        self:box(cx - 3, cy - 3, 6, 6, BLACK, 3)
    elseif kind == "Sleep" then
        self:box(cx - 9, cy - 9, 18, 18, BLACK, 9)
        self:box(cx - 4, cy - 12, 16, 16, bg, 8)
    elseif kind == "Speech" then
        self:box(cx - 4, cy - 10, 8, 14, BLACK, 4)
        self:box(cx - 1, cy + 4, 2, 5, BLACK)
        self:box(cx - 5, cy + 9, 10, 2, BLACK)
    elseif kind == "Reading" then
        self:box(cx - 9, cy - 8, 18, 16, nil, 2, 2)
        self:box(cx - 1, cy - 8, 2, 16, BLACK)
    else
        self:centerText("₹", "sans", 18, x, y, 40, 40, BLACK, true)
    end
end

function Canvas:buildLog()
    local L = self.L.log
    self:datePill(L.date[1], L.date[2], L.date[3], L.date[4])
    self:homePill(L.home)
    self:navBar("log", L)
    self.logk = self.logk or "Food"
    self.ldraft = self.ldraft or {}
    local kind = self.logk
    self.ldraft[kind] = self.ldraft[kind] or {}
    local d = self.ldraft[kind]

    -- tiles
    local tw = (698 - 24) / 3
    for i, k in ipairs(KINDS) do
        local x = 30 + ((i - 1) % 3) * (tw + 12)
        local y = L.tiles_y + math.floor((i - 1) / 3) * (L.tile_h + 12)
        local on = k[1] == kind
        self:box(x, y, tw, L.tile_h, on and BLACK or WHITE, 24)
        self:logIcon(k[1], x + 16, y + 12, on and WHITE or LIGHT)
        self:text(k[1], "sans", 19, x + 16, y + 56, on and WHITE or BLACK, true)
        self:text(k[2], "sans", 13, x + 16, y + 78, on and LIGHT or GREY)
        self:zone({ x, y, tw, L.tile_h }, function()
            self.logk = k[1]
            self:rebuild("ui")
            if k[1] == "Reading" and self:logFresh() then self:syncReading() end
        end)
    end

    -- form header
    local F = L.form
    local fx, fw = F[1] + 22, F[3] - 44
    self:lines("New " .. kind:lower() .. " entry", "serif", 23, fx, F[2] + 16, fw - 140, 1)
    self:pill(self:isTodayShown() and "Today" or (os.date("%d %b", N.dateTime(self:dday())):gsub("^0", "")), F[1] + F[3] - 122, F[2] + 16, 30, "grey", 13, 100)
    if not self:logFresh() then
        self:lines("Loading from Notion…", "sans", 16, fx, F[2] + 70, fw, 1, GREY)
        return
    end
    local y = F[2] + 62
    local set = function(k) return function(v) d[k] = v end end

    if kind == "Strength" then
        self:text("SESSION", "sans", 13, fx, y, GREY, true)
        self:choices(SESSIONS, d.session, fx, y + 22, fw, 3, 42, function(v) d.session = v end)
        self:field("HOW IT FELT", d.felt, "Strong, tired, new best…", fx, y + 124, fw, set("felt"))
        self:field("NOTES", d.notes, "Anything to remember", fx, y + 206, fw, set("notes"))
    elseif kind == "Food" then
        local P = L.patch_food
        self:put(ImageWidget:new{ file = ctx.plugin_dir .. "/screens/patch_food" .. (self.night and "_night" or "") .. ".png",
            width = px(P[3]), height = py(P[4]), file_do_cache = false, original_in_nightmode = true }, P[1], P[2])
        local kcal, pr, cb, ft = 0, 0, 0, 0
        for _i, pg in ipairs(self.logd.food) do
            kcal = kcal + (N.get(pg, "Calories") or 0)
            pr = pr + (N.get(pg, "Protein (g)") or 0)
            cb = cb + (N.get(pg, "Carbs (g)") or 0)
            ft = ft + (N.get(pg, "Fat (g)") or 0)
        end
        local fg = self.texfg
        local key = self:goalProfile()
        local g = GOALS[key]
        -- where you are (tap to change) and today against that goal
        self:text("TODAY · " .. g.name:upper() .. "  ›", "sans", 12, P[1] + 16, P[2] + 12, fg, true)
        self:zone({ P[1], P[2], 250, 34 }, function() self:placeMenu() end)
        local w = self:text(tostring(math.floor(kcal)), "sans", 28, P[1] + 16, P[2] + 32, fg, true):getSize().w / px(100) * 100
        self:text("/ " .. g.kcal .. " kcal", "sans", 14, P[1] + 22 + w, P[2] + 44, fg)
        local left = g.kcal - kcal
        self:text((left >= 0 and (math.floor(left) .. " left") or (math.floor(-left) .. " over")) .. " · " .. #self.logd.food
            .. (#self.logd.food == 1 and " meal" or " meals"), "sans", 13, P[1] + 16, P[2] + 70, fg, left < 0)
        local mx = P[1] + 260
        local mw = (P[3] - 260 - 16 - 20) / 3
        for i, m in ipairs({ { "Protein", pr, g.protein }, { "Carbs", cb, g.carbs }, { "Fat", ft, g.fat } }) do
            local x = mx + (i - 1) * (mw + 10)
            self:text(m[1], "sans", 12, x, P[2] + 22, fg, true)
            self:text(math.floor(m[2]) .. "/" .. m[3] .. " g", "sans", 11, x, P[2] + 40, fg)
            self:box(x, P[2] + 62, mw, 6, ctx.TRACK, 3)
            self:box(x, P[2] + 62, math.max(6, mw * math.min(1, m[2] / m[3])), 6, fg, 3)
        end
        local yy = P[2] + P[4] + 12
        self:choices(MEALS, d.meal or "Lunch", fx, yy, fw, 5, 42, function(v) d.meal = v end)
        self:field(nil, d.what, "What did you eat? e.g. Poha and chai", fx, yy + 54, fw, set("what"))
        local ky = yy + 118
        local unit = (fw - 24) / 4.5
        local kw = unit * 1.5
        self:text("CALORIES (KCAL)", "sans", 12, fx, ky, GREY, true)
        self:pill("–", fx, ky + 20, 48, "outline", 20, 40)
        self:box(fx + 46, ky + 20, kw - 92, 48, LIGHT, 14)
        self:centerText(tostring(d.kcal or 450), "sans", 21, fx + 46, ky + 20, kw - 92, 48, BLACK, true)
        self:pill("+", fx + kw - 40, ky + 20, 48, "dark", 20, 40)
        self:zone({ fx - 4, ky + 16, 48, 56 }, function() d.kcal = math.max(0, (d.kcal or 450) - 50); self:rebuild("ui") end)
        self:zone({ fx + kw - 44, ky + 16, 48, 56 }, function() d.kcal = (d.kcal or 450) + 50; self:rebuild("ui") end)
        for i, m in ipairs({ { "PROTEIN G", "protein" }, { "CARBS G", "carbs" }, { "FAT G", "fat" } }) do
            local x = fx + kw + 8 + (i - 1) * (unit + 8)
            self:field(m[1], d[m[2]], "0", x, ky, unit, set(m[2]), true)
        end
    elseif kind == "Sleep" then
        local hw = (fw - 12) / 2
        self:field("BEDTIME", d.bed, "23:00", fx, y, hw, set("bed"), true)
        self:field("WOKE UP", d.wake, "06:15", fx + hw + 12, y, hw, set("wake"), true)
        self:text("HOW DID YOU WAKE UP?", "sans", 13, fx, y + 92, GREY, true)
        self:choices({ "Rested", "Okay", "Tired" }, d.feel, fx, y + 114, fw, 3, 42, function(v) d.feel = v end)
        self:text("SLEEP QUALITY (1–5)", "sans", 13, fx, y + 174, GREY, true)
        self:choices({ 1, 2, 3, 4, 5 }, d.quality, fx, y + 196, fw, 5, 42, function(v) d.quality = v end)
    elseif kind == "Speech" then
        self:field("TOPIC", d.topic, "What did you speak on?", fx, y, fw, set("topic"))
        self:field("MINUTES SPOKEN", d.mins, "10", fx, y + 82, 200, set("mins"), true)
        self:text("SELF-RATING (1–5)", "sans", 13, fx + 216, y + 82, GREY, true)
        self:choices({ 1, 2, 3, 4, 5 }, d.rating, fx + 216, y + 104, fw - 216, 5, 46, function(v) d.rating = v end)
        self:field("ONE THING TO FIX", d.fix, "e.g. fewer fillers", fx, y + 164, fw, set("fix"))
    elseif kind == "Reading" then
        local P = L.patch_read
        self:put(ImageWidget:new{ file = ctx.plugin_dir .. "/screens/patch_read" .. (self.night and "_night" or "") .. ".png",
            width = px(P[3]), height = py(P[4]), file_do_cache = false, original_in_nightmode = true }, P[1], P[2])
        local fg = self.texfg
        self:text("FROM YOUR KINDLE · TODAY", "sans", 12, P[1] + 16, P[2] + 12, fg, true)
        if self.logd.synced then self:pill("Synced " .. self.logd.synced, P[1] + P[3] - 130, P[2] + 8, 24, "ghost", 11, 114) end
        local items = (self:dday() == N.today()) and kindleToday() or {}
        if #items == 0 then
            self:lines("Nothing read on the Kindle yet today.", "sans", 15, P[1] + 16, P[2] + 50, P[3] - 32, 1, fg)
        end
        for i, it in ipairs(items) do
            if i > 3 then break end
            local ry = P[2] + 40 + (i - 1) * 34
            self:box(P[1] + 16, ry + 4, P[3] - 32, 1, fg)
            self:pill(it.kind, P[1] + 16, ry + 8, 22, "light", 11)
            self:lines(it.title, "sans", 15, P[1] + 130, ry + 10, P[3] - 270, 1, fg, nil, true)
            self:text(it.amount, "sans", 13, P[1] + P[3] - 128, ry + 10, fg, true)
        end
        local yy = P[2] + P[4] + 12
        self:text("READ SOMETHING OFF THE KINDLE? ADD IT", "sans", 13, fx, yy, GREY, true)
        self:choices(READ_TYPES, d.rtype or "Judgement", fx, yy + 22, fw, 5, 40, function(v) d.rtype = v end)
        self:field(nil, d.title, "Title, e.g. a judgment or article", fx, yy + 74, fw, set("title"))
        local pw = (fw - 8) / 3.2
        self:field(nil, d.amount, "Pages / min", fx, yy + 134, pw, set("amount"), true)
        self:field(nil, d.takeaway, "One takeaway (optional)", fx + pw + 8, yy + 134, fw - pw - 8, set("takeaway"))
    else -- Expense
        self:field("AMOUNT (₹)", d.amount, "0", fx, y, 220, set("amount"), true)
        self:field("NOTE", d.note, "Optional", fx + 236, y, fw - 236, set("note"))
        self:text("CATEGORY", "sans", 13, fx, y + 86, GREY, true)
        self:choices(EXP_CATS, d.cat, fx, y + 108, fw, 4, 42, function(v) d.cat = v end)
    end

    self:pill("Add to " .. kind:lower() .. " log", L.add[1], L.add[2], L.add[4], "dark", 19, L.add[3])
    self:zone(L.add, function() self:addLog(kind) end)
end

local function hhmm(v)
    local h, m = tostring(v or ""):gsub("%.", ":"):match("^(%d%d?):?(%d%d)$")
    if h and tonumber(h) < 24 and tonumber(m) < 60 then return string.format("%02d:%s", tonumber(h), m) end
    return nil
end

function Canvas:addLog(kind)
    local d = self.ldraft[kind] or {}
    local day = self:dday()
    local need
    if kind == "Strength" and not d.session then need = "Pick a session first." end
    if kind == "Food" and not (d.what and d.what:match("%S")) then need = "Say what you ate first." end
    if kind == "Sleep" and not (hhmm(d.bed) and hhmm(d.wake)) then need = "Add bedtime and wake-up time as HH:MM." end
    if kind == "Speech" and not (d.topic and d.topic:match("%S")) then need = "Add the topic first." end
    if kind == "Reading" and not (d.title and d.title:match("%S")) then need = "Add a title first." end
    if kind == "Expense" and not num(d.amount) then need = "Add the amount first." end
    if need then UIManager:show(InfoMessage:new{ text = need, timeout = 2 }) return end

    ctx.online(function()
        self:checkinFor(day, function(ci)
            local ds, props
            if kind == "Strength" then
                ds = N.DS.strength
                props = { Exercise = N.title(d.session .. " · " .. N.dayTitle(day)), Session = N.multi({ d.session }),
                    Date = N.date(day), Notes = N.text(table.concat({ d.felt or "", d.notes or "" }, (d.felt and d.notes) and " · " or "")) }
            elseif kind == "Food" then
                ds = N.DS.food
                props = { Item = N.title(d.what), Meal = N.select(d.meal or "Lunch"), Calories = N.num(d.kcal or 450), Date = N.date(day),
                    ["Protein (g)"] = num(d.protein) and N.num(num(d.protein)) or nil, ["Carbs (g)"] = num(d.carbs) and N.num(num(d.carbs)) or nil,
                    ["Fat (g)"] = num(d.fat) and N.num(num(d.fat)) or nil }
            elseif kind == "Sleep" then
                ds = N.DS.sleep
                local bed, wake = hhmm(d.bed), hhmm(d.wake)
                local bedDay = (bed > wake) and N.prevDay(day) or day
                props = { Night = N.title("Night before " .. N.dayTitle(day)), Sleep = N.date(N.isoAt(bedDay, bed), N.isoAt(day, wake)),
                    ["Woke up feeling"] = d.feel and N.select(d.feel) or nil, ["Quality (1-5)"] = d.quality and N.num(d.quality) or nil }
            elseif kind == "Speech" then
                ds = N.DS.talk
                props = { Topic = N.title(d.topic), Date = N.date(day), ["Talk (min)"] = num(d.mins) and N.num(num(d.mins)) or nil,
                    ["Self-rating (1-5)"] = d.rating and N.num(d.rating) or nil, Notes = d.fix and N.text(d.fix) or nil }
            elseif kind == "Reading" then
                ds = N.DS.reading
                local t = d.rtype or "Judgement"
                props = { Title = N.title(d.title), Type = N.select(t), Date = N.date(day), Source = N.select("Typed by me"),
                    ["Pages / Minutes"] = num(d.amount) and N.num(num(d.amount)) or nil, Takeaway = d.takeaway and N.text(d.takeaway) or nil }
                if t == "Newspaper" then props.Area = N.select("Current Affairs") end
                if t == "Judgement" then props.Area = N.select("Case Laws & Judgements") end
            else
                ds = N.DS.expenses
                props = { Item = N.title((d.note and d.note:match("%S")) and d.note or (d.cat or "Expense")), Amount = N.num(num(d.amount)),
                    Category = N.select(d.cat or "Other"), Date = N.date(day) }
            end
            props["Check-in day"] = (kind ~= "Expense") and rel(ci) or nil
            local ok, res = N.create(ds, props)
            if not ok then self:notionError(res) return end
            if kind == "Food" then table.insert(self.logd.food, res) end
            if kind == "Reading" then table.insert(self.logd.reading, res) end
            if kind == "Strength" and d.session ~= "Skipped" and ci then N.update(ci.id, { Gym = N.check(true) }) end
            if kind == "Sleep" and self.dash and self.dash.date == day then self.dash.sleep = res end
            self.ldraft[kind] = {}
            UIManager:show(InfoMessage:new{ text = "Added to the " .. kind:lower() .. " log.", timeout = 2 })
            self:rebuild("ui")
        end)
    end)
end

---------------------------------------------------------------- Work: data

local TYPES = { "Research", "Drafting", "Proofreading", "Notes & summary", "Filing", "Court visit", "Client meeting", "Admin" }
local STAGES = { { "To do", "To do" }, { "In progress", "In progress" }, { "With chief for review", "With chief" },
    { "Changes asked", "Changes" }, { "Done", "Done" } }
local FILTERS = { "Open", "Due this week", "With chief", "Done" }

function Canvas:workFresh() return self.workd and self.workd.loaded end

function Canvas:loadWork()
    if not N.token() then self.plugin:notionSetup(false) return end
    ctx.online(function()
        local ok, res = N.query(N.DS.work, nil, { { property = "Deadline", direction = "ascending" } })
        if not ok then self:notionError(res) return end
        self.workd = { loaded = true, tasks = res }
        self:rebuild("full")
    end)
end

local function dueLabel(date)
    if not date then return "no date" end
    return (os.date("%a %d %b", N.dateTime(date)):gsub(" 0", " "))
end

local function taskOf(pg)
    local dl = N.get(pg, "Deadline")
    return { pg = pg, task = N.get(pg, "Task") or "", matter = N.get(pg, "Matter") or "", caseNo = N.get(pg, "Case no.") or "",
        types = N.get(pg, "Work type") or {}, stage = N.get(pg, "Stage") or "To do", prio = N.get(pg, "Priority") or "Medium",
        due = dl and dl.start and dl.start:sub(1, 10) or nil, by = N.get(pg, "Assigned by") or "", notes = N.get(pg, "Notes") or "" }
end

---------------------------------------------------------------- Work: screen

function Canvas:buildWork()
    local L = self.L.work
    self:datePill(L.date[1], L.date[2], L.date[3], L.date[4])
    self:homePill(L.home)
    self:navBar("work", L)
    if not self:workFresh() then
        self:lines("Loading from Notion…", "sans", 17, 52, L.cards_y + 20, 600, 1, GREY)
        return
    end
    local today = N.today()
    local weekEnd = today
    for _i = 1, 6 do weekEnd = N.nextDay(weekEnd) end
    local all = {}
    for _i, pg in ipairs(self.workd.tasks) do table.insert(all, taskOf(pg)) end
    local open = {}
    for _i, t in ipairs(all) do if t.stage ~= "Done" then table.insert(open, t) end end
    table.sort(open, function(a, b) return (a.due or "9999") < (b.due or "9999") end)
    local nx = open[1]

    -- due next (on lace)
    local Nx = L.next
    local fg = self.texfg
    if nx then
        self:text("DUE NEXT · " .. dueLabel(nx.due):upper(), "sans", 13, Nx[1] + 22, Nx[2] + 18, fg, true)
        self:lines(nx.task, "serif", 26, Nx[1] + 22, Nx[2] + 42, Nx[3] - 44, 1, fg)
        self:lines(nx.matter .. (nx.caseNo ~= "" and (" · " .. nx.caseNo) or ""), "sans", 15, Nx[1] + 22, Nx[2] + 82, Nx[3] - 44, 1, fg)
        local px0 = Nx[1] + 22
        for _i, ty in ipairs(nx.types) do px0 = px0 + self:pill(ty, px0, Nx[2] + 118, 30, "light", 13) + 8 end
        px0 = px0 + self:pill(nx.stage, px0, Nx[2] + 118, 30, "ghost", 13) + 8
        self:pill(nx.prio .. " priority", px0, Nx[2] + 118, 30, "ghost", 13)
        self:zone(Nx, function() self:openTask(nx) end)
    else
        self:lines("Nothing open. Enjoy the quiet.", "sans", 22, Nx[1] + 22, Nx[2] + 70, Nx[3] - 44, 1, fg, nil, true)
    end

    -- filters
    self.wfilter = self.wfilter or "Open"
    local fx = 30
    for _i, f in ipairs(FILTERS) do
        local w = self:pill(f, fx, L.filters_y, 42, self.wfilter == f and "dark" or "outline", 15)
        self:zone({ fx, L.filters_y - 4, w, 50 }, function() self.wfilter = f; self.wpage = 1; self:rebuild("ui") end)
        fx = fx + w + 8
    end
    local shown = {}
    for _i, t in ipairs(all) do
        local pass
        if self.wfilter == "Open" then pass = t.stage ~= "Done" and t ~= nx
        elseif self.wfilter == "Due this week" then pass = t.stage ~= "Done" and t.due and t.due <= weekEnd
        elseif self.wfilter == "With chief" then pass = t.stage == "With chief for review"
        else pass = t.stage == "Done" end
        if pass then table.insert(shown, t) end
    end
    table.sort(shown, function(a, b) return (a.due or "9999") < (b.due or "9999") end)
    local per = L.cards
    self.wpage = self.wpage or 1
    local pages = math.max(1, math.ceil(#shown / per))
    if self.wpage > pages then self.wpage = pages end
    if pages > 1 then
        self:pill(self.wpage .. "/" .. pages .. " ›", 640, L.filters_y, 42, "outline", 14, 88)
        self:zone({ 640, L.filters_y - 4, 88, 50 }, function() self.wpage = self.wpage % pages + 1; self:rebuild("ui") end)
    end
    if #shown == 0 then
        self:box(30, L.cards_y, 698, 80, WHITE, 22)
        self:lines("No tasks here.", "sans", 17, 52, L.cards_y + 28, 600, 1, GREY)
    end
    for k = 1, per do
        local t = shown[(self.wpage - 1) * per + k]
        if not t then break end
        local y = L.cards_y + (k - 1) * (L.card_h + 10)
        local done = t.stage == "Done"
        self:box(30, y, 698, L.card_h, WHITE, 22)
        self:box(48, y + 18, 34, 34, done and BLACK or WHITE, 17, 3)
        self:lines(t.task, "sans", 17, 96, y + 14, 470, 1, done and GREY or BLACK, nil, true)
        self:text("Due " .. dueLabel(t.due), "sans", 14, 580, y + 16, BLACK, true)
        self:lines(t.matter .. (t.caseNo ~= "" and (" · " .. t.caseNo) or ""), "sans", 15, 96, y + 40, 600, 1, GREY)
        local px0 = 96
        for _i, ty in ipairs(t.types) do px0 = px0 + self:pill(ty, px0, y + 66, 28, "dark", 12) + 6 end
        self:pill(t.stage, px0, y + 66, 28, "grey", 12)
        self:zone({ 96, y, 632, L.card_h }, function() self:openTask(t) end)
        self:zone({ 36, y + 6, 58, 58 }, function()
            local new = done and "To do" or "Done"
            ctx.online(function()
                local ok, res = N.update(t.pg.id, { Stage = N.status(new) })
                if not ok then self:notionError(res) return end
                t.pg.properties.Stage = { type = "status", status = { name = new } }
                self:rebuild("ui")
            end)
        end)
    end
    self:pill("+ New task", L.new[1], L.new[2], L.new[4], "dark", 19, L.new[3])
    self:zone(L.new, function()
        self:openTask({ new = true, task = "", matter = "", caseNo = "", types = {}, stage = "To do",
            prio = "Medium", due = N.nextDay(N.today()), by = "", notes = "" })
    end)
    if self.wsheet then self:drawTaskSheet() end
end

---------------------------------------------------------------- Work: task editor

local WY = 286 -- top of the sheet

function Canvas:openTask(t)
    local types = {}
    for _i, ty in ipairs(t.types or {}) do types[ty] = true end
    self.wsheet = { new = t.new, pg = t.pg, task = t.task, matter = t.matter, caseNo = t.caseNo, types = types,
        stage = t.stage, prio = t.prio, due = t.due or N.today(), by = t.by, notes = t.notes }
    self:rebuild("ui")
end

function Canvas:drawTaskSheet()
    local d = self.wsheet
    self:zone({ 0, 0, 758, WY }, function() self.wsheet = nil; self:rebuild("ui") end)
    self:zone({ 0, WY, 758, 1024 - WY }, function() end)
    self:box(0, WY, 758, 1024 - WY + 30, WHITE, 30, 4)
    self:lines(d.new and "New task" or "Edit task", "serif", 26, 30, WY + 22, 560, 1)
    self:pill("×", 682, WY + 16, 46, "outline", 20, 46)
    self:zone({ 674, WY + 10, 60, 60 }, function() self.wsheet = nil; self:rebuild("ui") end)
    local set = function(k) return function(v) d[k] = v end end
    self:field("TASK", d.task, "e.g. Research memo on s.37 scope", 30, WY + 70, 698, set("task"))
    self:field("MATTER", d.matter, "Client / matter name", 30, WY + 146, 400, set("matter"))
    self:field("CASE NO.", d.caseNo, "Optional", 442, WY + 146, 286, set("caseNo"))
    self:text("WORK TYPE · TAP ONE OR MORE", "sans", 13, 30, WY + 224, GREY, true)
    self:choices(TYPES, d.types, 30, WY + 244, 698, 4, 38, function(v) d.types[v] = (not d.types[v]) or nil end, true)
    self:text("STAGE", "sans", 13, 30, WY + 340, GREY, true)
    self:choices(STAGES, d.stage, 30, WY + 360, 698, 5, 38, function(v) d.stage = v end)
    -- deadline and priority
    self:box(30, WY + 410, 380, 84, LIGHT, 18)
    self:text("DEADLINE", "sans", 13, 44, WY + 420, GREY, true)
    self:pill("–", 44, WY + 442, 42, "outline", 20, 46)
    self:centerText(dueLabel(d.due), "sans", 19, 96, WY + 442, 260, 42, BLACK, true)
    self:pill("+", 350, WY + 442, 42, "dark", 20, 46)
    self:zone({ 40, WY + 436, 56, 54 }, function() d.due = N.prevDay(d.due); self:rebuild("ui") end)
    self:zone({ 346, WY + 436, 56, 54 }, function() d.due = N.nextDay(d.due); self:rebuild("ui") end)
    self:box(422, WY + 410, 306, 84, LIGHT, 18)
    self:text("PRIORITY", "sans", 13, 436, WY + 420, GREY, true)
    self:choices({ { "High", "High" }, { "Medium", "Med" }, { "Low", "Low" } }, d.prio, 436, WY + 442, 278, 3, 42, function(v) d.prio = v end)
    self:field("ASSIGNED BY", d.by, "e.g. Chief", 30, WY + 506, 280, set("by"))
    self:field("NOTES", d.notes, "Anything to remember", 322, WY + 506, 406, set("notes"))
    local by = WY + 600
    if not d.new then
        self:pill("Delete", 30, by, 52, "outline", 17, 200)
        self:zone({ 30, by, 200, 52 }, function()
            ctx.online(function()
                local ok, res = N.trash(d.pg.id)
                if not ok then self:notionError(res) return end
                for i, pg in ipairs(self.workd.tasks) do if pg == d.pg then table.remove(self.workd.tasks, i) break end end
                self.wsheet = nil
                self:rebuild("ui")
            end)
        end)
    end
    local sx, sw = d.new and 30 or 242, d.new and 698 or 486
    self:pill(d.new and "Add task" or "Save", sx, by, 52, "dark", 17, sw)
    self:zone({ sx, by, sw, 52 }, function() self:saveTask() end)
end

function Canvas:saveTask()
    local d = self.wsheet
    local types = {}
    for _i, ty in ipairs(TYPES) do if d.types[ty] then table.insert(types, ty) end end
    if #types == 0 then types = { "Admin" } end
    local props = {
        Task = N.title(d.task ~= "" and d.task or "Untitled task"), Matter = N.text(d.matter or ""), ["Case no."] = N.text(d.caseNo or ""),
        ["Work type"] = N.multi(types), Stage = N.status(d.stage), Deadline = N.date(d.due), Priority = N.select(d.prio),
        ["Assigned by"] = N.text(d.by or ""), Notes = N.text(d.notes or ""),
    }
    ctx.online(function()
        local ok, res
        if d.new then ok, res = N.create(N.DS.work, props) else ok, res = N.update(d.pg.id, props) end
        if not ok then self:notionError(res) return end
        if d.new then table.insert(self.workd.tasks, res)
        else for i, pg in ipairs(self.workd.tasks) do if pg == d.pg then self.workd.tasks[i] = res end end end
        self.wsheet = nil
        self:rebuild("ui")
    end)
end

end
