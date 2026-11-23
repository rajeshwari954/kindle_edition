--[[
self.v2 for KOReader: a full-screen start hub drawn over baked backgrounds.

Stage 1: Home, Today's papers, Substacks, and over-the-air updates.
Backgrounds (textures, folders, fixed labels) live in screens/*.png and are made by
kindle/make_screens.py; layout.lua holds the coordinates both sides share.
Live data comes from the Daily reads folder (today.json + EPUBs).
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local OverlapGroup = require("ui/widget/overlapgroup")
local RenderText = require("ui/rendertext")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local rapidjson = require("rapidjson")
local _ = require("gettext")
local Screen = Device.screen

local FOLDER = "/mnt/us/documents/Daily reads"
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GREY = Blitbuffer.Color8(0x55)
local LIGHT = Blitbuffer.Color8(0xE6)

local shown_at_launch = false
local force_home = false  -- set by the Home button inside a book

---------------------------------------------------------------- helpers

local SX, SY, FK = 1, 1, 1
local function setScale()
    SX = Screen:getWidth() / 758
    SY = Screen:getHeight() / 1024
    FK = Screen:scaleBySize(1000) / 1000 -- Font:getFace scales sizes by DPI; undo that
end
local function px(v) return math.floor(v * SX + 0.5) end
local function py(v) return math.floor(v * SY + 0.5) end

local plugin_dir
local faces = {}
local function face(kind, size)
    local key = kind .. size
    if faces[key] then return faces[key] end
    local file = kind == "serif" and "Marcellus-Regular.ttf" or "DMSans.ttf"
    local f = Font:getFace(plugin_dir .. "/fonts/" .. file, math.floor(size * SX / FK + 0.5))
    if not f then f = Font:getFace(kind == "serif" and "tfont" or "cfont", math.floor(size * SX / FK + 0.5)) end
    faces[key] = f
    return f
end

local function textWidth(f, text, bold)
    return RenderText:sizeUtf8Text(0, Screen:getWidth() * 3, f, text, true, bold).x
end

-- Word-wrap into at most maxlines lines, with an ellipsis if cut short.
local function wrap(f, text, width, maxlines, bold)
    local lines, cur = {}, ""
    for word in (text or ""):gmatch("%S+") do
        local t = cur == "" and word or (cur .. " " .. word)
        if textWidth(f, t, bold) <= width or cur == "" then
            cur = t
        else
            table.insert(lines, cur)
            cur = word
        end
    end
    if cur ~= "" then table.insert(lines, cur) end
    if #lines > maxlines then
        local last = lines[maxlines] .. "…"
        while textWidth(f, last, bold) > width and #last > 4 do
            last = last:gsub("[^%s]*…$", ""):gsub("%s+$", "") .. "…"
        end
        local out = {}
        for i = 1, maxlines - 1 do out[i] = lines[i] end
        out[maxlines] = last
        lines = out
    end
    return lines
end

local function readJSON(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local s = fh:read("*a")
    fh:close()
    local ok, data = pcall(rapidjson.decode, s)
    return ok and type(data) == "table" and data or nil
end

local function exists(path) return lfs.attributes(path, "mode") == "file" end

local function todayLabel()
    return (os.date("%a %d %b"):gsub(" 0", " "))
end

local function readState()
    return G_reader_settings:readSetting("selfv2_read") or {}
end
local function setRead(key, val)
    local st = readState()
    st[key] = val or nil
    G_reader_settings:saveSetting("selfv2_read", st)
end

-- Open an EPUB, optionally jumping to a spine position (DocFragment) once it has loaded.
local function openBook(file, frag)
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(file)
    if not frag then return end
    local tries = 0
    local function jump()
        tries = tries + 1
        local ui = ReaderUI.instance
        if ui and ui.document and ui.document.file == file and ui.rolling then
            UIManager:scheduleIn(1, function()
                local ok = pcall(function()
                    ui.rolling:onGotoXPointer(string.format("/body/DocFragment[%d]/body", frag))
                end)
                if not ok then logger.warn("selfv2: jump failed", frag) end
            end)
        elseif tries < 30 then
            UIManager:scheduleIn(0.5, jump)
        end
    end
    UIManager:scheduleIn(1, jump)
end

---------------------------------------------------------------- canvas

local Canvas = InputContainer:extend{
    name = "selfv2_canvas",
    covers_fullscreen = true,
    plugin = nil,
    mode = "home",
}

function Canvas:init()
    setScale()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapCanvas = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipeCanvas = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        HoldCanvas = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    self.sel = nil
    self.page = 1
    self:rebuild()
end

function Canvas:put(w, x, y)
    w.overlap_offset = { px(x), py(y) }
    table.insert(self.items, w)
end

function Canvas:text(str, kind, size, x, y, color, bold, max_w)
    local f = face(kind, size)
    local w = TextWidget:new{ text = str, face = f, fgcolor = color or BLACK, bold = bold, max_width = max_w and px(max_w) or nil }
    self:put(w, x, y)
    return w
end

function Canvas:lines(str, kind, size, x, y, width, maxlines, color, lh, bold)
    local f = face(kind, size)
    lh = lh or math.floor(size * 1.35)
    local ls = wrap(f, str, px(width), maxlines, bold)
    for i, l in ipairs(ls) do
        self:put(TextWidget:new{ text = l, face = f, fgcolor = color or BLACK, bold = bold }, x, y + (i - 1) * lh)
    end
    return #ls
end

-- A pill: rounded box with centred text. style = "dark" | "light" | "outline"
function Canvas:pill(str, x, y, h, style, size, min_w)
    local f = face("sans", size or 14)
    local tw = TextWidget:new{ text = str, face = f, bold = true,
        fgcolor = style == "dark" and WHITE or BLACK }
    local w = math.max(tw:getSize().w + px(28), min_w and px(min_w) or 0)
    local frame = FrameContainer:new{
        background = style == "dark" and BLACK or WHITE,
        bordersize = style == "outline" and 2 or 0,
        color = BLACK,
        radius = math.floor(py(h) / 2),
        padding = 0, margin = 0,
        CenterContainer:new{ dimen = Geom:new{ w = w, h = py(h) }, tw },
    }
    self:put(frame, x, y)
    return w / SX
end

function Canvas:dot(x, y, d, filled)
    self:put(FrameContainer:new{
        background = filled and BLACK or WHITE, bordersize = 2, color = BLACK,
        radius = math.floor(px(d) / 2), padding = 0, margin = 0,
        Widget:new{ dimen = Geom:new{ w = px(d) - 4, h = px(d) - 4 } },
    }, x, y)
end

function Canvas:outline(rect, r)
    self:put(FrameContainer:new{
        background = nil, bordersize = 4, color = BLACK, radius = px(r or 24), padding = 0, margin = 0,
        Widget:new{ dimen = Geom:new{ w = px(rect[3]) - 8, h = py(rect[4]) - 8 } },
    }, rect[1], rect[2])
end

function Canvas:zone(rect, cb)
    table.insert(self.zones, { x = px(rect[1]), y = py(rect[2]), w = px(rect[3]), h = py(rect[4]), cb = cb })
end

function Canvas:onSwipeCanvas() return true end
function Canvas:onHoldCanvas() return true end

function Canvas:onTapCanvas(_args, ges)
    local p = ges and ges.pos
    if not p then return true end
    for i = #self.zones, 1, -1 do
        local z = self.zones[i]
        if p.x >= z.x and p.x < z.x + z.w and p.y >= z.y and p.y < z.y + z.h then
            z.cb()
            return true
        end
    end
    return true
end

function Canvas:rebuild(refresh)
    self.items, self.zones = {}, {}
    self.L = self.plugin.layout
    self.manifest = readJSON(FOLDER .. "/today.json")
    local bg = ({ home = "home.png", papers = "papers.png", subs = "substacks.png" })[self.mode]
    self:put(ImageWidget:new{ file = plugin_dir .. "/screens/" .. bg, width = Screen:getWidth(), height = Screen:getHeight(), file_do_cache = false }, 0, 0)
    if self.mode == "home" then self:buildHome()
    elseif self.mode == "papers" then self:buildPapers()
    else self:buildSubs() end
    self[1] = OverlapGroup:new{ dimen = self.dimen:copy(), allow_mirroring = false, unpack(self.items) }
    if refresh then UIManager:setDirty(self, refresh) end
end

function Canvas:go(mode)
    self.mode = mode
    self.sel, self.page = nil, 1
    self:rebuild("full")
end

function Canvas:close()
    self.is_open = false
    UIManager:close(self, "full")
end

function Canvas:files(kind)
    local out = {}
    for _i, f in ipairs(self.manifest and self.manifest.files or {}) do
        if not kind or f.kind == kind then table.insert(out, f) end
    end
    return out
end

function Canvas:isToday()
    return self.manifest and self.manifest.date == os.date("%Y-%m-%d")
end

---------------------------------------------------------------- home

function Canvas:buildHome()
    local L = self.L.home
    local h = tonumber(os.date("%H"))
    local hello = h < 12 and "GOOD MORNING," or (h < 17 and "GOOD AFTERNOON," or "GOOD EVENING,")
    self:text(hello, "sans", 14, L.label[1], L.label[2], GREY, true)

    local papers, subs = self:files("paper"), self:files("substacks")[1]
    local x = 30
    x = x + self:pill(todayLabel(), x, L.pills_y, 36, "dark", 14) + 8
    if self:isToday() then
        x = x + self:pill("Papers · " .. #papers .. " ready", x, L.pills_y, 36, "light", 14) + 8
        if subs then self:pill("Substacks · " .. (subs.count or 0) .. " new", x, L.pills_y, 36, "light", 14) end
    else
        self:pill("Tap Download for today's reads", x, L.pills_y, 36, "light", 14)
    end

    -- continue reading
    local c = L.cont
    local ok, ReadHistory = pcall(require, "readhistory")
    local last = ok and ReadHistory.hist and ReadHistory.hist[1]
    if last and last.file and exists(last.file) then
        local title, pct = last.text or last.file:match("([^/]+)$"), nil
        local ok2, DocSettings = pcall(require, "docsettings")
        if ok2 then
            local ok3, ds = pcall(DocSettings.open, DocSettings, last.file)
            if ok3 and ds then
                local props = ds:readSetting("doc_props")
                if props and props.title and props.title ~= "" then title = props.title end
                pct = ds:readSetting("percent_finished")
            end
        end
        title = title:gsub("%.epub$", ""):gsub("%.pdf$", "")
        self:lines(title, "serif", 24, 52, c[2] + 40, 520, 1)
        self:text(pct and string.format("%d%% read · tap to continue", math.floor(pct * 100)) or "Tap to continue", "sans", 15, 52, c[2] + 80, GREY)
        self:zone(c, function() self:close(); openBook(last.file) end)
    else
        self:text("Nothing open yet. Pick a book from the Library.", "sans", 16, 52, c[2] + 50, GREY)
    end

    -- tile pills
    local p = L.papers
    if self:isToday() and #papers > 0 then
        self:pill(#papers .. " ready", p[1] + p[3] - 110, p[2] + 16, 30, "light", 13, 90)
    else
        self:pill("Download", p[1] + p[3] - 110, p[2] + 16, 30, "light", 13, 90)
    end
    self:text(self:isToday() and todayLabel() or "Not downloaded yet", "sans", 14, p[1] + 20, p[2] + p[4] - 32, WHITE)
    local s = L.subs
    if subs and self:isToday() then
        self:pill((subs.count or 0) .. " new", s[1] + s[3] - 110, s[2] + 16, 30, "light", 13, 90)
        self:text("New posts from your reads", "sans", 14, s[1] + 20, s[2] + s[4] - 32, WHITE)
    else
        self:text("Nothing new yet", "sans", 14, s[1] + 20, s[2] + s[4] - 32, WHITE)
    end

    local soon = function() UIManager:show(InfoMessage:new{ text = _("Coming in the next update."), timeout = 3 }) end
    self:zone(L.dash, soon)
    self:zone(L.focus, soon)
    self:zone(L.papers, function() self:go("papers") end)
    self:zone(L.subs, function() self:go("subs") end)
    self:zone(L.library, function()
        self:close()
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then pcall(function() FileManager.instance:onHome() end)
        else FileManager:showFiles(G_reader_settings:readSetting("home_dir")) end
    end)
    self:zone(L.download, function() self.plugin:download(function() self:rebuild("ui") end) end)
    self:zone(L.wifi, function() self.plugin:toggleWifi() end)
    self:zone(L.settings, function() self.plugin:settingsDialog(self) end)
end

---------------------------------------------------------------- papers

function Canvas:buildPapers()
    local L = self.L.papers
    local papers = self:isToday() and self:files("paper") or {}
    local st = readState()
    local date = self.manifest and self.manifest.date or ""
    local nread = 0
    for _i, f in ipairs(papers) do if st[date .. "/" .. f.id] then nread = nread + 1 end end
    self:zone(L.back, function() self:go("home") end)

    if #papers == 0 then
        self:text("Not downloaded yet · tap Download on Home", "sans", 16, L.sub[1], L.sub[2], GREY)
        self:lines("Today's papers arrive after 6 am. Go back to Home and tap Download today's reads.", "sans", 17, 52, L.rows_y, 600, 3, GREY, 26)
        return
    end
    self:text(todayLabel() .. " · " .. nread .. " of " .. #papers .. " read", "sans", 16, L.sub[1], L.sub[2], GREY)

    -- tiles are baked in a fixed order; match manifest entries to them by id
    local order = { "toi", "hindu", "et", "livelaw" }
    local byId = {}
    for _i, f in ipairs(papers) do byId[f.id] = f end
    if not self.sel then
        for _i, id in ipairs(order) do
            if byId[id] and not st[date .. "/" .. id] then self.sel = id break end
        end
        self.sel = self.sel or order[1]
    end
    for i, id in ipairs(order) do
        local r, f = L.tiles[i], byId[id]
        if f then
            self:pill((f.count or 0) .. " stories", r[1] + 16, r[2] + 14, 28, "light", 12)
            if st[date .. "/" .. id] then self:pill("Read", r[1] + r[3] - 86, r[2] + 14, 28, "dark", 12, 70) end
        else
            self:pill("Not in today's set", r[1] + 16, r[2] + 14, 28, "light", 12)
        end
        if self.sel == id then self:outline(r, 24) end
        self:zone(r, function() self.sel = id; self:rebuild("ui") end)
    end

    local f = byId[self.sel]
    if not f then return end
    local path = FOLDER .. "/" .. f.file
    self:text("The top 5 from " .. f.name, "sans", 14, L.panel_sub[1], L.panel_sub[2], GREY)
    local key = date .. "/" .. f.id
    self:pill("Open paper", L.btn_open[1], L.btn_open[2], L.btn_open[4], "dark", 14, L.btn_open[3])
    self:zone(L.btn_open, function() if exists(path) then self:close(); openBook(path) end end)
    self:pill(st[key] and "Read" or "Mark read", L.btn_read[1], L.btn_read[2], L.btn_read[4], "outline", 14, L.btn_read[3])
    self:zone(L.btn_read, function() setRead(key, not st[key]); self:rebuild("ui") end)

    for n, hl in ipairs(f.highlights or {}) do
        if n > 5 then break end
        local y = L.rows_y + (n - 1) * L.row_h
        self:lines(hl.title or "", "serif", 19, L.row_x, y + 2, L.row_w, 1)
        local tag = (hl.tag or ""):upper()
        local why = (tag ~= "" and (tag .. "  ·  ") or "") .. (hl.why or "")
        self:lines(why, "sans", 14, L.row_x, y + 32, L.row_w, 2, GREY, 20)
        self:zone({ 52, y - 4, 654, L.row_h - 8 }, function()
            if exists(path) then self:close(); openBook(path, hl.frag) end
        end)
    end
end

---------------------------------------------------------------- substacks

function Canvas:buildSubs()
    local L = self.L.subs
    self:zone(L.back, function() self:go("home") end)
    local d = self:isToday() and self:files("substacks")[1] or nil
    local posts = d and d.posts or {}
    local st = readState()
    local date = self.manifest and self.manifest.date or ""
    local pk = L.pick

    if #posts == 0 then
        self:text("No new posts today", "sans", 16, L.sub[1], L.sub[2], GREY)
        self:lines("Nothing new yet", "serif", 26, pk[1] + 22, pk[2] + 60, 640, 1, WHITE)
        self:lines("New posts arrive with the morning papers. Send Claude the Substacks you follow to add them.", "sans", 17, 52, L.rows_y + 10, 620, 4, GREY, 26)
        return
    end
    local path = FOLDER .. "/" .. d.file
    local unread = 0
    for i, _p in ipairs(posts) do if not st[date .. "/sub" .. i] then unread = unread + 1 end end
    self:text(unread .. " unread · " .. todayLabel(), "sans", 16, L.sub[1], L.sub[2], GREY)

    local open = function(i)
        setRead(date .. "/sub" .. i, true)
        if exists(path) then self:close(); openBook(path, posts[i].frag) end
    end

    -- pick of the morning: first unread
    local pi = 1
    for i, _p in ipairs(posts) do if not st[date .. "/sub" .. i] then pi = i break end end
    local p = posts[pi]
    self:text((p.pub or "") .. " · " .. (p.mins or 1) .. " min", "sans", 14, pk[1] + 200, pk[2] + 20, WHITE)
    self:lines(p.title or "", "serif", 24, pk[1] + 22, pk[2] + 54, 650, 1, WHITE)
    self:lines(p.summary or "", "sans", 15, pk[1] + 22, pk[2] + 92, 650, 2, WHITE, 22)
    self:zone(pk, function() open(pi) end)

    local per = L.rows
    local pages = math.max(1, math.ceil(#posts / per))
    if self.page > pages then self.page = pages end
    if pages > 1 then
        self:text(self.page .. "/" .. pages, "sans", 14, L.page[1] - 10, L.page[2] - 10, GREY)
        self:pill("‹", L.btn_prev[1], L.btn_prev[2], L.btn_prev[4], "outline", 18, L.btn_prev[3])
        self:pill("›", L.btn_next[1], L.btn_next[2], L.btn_next[4], "dark", 18, L.btn_next[3])
        self:zone(L.btn_prev, function() if self.page > 1 then self.page = self.page - 1; self:rebuild("ui") end end)
        self:zone(L.btn_next, function() if self.page < pages then self.page = self.page + 1; self:rebuild("ui") end end)
    end
    for k = 1, per do
        local i = (self.page - 1) * per + k
        local post = posts[i]
        if not post then break end
        local y = L.rows_y + (k - 1) * L.row_h
        local is_read = st[date .. "/sub" .. i]
        self:dot(52, y + 6, 14, not is_read)
        self:lines(post.title or "", "serif", 19, L.row_x, y, L.row_w, 1, is_read and GREY or BLACK)
        self:lines(post.summary or "", "sans", 14, L.row_x, y + 30, L.row_w, 2, GREY, 20)
        self:text((post.pub or "") .. " · " .. (post.mins or 1) .. " min", "sans", 12, L.row_x, y + 72, BLACK, true)
        self:zone({ 40, y - 6, 680, L.row_h - 6 }, function() open(i) end)
    end
end

---------------------------------------------------------------- plugin

local SelfV2 = WidgetContainer:extend{
    name = "selfv2",
    is_doc_only = false,
}

function SelfV2:init()
    plugin_dir = self.path
    self.layout = dofile(self.path .. "/layout.lua")
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if self.ui.document then
        -- inside a book, PDF or paper: show the Back / Home buttons
        self:addReaderButtons()
        return
    end
    -- Open Home when KOReader starts, when you come back to the file browser from a book,
    -- and always after tapping Home inside a book.
    local first = not shown_at_launch
    shown_at_launch = true
    local want = force_home
        or (G_reader_settings:nilOrTrue("selfv2_home_on_start") and (first or G_reader_settings:nilOrTrue("selfv2_home_after_book")))
    force_home = false
    if want then
        UIManager:nextTick(function() self:showHome() end)
    end
end

---------------------------------------------------------------- Back / Home buttons in the reader

function SelfV2:addReaderButtons()
    if not G_reader_settings:nilOrTrue("selfv2_reader_buttons") then return end
    local view = self.view or self.ui.view
    if not view or not view.registerViewModule then return end
    setScale()
    local H = py(36)
    local function btn(label, w)
        return FrameContainer:new{
            background = WHITE, bordersize = 2, color = BLACK, radius = math.floor(H / 2), padding = 0, margin = 0,
            CenterContainer:new{ dimen = Geom:new{ w = px(w), h = H - 4 }, TextWidget:new{ text = label, face = face("sans", 14), bold = true } },
        }
    end
    local back, home = btn("‹ Back", 84), btn("Home", 74)
    local bottom = G_reader_settings:isTrue("selfv2_buttons_bottom")
    local y = bottom and (Screen:getHeight() - H - py(34)) or py(6)
    local bw, hw = px(84) + 4, px(74) + 4
    local bx = px(10)
    local hx = bx + bw + px(8)
    local module = Widget:new{ dimen = Geom:new{ w = 0, h = 0 } }
    module.paintTo = function(_m, bb, x, y0)
        back:paintTo(bb, x + bx, y0 + y)
        home:paintTo(bb, x + hx, y0 + y)
    end
    view:registerViewModule("selfv2_nav", module)

    local W, Hs = Screen:getWidth(), Screen:getHeight()
    local pad = px(6) -- a little extra room around each button so taps land easily
    local function zone(x, w)
        return { ratio_x = (x - pad) / W, ratio_y = (y - pad) / Hs, ratio_w = (w + 2 * pad) / W, ratio_h = (H + 2 * pad) / Hs }
    end
    local overrides = { "tap_forward", "tap_backward", "readerconfigmenu_tap", "readerconfigmenu_ext_tap",
        "readermenu_tap", "readermenu_ext_tap", "tap_top_left_corner", "tap_top_right_corner",
        "tap_left_bottom_corner", "tap_right_bottom_corner", "readerfooter_tap", "readerhighlight_tap", "tap_link" }
    self.ui:registerTouchZones({
        { id = "selfv2_back", ges = "tap", screen_zone = zone(bx, bw), overrides = overrides,
          handler = function() self:readerBack() return true end },
        { id = "selfv2_home", ges = "tap", screen_zone = zone(hx, hw), overrides = overrides,
          handler = function() self:readerHome() return true end },
    })
end

-- Back: return to where a link took you from (e.g. the newspaper's front page);
-- if you didn't arrive by a link, close the book and go back to Home.
function SelfV2:readerBack()
    local link = self.ui.link
    if link and link.location_stack and #link.location_stack > 0 and link.onGoBackLink then
        link:onGoBackLink()
    else
        self:readerHome()
    end
end

function SelfV2:readerHome()
    force_home = true
    if self.ui.onHome then
        self.ui:onHome()
    else
        self.ui:onClose()
        local FileManager = require("apps/filemanager/filemanager")
        FileManager:showFiles()
    end
end

function SelfV2:onDispatcherRegisterActions()
    Dispatcher:registerAction("selfv2_home", { category = "none", event = "SelfV2Home", title = _("self.v2 Home"), general = true })
end

function SelfV2:onSelfV2Home()
    self:showHome()
    return true
end

function SelfV2:showHome()
    if self.canvas and self.canvas.is_open then return end
    local ok, c = pcall(Canvas.new, Canvas, { plugin = self, mode = "home" })
    if not ok then
        logger.err("selfv2: could not build Home", c)
        UIManager:show(InfoMessage:new{ text = "self.v2 couldn't open: " .. tostring(c) })
        return
    end
    self.canvas = c
    c.is_open = true
    UIManager:show(c, "full")
end

function SelfV2:download(after)
    if not self.ui.dailyreads then
        UIManager:show(InfoMessage:new{ text = _("The Daily reads plugin isn't installed."), timeout = 4 })
        return
    end
    NetworkMgr:runWhenOnline(function() self.ui.dailyreads:download(after) end)
end

function SelfV2:toggleWifi()
    if NetworkMgr:isWifiOn() then
        NetworkMgr:turnOffWifi(function()
            UIManager:show(InfoMessage:new{ text = _("Wi-Fi off."), timeout = 2 })
        end)
    else
        NetworkMgr:turnOnWifi(function()
            UIManager:show(InfoMessage:new{ text = _("Wi-Fi on."), timeout = 2 })
        end)
    end
end

---------------------------------------------------------------- updates

local function httpGet(url, sink)
    local http = require("socket.http")
    local socket = require("socket")
    local socketutil = require("socketutil")
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code = socket.skip(1, http.request{ url = url, method = "GET", sink = sink, redirect = true })
    socketutil:reset_timeout()
    return code
end

local function localVersion()
    local fh = io.open(plugin_dir .. "/version.txt", "r")
    if not fh then return "0" end
    local v = fh:read("*l") or "0"
    fh:close()
    return v
end

function SelfV2:checkUpdates()
    local base = G_reader_settings:readSetting("dailyreads_url") or ""
    if base == "" then
        UIManager:show(InfoMessage:new{ text = _("Set the edition address first: Tools → Daily reads → Edition address.") })
        return
    end
    if not base:match("/$") then base = base .. "/" end
    NetworkMgr:runWhenOnline(function()
        local ltn12 = require("ltn12")
        local chunks = {}
        local code = httpGet(base .. "app/version.txt?t=" .. os.time(), ltn12.sink.table(chunks))
        local remote = (table.concat(chunks):match("%S+")) or ""
        if code ~= 200 or remote == "" then
            UIManager:show(InfoMessage:new{ text = _("Couldn't check for updates. Try again on Wi-Fi.") })
            return
        end
        if remote == localVersion() then
            UIManager:show(InfoMessage:new{ text = _("self.v2 is up to date."), timeout = 3 })
            return
        end
        local tmp = "/tmp/selfv2-update.tar.gz"
        local fh = io.open(tmp, "wb")
        local c2 = fh and httpGet(base .. "app/plugins.tar.gz?t=" .. os.time(), ltn12.sink.file(fh))
        if c2 ~= 200 then
            UIManager:show(InfoMessage:new{ text = _("Update download failed. Try again.") })
            return
        end
        local dest = DataStorage:getDataDir() .. "/plugins"
        local rc = os.execute(string.format("tar -xzf %q -C %q", tmp, dest))
        os.remove(tmp)
        if rc == 0 or rc == true then
            if UIManager.askForRestart then
                UIManager:askForRestart(_("self.v2 updated. Restart KOReader to finish."))
            else
                UIManager:show(InfoMessage:new{ text = _("self.v2 updated. Close and reopen KOReader to finish.") })
            end
        else
            UIManager:show(InfoMessage:new{ text = _("Couldn't unpack the update.") })
        end
    end)
end

function SelfV2:settingsDialog(canvas)
    local dlg
    local function item(text, cb) return { { text = text, callback = function() UIManager:close(dlg); cb() end } } end
    dlg = ButtonDialog:new{
        title = _("Settings"),
        buttons = {
            item(_("KOReader menu · tools & settings"), function()
                -- the full KOReader menu (tools, settings, network, fonts…) on top of Home
                local menu = self.ui and self.ui.menu
                if menu and menu.onShowMenu then menu:onShowMenu() end
            end),
            item(_("Open files"), function() canvas:close() end),
            item(_("Wi-Fi on / off"), function() self:toggleWifi() end),
            item(_("Check for updates"), function() self:checkUpdates() end),
            item(G_reader_settings:nilOrTrue("selfv2_home_after_book") and _("Show Home after closing a book: on") or _("Show Home after closing a book: off"),
                function() G_reader_settings:flipNilOrTrue("selfv2_home_after_book") end),
            item(_("Restart KOReader"), function()
                if UIManager.restartKOReader then UIManager:restartKOReader() end
            end),
            item(_("Close"), function() end),
        },
    }
    UIManager:show(dlg)
end

function SelfV2:addToMainMenu(menu_items)
    menu_items.selfv2 = {
        text = _("self.v2"),
        sorting_hint = "tools",
        sub_item_table = {
            { text = _("Open Home"), callback = function() self:showHome() end },
            { text = _("Check for updates"), callback = function() self:checkUpdates() end },
            {
                text = _("Open Home when KOReader starts"),
                checked_func = function() return G_reader_settings:nilOrTrue("selfv2_home_on_start") end,
                callback = function() G_reader_settings:flipNilOrTrue("selfv2_home_on_start") end,
            },
            {
                text = _("Back & Home buttons in books"),
                checked_func = function() return G_reader_settings:nilOrTrue("selfv2_reader_buttons") end,
                callback = function() G_reader_settings:flipNilOrTrue("selfv2_reader_buttons") end,
                help_text = _("Takes effect the next time you open a book."),
            },
            {
                text = _("Put the buttons at the bottom of the page"),
                checked_func = function() return G_reader_settings:isTrue("selfv2_buttons_bottom") end,
                callback = function() G_reader_settings:flipNilOrFalse("selfv2_buttons_bottom") end,
                help_text = _("Takes effect the next time you open a book."),
            },
            {
                text = _("Show Home after closing a book"),
                checked_func = function() return G_reader_settings:nilOrTrue("selfv2_home_after_book") end,
                callback = function() G_reader_settings:flipNilOrTrue("selfv2_home_after_book") end,
            },
        },
    }
end

return SelfV2
