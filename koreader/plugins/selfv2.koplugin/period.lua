--[[
Week, Month, Month stats and the Focus board, matching the finalised designs
(Week.dc.html, Month.dc.html, Stats.dc.html, Focus.dc.html). All figures are read from Notion:
Daily Check-in (habits + rollups), Attendance, Lectures, Expenses and Work.
Installed onto Canvas by main.lua: dofile("period.lua")(Canvas, ctx).
]]

local DataStorage = require("datastorage")
local ImageWidget = require("ui/widget/imagewidget")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")

return function(Canvas, ctx)
local N, px, py = ctx.N, ctx.px, ctx.py
local BLACK, WHITE, GREY, LIGHT, TRACK = ctx.BLACK, ctx.WHITE, ctx.GREY, ctx.LIGHT, ctx.TRACK

local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August",
    "September", "October", "November", "December" }
local DOW = { "MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN" }

---------------------------------------------------------------- dates

local function ymd(date) local y, m, d = date:match("(%d+)-(%d+)-(%d+)") return tonumber(y), tonumber(m), tonumber(d) end
local function weekday(date) return (os.date("*t", N.dateTime(date)).wday + 5) % 7 + 1 end -- 1 = Monday
local function addDays(date, n)
    for _i = 1, math.abs(n) do date = n > 0 and N.nextDay(date) or N.prevDay(date) end
    return date
end
local function monthLen(y, m) return os.date("*t", os.time{ year = y, month = m + 1, day = 0, hour = 12 }).day end

local function weekRange(date)
    local from = addDays(date, 1 - weekday(date))
    return from, addDays(from, 6)
end
local function monthRange(date)
    local y, m = ymd(date)
    return string.format("%04d-%02d-01", y, m), string.format("%04d-%02d-%02d", y, m, monthLen(y, m))
end
local function short(date) local _y, m, d = ymd(date) return d .. " " .. MONTHS[m]:sub(1, 3) end
local function rupees(n)
    local s = tostring(math.floor((n or 0) + 0.5))
    local head, tail = s:sub(1, -4), s:sub(-3)
    if head == "" then return "₹ " .. tail end
    head = head:reverse():gsub("(%d%d)", "%1,"):reverse():gsub("^,", "")
    return "₹ " .. head .. "," .. tail
end
local function dayOf(pg, prop)
    local d = N.get(pg, prop or "Date")
    return d and d.start and d.start:sub(1, 10) or nil
end

---------------------------------------------------------------- data

function Canvas:periodKey(mode)
    local from, to
    local weekly = mode == "week" or mode == "meals"
    if weekly then from, to = weekRange(self:dday()) else from, to = monthRange(self:dday()) end
    return from, to, (weekly and "w" or "m") .. from
end

function Canvas:periodFresh(mode)
    local _f, _t, key = self:periodKey(mode)
    return self.periodd and self.periodd[key] ~= nil
end

function Canvas:loadPeriod(mode)
    if self:periodFresh(mode) then return end
    if not N.token() then self.plugin:notionSetup(false) return end
    local from, to, key = self:periodKey(mode)
    ctx.online(function()
        local d = { from = from, to = to, checkin = {}, attend = {}, lectures = {}, expenses = {}, work = {} }
        local ok, res = N.between(N.DS.checkin, "Date", from, to)
        if not ok then self:notionError(res) return end
        for _i, pg in ipairs(res) do local k = dayOf(pg) if k then d.checkin[k] = pg end end
        ok, res = N.between(N.DS.attend, "Date", from, to)
        if ok then for _i, pg in ipairs(res) do
            local k, t = dayOf(pg), N.get(pg, "Type")
            if k and t then d.attend[k .. t] = pg end
        end end
        ok, res = N.between(N.DS.lectures, "Date", from, to)
        if ok then d.lectures = res end
        ok, res = N.between(N.DS.expenses, "Date", from, to)
        if ok then d.expenses = res end
        if mode == "week" or mode == "meals" then
            ok, res = N.between(N.DS.food, "Date", from, to)
            if ok then d.food = res end
        end
        if mode ~= "week" then
            ok, res = N.between(N.DS.work, "Deadline", from, to)
            if ok then d.work = res end
        end
        self.periodd = self.periodd or {}
        self.periodd[key] = d
        self:rebuild("full")
    end)
end

-- habit counts over the days from..upto
local function tally(d, upto)
    local t = { days = 0, read = 0, riyaaz = 0, talks = 0, gym = 0, abs = 0, absDays = 0, med = 0,
        calmSum = 0, calmN = 0, calmHigh = 0, sleepSum = 0, sleepN = 0, sleep7 = 0, pages = 0,
        hobby = 0, kcalSum = 0, kcalN = 0, period = {}, h = {} }
    local day = d.from
    while day <= d.to and day <= upto do
        t.days = t.days + 1
        local pg = d.checkin[day]
        if pg then
            for _i, k in ipairs({ "Vit B12", "Vit D3", "Magnesium", "Meditation", "5 pages", "News update", "Riyaaz", "Gym" }) do
                if N.get(pg, k) then t.h[k] = (t.h[k] or 0) + 1 end
            end
            if (N.get(pg, "Herbal tea") or 0) >= 2 then t.h["Herbal tea ×2"] = (t.h["Herbal tea ×2"] or 0) + 1 end
            local ab = N.get(pg, "Ab workouts") or 0
            t.abs = t.abs + ab
            if ab > 0 then t.absDays = t.absDays + 1 end
            local pages = N.get(pg, "Pages / min read") or 0
            t.pages = t.pages + pages
            if pages > 0 or N.get(pg, "5 pages") then t.read = t.read + 1 end
            t.talks = t.talks + (N.get(pg, "Talks done") or 0)
            local c = N.get(pg, "Calm")
            if c then t.calmSum, t.calmN = t.calmSum + c, t.calmN + 1 if c >= 4 then t.calmHigh = t.calmHigh + 1 end end
            local sh = N.get(pg, "Sleep hours")
            if sh and sh > 0 then
                t.sleepSum, t.sleepN = t.sleepSum + sh, t.sleepN + 1
                if sh >= 7 then t.sleep7 = t.sleep7 + 1 end
            end
            t.hobby = t.hobby + (N.get(pg, "Hobby minutes") or 0)
            local kc = N.get(pg, "Total calories")
            if kc and kc > 0 then
                t.kcalSum, t.kcalN = t.kcalSum + kc, t.kcalN + 1
                -- that day's goal follows where you were (check-in Location; Mumbai unless it says otherwise)
                local loc = (N.get(pg, "Location") or ""):lower()
                local G = ctx.GOALS or {}
                local goal = (loc ~= "" and not (loc:find("mumbai") or loc:find("home 1"))) and G.home2 or G.home1
                t.goalSum = (t.goalSum or 0) + (goal and goal.kcal or 0)
            end
            if N.get(pg, "Period day") then table.insert(t.period, day) end
        end
        day = N.nextDay(day)
    end
    t.h["Ab workouts"] = t.absDays
    t.h["Sleep 7h+"] = t.sleep7
    t.riyaaz, t.gym, t.med = t.h["Riyaaz"] or 0, t.h["Gym"] or 0, t.h["Meditation"] or 0
    return t
end

local function clamp(x) return math.max(0, math.min(1, x or 0)) end
local function goals(t)
    local n = math.max(1, t.days)
    local weeks = math.max(1, n / 7)
    local calm = t.calmN > 0 and t.calmSum / t.calmN or 0
    return {
        { "Range", (clamp(t.read / n) + clamp(t.riyaaz / n) + clamp(t.talks / weeks)) / 3,
            t.read .. (t.read == 1 and " read" or " reads"), "Reading " .. t.read .. " days · " .. t.talks .. " speeches · riyaaz " .. t.riyaaz .. " days" },
        { "Athleticism", 0.7 * clamp(t.gym / (4 * weeks)) + 0.3 * clamp(t.absDays / (4 * weeks)),
            t.gym .. "/" .. math.floor(4 * weeks + 0.5), t.gym .. " gym sessions · " .. t.abs .. " ab workouts" },
        { "Quiet mind", (clamp(t.med / n) + clamp(calm / 5)) / 2,
            "calm ×" .. t.calmHigh, "Meditated " .. t.med .. " days · calm " .. string.format("%.1f", calm) .. " / 5" },
    }
end

---------------------------------------------------------------- shared header

function Canvas:periodSwitch(active, L)
    local S = L.switch
    local _f, _t = weekRange(self:dday())
    local y, m = ymd(self:dday())
    local tabs = {
        { "week", active == "week" and ("Week · " .. (_f:sub(1, 7) == _t:sub(1, 7) and tostring(select(3, ymd(_f))) or short(_f))
            .. "–" .. short(_t)) or "Week" },
        { "month", active == "month" and ("Month · " .. MONTHS[m]:sub(1, 3)) or "Month" },
        { "stats", active == "stats" and (MONTHS[m]:sub(1, 3) .. " stats") or "Stats" },
        { "meals", "Meals" },
    }
    local widths, total = {}, 8
    for i, t in ipairs(tabs) do widths[i] = self:measure(t[2], "sans", 15, true) + 32 total = total + widths[i] + 4 end
    self:box(S[1], S[2], total, S[4], WHITE, S[4] / 2)
    local x = S[1] + 4
    for i, t in ipairs(tabs) do
        self:pill(t[2], x, S[2] + 4, S[4] - 8, t[1] == active and "dark" or "plain", 15, widths[i])
        self:zone({ x, S[2], widths[i], S[4] }, function() if t[1] ~= self.mode then self:go(t[1]) end end)
        x = x + widths[i] + 4
    end
    self:homePill(L.home)
    self:refreshPill(524, L.home[2], 100, L.home[4])
    self:navBar("week", L)
end

local function tiles(y, h, n, gap)
    local w = (698 - gap * (n - 1)) / n
    local out = {}
    for i = 1, n do out[i] = { 30 + (i - 1) * (w + gap), y, w, h } end
    return out
end

function Canvas:goalTiles(t, y, h, big)
    local fg = self.texfg
    for i, g in ipairs(goals(t)) do
        local r = tiles(y, h, 3, 12)[i]
        local x, w = r[1] + 14, r[3] - 28
        self:text(g[1], "sans", 16, x, y + 12, fg, true)
        if big then
            self:rtext(math.floor(g[2] * 100 + 0.5) .. "%", "sans", 22, x + w, y + 8, fg, true)
            self:box(x, y + 46, w, 8, TRACK, 4)
            self:box(x, y + 46, math.max(8, w * g[2]), 8, fg, 4)
            self:lines(g[4], "sans", 13, x, y + 64, w, 2, fg, 17)
        else
            self:rtext(g[3], "sans", 13, x + w, y + 14, fg)
            self:box(x, y + 50, w, 10, TRACK, 5)
            self:box(x, y + 50, math.max(10, w * g[2]), 10, fg, 5)
        end
    end
end

function Canvas:periodLoading(y)
    self:lines("Loading from Notion…", "sans", 17, 52, y, 600, 1, GREY)
end

---------------------------------------------------------------- Week

local PXH = 14 -- pixels per hour on the week grid (7 am at the top)

function Canvas:buildWeek()
    local L = self.L.week
    self:periodSwitch("week", L)
    local from, to, key = self:periodKey("week")
    self:text("This week", "serif", 40, 30, 66)
    local _y1, m1, d1 = ymd(from)
    local _y2, m2, d2 = ymd(to)
    self:text(m1 == m2 and (d1 .. " – " .. d2 .. " " .. MONTHS[m2]) or (short(from) .. " – " .. short(to)), "sans", 16, 30, 116, GREY)
    local d = self.periodd and self.periodd[key]
    if not d then self:periodLoading(L.cw[2] + 24) return end
    local today = N.today()

    -- college & work grid
    local C = L.cw
    self:text("College & work", "serif", 22, C[1] + 22, C[2] + 16)
    local lecWent, lecAll = 0, 0
    local lecBy = {}
    for _i, pg in ipairs(d.lectures) do
        local k, st = dayOf(pg), N.get(pg, "Status")
        lecBy[k] = lecBy[k] or { 0, 0 }
        if st ~= "Holiday" then
            lecBy[k][2] = lecBy[k][2] + 1; lecAll = lecAll + 1
            if st == "Attended" then lecBy[k][1] = lecBy[k][1] + 1; lecWent = lecWent + 1 end
        end
    end
    self:rtext("Lectures attended · this week " .. lecWent .. "/" .. lecAll, "sans", 14, C[1] + C[3] - 22, C[2] + 22, GREY)
    local gx, cw = C[1] + 66, (C[3] - 66 - 18) / 7
    local hy, by = C[2] + 56, C[2] + 104
    self:text("7", "sans", 11, C[1] + 34, by, GREY)
    self:text("1 pm", "sans", 11, C[1] + 22, by + 6 * PXH, GREY)
    self:text("6 pm", "sans", 11, C[1] + 22, by + 11 * PXH, GREY)
    local day = from
    for i = 1, 7 do
        local x = gx + (i - 1) * cw
        local isToday = day == today
        if isToday then self:box(x + 2, hy, cw - 4, 42, BLACK, 10) end
        local col = isToday and WHITE or BLACK
        self:centerText(DOW[i], "sans", 12, x, hy + 2, cw, 18, col, true)
        local _y, _m, dd = ymd(day)
        self:centerText(tostring(dd), "sans", 15, x, hy + 18, cw, 22, col, true)
        local ci = d.checkin[day]
        if ci and N.get(ci, "Period day") then self:box(x + cw / 2 + 14, hy + 26, 7, 7, col, 4) end
        local function block(kind, f0, f1, label, defSub)
            local att = d.attend[day .. kind]
            local st = att and N.get(att, "Status")
            local look
            if st == "Attended" then look = "went" elseif st == "Missed" then look = "missed"
            elseif st == "Holiday" then look = "holiday"
            elseif day > today and i < 7 then look = "coming" end
            if not look then return end
            local sub = defSub
            if att then
                local a, b = N.get(att, "In"), N.get(att, "Out")
                local ta, tb = a and N.localTime(a.start), b and N.localTime(b.start)
                if ta then f0 = ta / 60 end
                if tb then f1 = tb / 60 end
                if kind == "Work" and ta and tb then sub = N.hhmm(ta) .. "–" .. N.hhmm(tb) end
            end
            if kind == "College" and lecBy[day] and lecBy[day][2] > 0 then sub = lecBy[day][1] .. "/" .. lecBy[day][2] end
            f0, f1 = math.max(7, f0), math.min(19, math.max(f1, f0 + 1))
            local yy, hh = by + (f0 - 7) * PXH, (f1 - f0) * PXH
            local bg, fg, border = BLACK, WHITE, nil
            if look == "missed" then bg, fg, border = WHITE, BLACK, 2
            elseif look == "holiday" then bg, fg = LIGHT, BLACK
            elseif look == "coming" then bg, fg, border = WHITE, GREY, 2 end
            self:box(x + 3, yy, cw - 6, hh, bg, 9, border, look == "coming" and GREY or BLACK)
            self:lines(label, "sans", 12, x + 9, yy + 5, cw - 16, 1, fg, nil, true)
            if hh > 36 then self:lines(sub, "sans", 11, x + 9, yy + 21, cw - 16, 1, fg) end
        end
        if i < 7 then
            block("College", 7.5, 13, "College", "7:30")
            block("Work", 14, 18.5, "Work", "2–6:30")
        end
        day = N.nextDay(day)
    end
    -- legend
    local ly = C[2] + C[4] - 30
    local lx = C[1] + 22
    for _i, it in ipairs({ { "Went", BLACK, nil }, { "Missed", WHITE, BLACK }, { "Holiday", LIGHT, nil }, { "Coming up", WHITE, GREY } }) do
        self:box(lx, ly + 2, 14, 14, it[2], 4, it[3] and 2 or nil, it[3])
        lx = lx + 20 + self:text(it[1], "sans", 13, lx + 20, ly, GREY):getSize().w / px(100) * 100 + 18
    end
    self:box(lx, ly + 5, 8, 8, BLACK, 4)
    self:text("Period day", "sans", 13, lx + 14, ly, GREY)

    -- goals
    local t = tally(d, today)
    self:goalTiles(t, L.goals_y, L.goal_h, false)

    -- habits
    local H = L.habits
    self:text("My habits", "serif", 22, H[1] + 22, H[2] + 16)
    local spent = 0
    for _i, pg in ipairs(d.expenses) do spent = spent + (N.get(pg, "Amount") or 0) end
    local sp = rupees(spent) .. " spent this week"
    local sw = self:measure(sp, "sans", 13, true) + 28
    self:pill(sp, H[1] + H[3] - 22 - sw, H[2] + 14, 32, "dark", 13, sw)
    local soFar = math.max(1, t.days)
    local RH, STEP = 42, 47   -- row height and spacing (six rows: five habits and calories)
    local cellX = function(c) return H[1] + H[3] - 32 - 7 * 22 + (c - 1) * 22 + 4 end
    for r, name in ipairs({ "Vit B12", "Vit D3", "Magnesium", "Herbal tea ×2", "Gym" }) do
        local y = H[2] + 56 + (r - 1) * STEP
        self:box(H[1] + 16, y, H[3] - 32, RH, LIGHT, 13)
        self:text(name, "sans", 17, H[1] + 32, y + 10, BLACK, true)
        self:rtext((t.h[name] or 0) .. "/" .. soFar, "sans", 14, H[1] + H[3] - 32 - 7 * 22 - 12, y + 12, GREY)
        local dday = from
        for c = 1, 7 do
            local cx = cellX(c)
            local pg = d.checkin[dday]
            local done = pg and ((name == "Herbal tea ×2" and (N.get(pg, "Herbal tea") or 0) >= 2) or (name ~= "Herbal tea ×2" and N.get(pg, name)))
            if dday > today then self:box(cx, y + 10, 18, 22, WHITE, 6)
            elseif done then self:box(cx, y + 10, 18, 22, BLACK, 6)
            else self:box(cx, y + 10, 18, 22, nil, 6, 2) end
            dday = N.nextDay(dday)
        end
    end

    -- calories against each day's goal (the goal follows where you were: Mumbai or Home 2/travel)
    local y = H[2] + 56 + 5 * STEP
    self:box(H[1] + 16, y, H[3] - 32, RH, LIGHT, 13)
    self:text("Calories", "sans", 17, H[1] + 32, y + 10, BLACK, true)
    local G = ctx.GOALS or {}
    local sumK, sumG, n, hit = 0, 0, 0, 0
    local dday = from
    for c = 1, 7 do
        local cx = cellX(c)
        local pg = d.checkin[dday]
        local loc = pg and (N.get(pg, "Location") or ""):lower() or ""
        local goal = ((loc ~= "" and not (loc:find("mumbai") or loc:find("home 1"))) and G.home2 or G.home1)
        goal = goal and goal.kcal or 1900
        local kcal = pg and N.get(pg, "Total calories") or 0
        local bh = 30
        if dday > today then
            self:box(cx, y + 6, 18, bh, WHITE, 5)
        else
            self:box(cx, y + 6, 18, bh, nil, 5, 2)
            if kcal > 0 then
                local f = math.min(1, kcal / goal)
                local fh = math.max(4, math.floor(bh * f + 0.5))
                self:box(cx, y + 6 + bh - fh, 18, fh, BLACK, 5)
                if kcal > goal * 1.05 then self:box(cx + 3, y + 1, 12, 3, BLACK) end  -- over the goal
                sumK, sumG, n = sumK + kcal, sumG + goal, n + 1
                if kcal >= goal * 0.9 and kcal <= goal * 1.05 then hit = hit + 1 end
            end
        end
        dday = N.nextDay(dday)
    end
    local label = n > 0 and string.format("avg %d / %d", math.floor(sumK / n + 0.5), math.floor(sumG / n + 0.5)) or "nothing logged"
    self:rtext(label, "sans", 14, H[1] + H[3] - 32 - 7 * 22 - 12, y + 12, GREY)
    self:zone({ H[1] + 16, y, H[3] - 32, RH }, function() self:go("meals") end)
end

---------------------------------------------------------------- Meals (week of food and macros)

local MEAL_ORDER = { Breakfast = 1, Brunch = 2, Lunch = 3, Snack = 4, Dinner = 5 }

local function goalFor(pg)
    local G = ctx.GOALS or {}
    local loc = pg and (N.get(pg, "Location") or ""):lower() or ""
    local g = ((loc ~= "" and not (loc:find("mumbai") or loc:find("home 1"))) and G.home2 or G.home1)
    return g or { name = "Goal", kcal = 1900, protein = 120, carbs = 200, fat = 65 }
end

function Canvas:buildMeals()
    local L = self.L.meals
    self:periodSwitch("meals", L)
    local from, to, key = self:periodKey("meals")
    self:text("Meals this week", "serif", 40, 30, 66)
    self:text(short(from) .. " – " .. short(to) .. " · tap a day to see what you ate", "sans", 16, 30, 116, GREY)
    local d = self.periodd and self.periodd[key]
    if not d then self:periodLoading(L.sum[2] + 24) return end
    local today = N.today()

    -- per-day totals and goals
    local days = {}
    local day = from
    for i = 1, 7 do
        days[i] = { date = day, kcal = 0, protein = 0, carbs = 0, fat = 0, meals = {}, goal = goalFor(d.checkin[day]) }
        day = N.nextDay(day)
    end
    local index = {}
    for i, x in ipairs(days) do index[x.date] = i end
    for _i, pg in ipairs(d.food or {}) do
        local x = days[index[dayOf(pg) or ""] or 0]
        if x then
            x.kcal = x.kcal + (N.get(pg, "Calories") or 0)
            x.protein = x.protein + (N.get(pg, "Protein (g)") or 0)
            x.carbs = x.carbs + (N.get(pg, "Carbs (g)") or 0)
            x.fat = x.fat + (N.get(pg, "Fat (g)") or 0)
            table.insert(x.meals, pg)
        end
    end
    local logged = {}
    for _i, x in ipairs(days) do if x.kcal > 0 then table.insert(logged, x) end end
    local function avg(field, goal)
        if #logged == 0 then return 0, 0 end
        local a, g = 0, 0
        for _i, x in ipairs(logged) do a = a + x[field]; g = g + (goal and x.goal[field] or 0) end
        return a / #logged, g / #logged
    end

    -- summary (on leopard)
    local S = L.sum
    local fg = self.texfg
    local ak, ag = avg("kcal", true)
    local onTarget = 0
    for _i, x in ipairs(logged) do if x.kcal >= x.goal.kcal * 0.9 and x.kcal <= x.goal.kcal * 1.05 then onTarget = onTarget + 1 end end
    self:text("DAILY AVERAGE · " .. #logged .. (#logged == 1 and " DAY" or " DAYS") .. " LOGGED", "sans", 12, S[1] + 18, S[2] + 14, fg, true)
    if #logged == 0 then
        self:lines("Nothing logged this week yet. Add meals in Log → Food.", "sans", 17, S[1] + 18, S[2] + 48, 330, 2, fg, 24)
    else
        local w = self:text(tostring(math.floor(ak + 0.5)), "sans", 30, S[1] + 18, S[2] + 34, fg, true):getSize().w / px(100) * 100
        self:text("/ " .. math.floor(ag + 0.5) .. " kcal", "sans", 14, S[1] + 24 + w, S[2] + 48, fg)
        self:text(onTarget .. " of " .. #logged .. " days on target", "sans", 13, S[1] + 18, S[2] + 84, fg)
    end
    local mx = S[1] + 330
    local mw = (S[3] - 330 - 18 - 20) / 3
    for i, m in ipairs({ { "Protein", "protein" }, { "Carbs", "carbs" }, { "Fat", "fat" } }) do
        local x = mx + (i - 1) * (mw + 10)
        local a, g = avg(m[2], true)
        self:text(m[1], "sans", 12, x, S[2] + 34, fg, true)
        self:text(math.floor(a + 0.5) .. "/" .. math.floor(g + 0.5) .. " g", "sans", 12, x, S[2] + 52, fg)
        self:box(x, S[2] + 76, mw, 6, ctx.TRACK, 3)
        if g > 0 then self:box(x, S[2] + 76, math.max(6, mw * math.min(1, a / g)), 6, fg, 3) end
    end

    -- calories by day
    local C = L.cal
    self:text("Calories by day", "serif", 21, C[1] + 22, C[2] + 14)
    self:rtext("Line = that day's goal", "sans", 13, C[1] + C[3] - 22, C[2] + 20, GREY)
    self.mealsDay = self.mealsDay or ((today >= from and today <= to) and index[today] or 1)
    local top, bh = C[2] + 62, 130
    local maxv = 0
    for _i, x in ipairs(days) do maxv = math.max(maxv, x.kcal, x.goal.kcal) end
    maxv = maxv * 1.08
    local colw = (C[3] - 44) / 7
    for i, x in ipairs(days) do
        local cx = C[1] + 22 + (i - 1) * colw
        local bw = colw - 30
        local bx = cx + 15
        local sel = i == self.mealsDay
        if sel then self:box(cx + 4, top - 8, colw - 8, bh + 66, LIGHT, 14) end
        local gy = top + bh - bh * x.goal.kcal / maxv
        if x.date <= today then
            local h = math.floor(bh * x.kcal / maxv + 0.5)
            if x.kcal > 0 then self:box(bx, top + bh - h, bw, h, x.kcal > x.goal.kcal * 1.05 and BLACK or GREY, 6) end
        end
        self:box(bx - 6, gy, bw + 12, 2, BLACK)
        self:centerText(DOW[i]:sub(1, 1) .. DOW[i]:sub(2):lower(), "sans", 13, cx, top + bh + 6, colw, 20, BLACK, true)
        self:centerText(x.kcal > 0 and tostring(math.floor(x.kcal)) or (x.date > today and "" or "–"), "sans", 12, cx, top + bh + 26, colw, 18, GREY)
        self:zone({ cx, top - 10, colw, bh + 70 }, function() self.mealsDay = i; self:rebuild("ui") end)
    end

    -- macros by day
    local M = L.mac
    self:text("Macros by day", "serif", 21, M[1] + 22, M[2] + 14)
    self:rtext("Filled = share of the day's target", "sans", 13, M[1] + M[3] - 22, M[2] + 20, GREY)
    for r, m in ipairs({ { "Protein", "protein" }, { "Carbs", "carbs" }, { "Fat", "fat" } }) do
        local y = M[2] + 56 + (r - 1) * 44
        local a, g = avg(m[2], true)
        self:text(m[1], "sans", 15, M[1] + 22, y + 8, BLACK, true)
        self:text(#logged > 0 and (math.floor(a + 0.5) .. "/" .. math.floor(g + 0.5) .. " g avg") or "–", "sans", 12, M[1] + 22, y + 28, GREY)
        local mcol = (M[3] - 44 - 140) / 7
        for i, x in ipairs(days) do
            local cx = M[1] + 22 + 140 + (i - 1) * mcol
            local bx, bw = cx + 6, mcol - 12
            if x.date > today then
                self:box(bx, y + 10, bw, 22, WHITE, 6, 1, LIGHT)
            else
                self:box(bx, y + 10, bw, 22, nil, 6, 2)
                local tgt = x.goal[m[2]] or 1
                if x[m[2]] > 0 then
                    local f = math.min(1, x[m[2]] / tgt)
                    self:box(bx, y + 10, math.max(6, bw * f), 22, x[m[2]] > tgt * 1.1 and BLACK or GREY, 6)
                end
            end
        end
    end

    -- the selected day's meals
    local D = L.day
    local x = days[self.mealsDay]
    local dname = os.date("%A %d %b", N.dateTime(x.date)):gsub(" 0", " ")
    self:text(dname, "serif", 21, D[1] + 22, D[2] + 14)
    self:rtext(x.goal.name, "sans", 13, D[1] + D[3] - 22, D[2] + 20, GREY)
    table.sort(x.meals, function(a, b)
        return (MEAL_ORDER[N.get(a, "Meal") or ""] or 9) < (MEAL_ORDER[N.get(b, "Meal") or ""] or 9)
    end)
    if #x.meals == 0 then
        self:lines(x.date > today and "Still to come." or "Nothing logged this day.", "sans", 16, D[1] + 22, D[2] + 64, 640, 1, GREY)
    end
    for k, pg in ipairs(x.meals) do
        if k > 4 then
            self:rtext("+ " .. (#x.meals - 4) .. " more", "sans", 13, D[1] + D[3] - 22, D[2] + D[4] - 24, GREY, true)
            break
        end
        local y = D[2] + 50 + (k - 1) * 26
        self:text(N.get(pg, "Meal") or "Meal", "sans", 14, D[1] + 22, y, BLACK, true)
        self:lines(N.get(pg, "Item") or "", "sans", 14, D[1] + 126, y, 300, 1, BLACK)
        local mac = string.format("%dP %dC %dF", math.floor(N.get(pg, "Protein (g)") or 0), math.floor(N.get(pg, "Carbs (g)") or 0),
            math.floor(N.get(pg, "Fat (g)") or 0))
        self:rtext(math.floor(N.get(pg, "Calories") or 0) .. " kcal", "sans", 14, D[1] + D[3] - 22, y, BLACK, true)
        self:rtext(mac, "sans", 12, D[1] + D[3] - 120, y + 2, GREY)
    end
    if #x.meals > 0 then
        self:text(string.format("Total %d / %d kcal · %d / %d g protein", math.floor(x.kcal), x.goal.kcal, math.floor(x.protein), x.goal.protein),
            "sans", 13, D[1] + 22, D[2] + D[4] - 24, GREY, true)
    end
end

---------------------------------------------------------------- Month

function Canvas:buildMonth()
    local L = self.L.month
    self:periodSwitch("month", L)
    local from, to, key = self:periodKey("month")
    local y0, m0 = ymd(from)
    self:text(MONTHS[m0], "serif", 40, 30, 66)
    self:text("College · work · gym · period", "sans", 16, 30, 116, GREY)
    local d = self.periodd and self.periodd[key]
    if not d then self:periodLoading(L.cal[2] + 24) return end
    local today = N.today()
    local fg = self.texfg
    local inv = self.night and WHITE or BLACK -- colour that reads dark on a white disc, in both modes

    -- calendar on leopard
    local C = L.cal
    self:text(MONTHS[m0], "serif", 22, C[1] + 18, C[2] + 16, fg)
    self:rtext("College · work · gym · period", "sans", 14, C[1] + C[3] - 18, C[2] + 22, fg)
    local gap = 6
    local cw = (C[3] - 36 - gap * 6) / 7
    for i, w in ipairs({ "M", "T", "W", "T", "F", "S", "S" }) do
        self:centerText(w, "sans", 12, C[1] + 18 + (i - 1) * (cw + gap), C[2] + 52, cw, 18, fg, true)
    end
    local lead = weekday(from) - 1
    local n = monthLen(y0, m0)
    local function state(day, kind)
        if weekday(day) == 7 then return nil end
        local att = d.attend[day .. kind]
        local st = att and N.get(att, "Status")
        if st == "Attended" then return "went" elseif st == "Missed" then return "missed"
        elseif st == "Holiday" then return "holiday" elseif day > today then return "ahead" end
        return nil
    end
    local function bar(x, y, w, st)
        if st == "went" then self:box(x, y, w, 6, fg, 3)
        elseif st == "missed" then self:box(x, y, w, 6, nil, 3, 2, fg)
        elseif st == "holiday" then self:box(x, y, w, 6, GREY, 3)
        elseif st == "ahead" then self:box(x, y, w, 6, nil, 3, 1, GREY) end
    end
    for k = 1, n do
        local idx = lead + k - 1
        local x = C[1] + 18 + (idx % 7) * (cw + gap)
        local y = C[2] + 76 + math.floor(idx / 7) * 42
        local day = string.format("%04d-%02d-%02d", y0, m0, k)
        if day == today then self:box(x, y, cw, 36, nil, 10, 2, fg) end
        local ci = d.checkin[day]
        if ci and N.get(ci, "Gym") then
            self:box(x + 5, y + 4, 20, 20, fg, 10)
            self:centerText(tostring(k), "sans", 13, x + 5, y + 4, 20, 20, inv, true)
        else
            self:centerText(tostring(k), "sans", 13, x + 5, y + 4, 20, 20, fg, true)
        end
        if ci and N.get(ci, "Period day") then self:box(x + cw - 14, y + 9, 8, 8, fg, 4) end
        local bw = (cw - 15) / 2
        bar(x + 6, y + 27, bw, state(day, "College"))
        bar(x + 9 + bw, y + 27, bw, state(day, "Work"))
    end
    local ly = C[2] + C[4] - 30
    local lx = C[1] + 18
    local function leg(draw, label)
        draw(lx)
        lx = lx + 24 + self:measure(label, "sans", 13) + 16
        self:text(label, "sans", 13, lx - self:measure(label, "sans", 13) - 16, ly, fg)
    end
    leg(function(x) self:box(x, ly + 6, 18, 6, fg, 3) end, "College / work: went")
    leg(function(x) self:box(x, ly + 6, 18, 6, nil, 3, 2, fg) end, "Missed")
    leg(function(x) self:box(x, ly + 6, 18, 6, GREY, 3) end, "Holiday")
    leg(function(x) self:box(x + 2, ly + 1, 16, 16, fg, 8) end, "Gym")
    leg(function(x) self:box(x + 5, ly + 5, 8, 8, fg, 4) end, "Period")

    -- lecture attendance by subject
    local Lc = L.lect
    self:text("Lecture attendance", "serif", 22, Lc[1] + 22, Lc[2] + 16)
    self:rtext("Line = 75%", "sans", 14, Lc[1] + Lc[3] - 22, Lc[2] + 22, GREY)
    local subj, order = {}, {}
    for _i, pg in ipairs(d.lectures) do
        local s, st = N.get(pg, "Subject") or "Other", N.get(pg, "Status")
        if not subj[s] then subj[s] = { 0, 0 }; table.insert(order, s) end
        if st ~= "Holiday" then
            subj[s][2] = subj[s][2] + 1
            if st == "Attended" then subj[s][1] = subj[s][1] + 1 end
        end
    end
    table.sort(order, function(a, b) return subj[a][2] > subj[b][2] end)
    if #order == 0 then self:lines("No lectures logged this month yet.", "sans", 16, Lc[1] + 22, Lc[2] + 70, 600, 1, GREY) end
    for i, s in ipairs(order) do
        if i > 5 then break end
        local y = Lc[2] + 62 + (i - 1) * 40
        local p = subj[s][2] > 0 and subj[s][1] / subj[s][2] or 0
        local pct = math.floor(p * 100 + 0.5)
        self:lines(s, "sans", 16, Lc[1] + 22, y, 160, 1, BLACK, nil, true)
        local bx, bw = Lc[1] + 196, Lc[3] - 196 - 22 - 96
        self:box(bx, y + 2, bw, 16, LIGHT, 8)
        self:box(bx, y + 2, math.max(16, bw * p), 16, pct < 75 and GREY or BLACK, 8)
        self:box(bx + bw * 0.75, y - 3, 2, 26, BLACK)
        self:rtext(pct .. "%" .. (pct < 75 and " · low" or ""), "sans", 16, Lc[1] + Lc[3] - 22, y, BLACK, true)
    end

    -- four figures
    local T = tiles(L.tiles_y, L.tile_h, 4, 10)
    local cWent, cAll, wDays, wMin = 0, 0, 0, 0
    for k, att in pairs(d.attend) do
        local st = N.get(att, "Status")
        if k:match("College$") and st ~= "Holiday" then
            cAll = cAll + 1
            if st == "Attended" then cWent = cWent + 1 end
        elseif k:match("Work$") and st == "Attended" then
            wDays = wDays + 1
            local a, b = N.get(att, "In"), N.get(att, "Out")
            local ta, tb = a and N.localTime(a.start), b and N.localTime(b.start)
            if ta and tb and tb > ta then wMin = wMin + tb - ta end
        end
    end
    local done = 0
    for _i, pg in ipairs(d.work) do if N.get(pg, "Stage") == "Done" then done = done + 1 end end
    local spent = 0
    for _i, pg in ipairs(d.expenses) do spent = spent + (N.get(pg, "Amount") or 0) end
    local figs = {
        { "College days", tostring(cWent), " / " .. cAll },
        { "Work days", tostring(wDays), wMin > 0 and (" · " .. math.floor(wMin / 60 + 0.5) .. " h") or "" },
        { "Tasks done", tostring(done), " / " .. #d.work },
    }
    for i, f in ipairs(figs) do
        local r = T[i]
        self:text(f[1], "sans", 13, r[1] + 14, r[2] + 14, GREY, true)
        local w = self:text(f[2], "sans", 26, r[1] + 14, r[2] + 40, BLACK, true):getSize().w / px(100) * 100
        self:text(f[3], "sans", 15, r[1] + 16 + w, r[2] + 50, GREY)
    end
    self:text("Spent", "sans", 13, T[4][1] + 14, T[4][2] + 14, fg, true)
    self:text(rupees(spent), "sans", 22, T[4][1] + 14, T[4][2] + 44, fg, true)
end

---------------------------------------------------------------- Month stats

function Canvas:buildStats()
    local L = self.L.stats
    self:periodSwitch("stats", L)
    local from, to, key = self:periodKey("month")
    local y0, m0 = ymd(from)
    self:text(MONTHS[m0] .. " stats", "serif", 40, 30, 66)
    self:text("Everything you logged this month", "sans", 16, 30, 116, GREY)
    local d = self.periodd and self.periodd[key]
    if not d then self:periodLoading(L.goals_y + 24) return end
    local t = tally(d, N.today())
    local n = math.max(1, t.days)
    self:goalTiles(t, L.goals_y, L.goal_h, true)

    -- daily check-in
    local H = L.habits
    self:text("Daily check-in", "serif", 21, H[1] + 22, H[2] + 16)
    self:rtext("Days done out of " .. n .. " so far", "sans", 14, H[1] + H[3] - 22, H[2] + 22, GREY)
    local names = { "Vit B12", "Vit D3", "Magnesium", "Herbal tea ×2", "Meditation", "5 pages", "News update",
        "Riyaaz", "Gym", "Ab workouts", "Sleep 7h+", "Period" }
    local cw = (H[3] - 32 - 24) / 4
    for i, name in ipairs(names) do
        local x = H[1] + 16 + ((i - 1) % 4) * (cw + 8)
        local y = H[2] + 56 + math.floor((i - 1) / 4) * 78
        self:box(x, y, cw, 70, LIGHT, 14)
        self:lines(name, "sans", 14, x + 12, y + 10, cw - 70, 1, BLACK, nil, true)
        if name == "Period" then
            local lbl = "–"
            if #t.period > 0 then
                local a, b = t.period[1], t.period[#t.period]
                local _a1, _a2, da = ymd(a)
                lbl = a == b and short(a) or (da .. "–" .. short(b))
            end
            self:rtext(lbl, "sans", 12, x + cw - 12, y + 12, GREY)
            self:text(#t.period .. " d", "sans", 19, x + 12, y + 36, BLACK, true)
        else
            local c = t.h[name] or 0
            local p = math.min(1, c / n)
            self:rtext(c .. "/" .. n, "sans", 12, x + cw - 12, y + 12, GREY)
            self:text(math.floor(p * 100 + 0.5) .. "%", "sans", 19, x + 12, y + 36, BLACK, true)
            local bx = x + 70
            self:box(bx, y + 46, cw - 82, 6, WHITE, 3)
            if p > 0 then self:box(bx, y + 46, math.max(6, (cw - 82) * p), 6, BLACK, 3) end
        end
    end

    -- logs
    local logs = {
        { "Sleep", t.sleepN > 0 and string.format("%.1f h", t.sleepSum / t.sleepN) or "–", "average" },
        { "Reading", tostring(math.floor(t.pages)), "pages / min" },
        { "Speech", tostring(math.floor(t.talks)), "talks logged" },
        { "Hobbies", tostring(math.floor(t.hobby)), "minutes" },
        { "Calories", t.kcalN > 0 and tostring(math.floor(t.kcalSum / t.kcalN + 0.5)) or "–",
            (t.kcalN > 0 and (t.goalSum or 0) > 0) and ("avg · goal " .. math.floor(t.goalSum / t.kcalN + 0.5)) or "kcal / day avg" },
    }
    for i, r in ipairs(tiles(L.logs_y, L.log_h, 5, 8)) do
        self:text(logs[i][1], "sans", 13, r[1] + 12, r[2] + 12, GREY, true)
        self:text(logs[i][2], "sans", 21, r[1] + 12, r[2] + 32, BLACK, true)
        self:text(logs[i][3], "sans", 12, r[1] + 12, r[2] + 62, GREY)
    end

    -- money
    local M = L.money
    local total, cats, weeks = 0, {}, { 0, 0, 0, 0, 0 }
    for _i, pg in ipairs(d.expenses) do
        local a = N.get(pg, "Amount") or 0
        total = total + a
        local c = N.get(pg, "Category") or "Other"
        cats[c] = (cats[c] or 0) + a
        local day = dayOf(pg)
        if day then
            local _yy, _mm, dd = ymd(day)
            local w = math.min(5, math.floor((dd - 1) / 7) + 1)
            weeks[w] = weeks[w] + a
        end
    end
    self:text("Money · " .. MONTHS[m0], "serif", 21, M[1] + 22, M[2] + 16)
    local tp = rupees(total)
    local tw = self:measure(tp, "sans", 14, true) + 28
    self:pill(tp, M[1] + M[3] - 22 - tw, M[2] + 14, 32, "dark", 14, tw)
    self:text("BY CATEGORY", "sans", 12, M[1] + 22, M[2] + 58, GREY, true)
    local order = { "Rent", "Food", "Transport", "Shopping", "Health", "Subscriptions", "Travel", "Other" }
    table.sort(order, function(a, b) return (cats[a] or 0) > (cats[b] or 0) end)
    local maxc = math.max(1, cats[order[1]] or 0)
    for i, c in ipairs(order) do
        local y = M[2] + 80 + (i - 1) * 21
        local v = cats[c] or 0
        self:text(c, "sans", 13, M[1] + 22, y, BLACK, true)
        local bx, bw = M[1] + 130, 210
        self:box(bx, y + 4, bw, 9, LIGHT, 5)
        if v > 0 then self:box(bx, y + 4, math.max(9, bw * v / maxc), 9, BLACK, 5) end
        self:rtext(total > 0 and (math.floor(v / total * 100 + 0.5) .. "%") or "–", "sans", 12, bx + bw + 52, y, GREY)
    end
    local rx, rw = M[1] + 430, M[3] - 430 - 22
    self:text("BY WEEK", "sans", 12, rx, M[2] + 58, GREY, true)
    local wmax = math.max(1, unpack(weeks))
    local _yy, _mm, tdd = ymd(N.today())
    local thisW = (N.today():sub(1, 7) == from:sub(1, 7)) and math.min(5, math.floor((tdd - 1) / 7) + 1) or 0
    local bw = (rw - 4 * 10) / 5
    local base = M[2] + M[4] - 52
    for i, v in ipairs(weeks) do
        local x = rx + (i - 1) * (bw + 10)
        local h = math.max(4, 120 * v / wmax)
        self:box(x, base - h, bw, h, i == thisW and GREY or BLACK, 6)
        self:centerText("W" .. i, "sans", 12, x, base + 4, bw, 16, BLACK, true)
    end
    local wf, wt = weekRange(N.today())
    local wk = 0
    for _i, pg in ipairs(d.expenses) do
        local day = dayOf(pg)
        if day and day >= wf and day <= wt then wk = wk + (N.get(pg, "Amount") or 0) end
    end
    self:text("This week so far: " .. rupees(wk), "sans", 12, rx, base + 24, GREY, true)
end

---------------------------------------------------------------- Focus board

local SELF_V2 = "3f226113-480c-8044-ac8d-e7e73350ce21"
local FOCUS_DIR = DataStorage:getDataDir() .. "/selfv2_focus"
local SPANS = { { 1, 1, 3, 4 }, { 4, 1, 3, 2 }, { 4, 3, 3, 2 }, { 1, 5, 2, 2 }, { 3, 5, 4, 2 } } -- col, row, w, h on a 6x6 grid

local function focusFiles()
    local out = {}
    for i = 1, 5 do
        for _j, ext in ipairs({ "jpg", "png" }) do
            local p = FOCUS_DIR .. "/focus_" .. i .. "." .. ext
            if lfs.attributes(p, "mode") == "file" then out[i] = p end
        end
    end
    return out
end

-- find the image blocks on the self.v2 page (they sit inside columns)
local function findImages(id, out, depth)
    if depth > 3 or #out >= 5 then return end
    local ok, kids = N.children(id)
    if not ok then return end
    for _i, b in ipairs(kids) do
        if #out >= 5 then return end
        if b.type == "image" and type(b.image) == "table" then
            local src = b.image.type == "file" and b.image.file or b.image.external
            if type(src) == "table" and type(src.url) == "string" then table.insert(out, src.url) end
        elseif b.has_children and (b.type == "column_list" or b.type == "column" or b.type == "toggle"
                or b.type == "synced_block" or b.type == "callout") then
            findImages(b.id, out, depth + 1)
        end
    end
end

function Canvas:loadFocus()
    if self.focusSynced then return end
    if not N.token() then return end
    ctx.online(function()
        local urls = {}
        findImages(SELF_V2, urls, 0)
        if #urls == 0 then return end
        lfs.mkdir(FOCUS_DIR)
        for i, url in ipairs(urls) do
            local ext = (url:lower():match("%.png[%?]") or url:lower():match("%.png$")) and "png" or "jpg"
            for _j, e in ipairs({ "jpg", "png" }) do os.remove(FOCUS_DIR .. "/focus_" .. i .. "." .. e) end
            local path = FOCUS_DIR .. "/focus_" .. i .. "." .. ext
            N.download(url, path)
        end
        self.focusSynced = true
        if self.mode == "focus" then self:rebuild("full") end
    end)
end

function Canvas:focusImage(file, x, y, w, h)
    self:put(ImageWidget:new{ file = file, width = px(w), height = py(h), scale_factor = 0,
        file_do_cache = false, original_in_nightmode = true }, x, y)
end

function Canvas:buildFocus()
    local L = self.L.focus
    local fg = self.texfg
    local files = focusFiles()
    if self.fview then
        local n = 5
        self:box(0, 0, 758, 1024, BLACK)
        self:pill("Close", 30, 24, 44, "outline", 16, 110)
        self:zone({ 26, 18, 120, 56 }, function() self.fview = nil; self:rebuild("full") end)
        self:centerText(self.fview .. " of " .. n, "sans", 16, 250, 24, 258, 44, WHITE, true)
        self:pill("‹", 590, 24, 44, "outline", 20, 56)
        self:pill("›", 672, 24, 44, "light", 20, 56)
        self:zone({ 586, 18, 66, 56 }, function() self.fview = (self.fview + 3) % n + 1; self:rebuild("full") end)
        self:zone({ 668, 18, 66, 56 }, function() self.fview = self.fview % n + 1; self:rebuild("full") end)
        if files[self.fview] then self:focusImage(files[self.fview], 30, 96, 698, 900)
        else self:centerText("Focus image " .. self.fview, "sans", 20, 30, 96, 698, 900, WHITE, true) end
        return
    end
    self:pill("‹ Today", L.back[1], L.back[2], L.back[4], "ghost", 16, L.back[3])
    self:zone({ L.back[1] - 4, L.back[2] - 6, L.back[3] + 8, L.back[4] + 12 }, function() self:go("today") end)
    self:text("Focus board", "serif", 44, 30, 92, fg)
    local x = 30
    for _i, c in ipairs({ "range", "athleticism", "a quiet mind" }) do
        x = x + self:pill(c, x, 156, 32, "light", 15) + 10
    end
    local G = L.grid
    local gap = 12
    local cw, rh = (G[3] - gap * 5) / 6, (G[4] - gap * 5) / 6
    for i, s in ipairs(SPANS) do
        local tx, ty = G[1] + (s[1] - 1) * (cw + gap), G[2] + (s[2] - 1) * (rh + gap)
        local tw, th = s[3] * cw + (s[3] - 1) * gap, s[4] * rh + (s[4] - 1) * gap
        self:box(tx, ty, tw, th, LIGHT, 22)
        if files[i] then self:focusImage(files[i], tx + 6, ty + 6, tw - 12, th - 12)
        else self:centerText("Focus image " .. i, "sans", 15, tx, ty, tw, th, BLACK, true) end
        self:zone({ tx, ty, tw, th }, function() self.fview = i; self:rebuild("full") end)
    end
    self:text("Tap an image to see it full screen", "sans", 14, 30, L.foot_y, fg)
end

end
