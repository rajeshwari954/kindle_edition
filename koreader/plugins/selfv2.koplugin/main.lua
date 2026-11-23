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
local N -- Notion client, loaded from notion.lua
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

---------------------------------------------------------------- library data

local DOCS = "/mnt/us/documents"
local BOOK_EXT = { epub = true, pdf = true, mobi = true, azw3 = true, azw = true, fb2 = true, txt = true,
    cbz = true, djvu = true, docx = true, html = true, rtf = true }

local function scanBooks()
    local out = {}
    local function walk(dir, depth)
        if depth > 4 then return end
        local ok, iter, obj = pcall(lfs.dir, dir)
        if not ok then return end
        for name in iter, obj do
            if name:sub(1, 1) ~= "." and name ~= "Daily reads" and not name:match("%.sdr$") then
                local path = dir .. "/" .. name
                local attr = lfs.attributes(path)
                if attr and attr.mode == "directory" then
                    walk(path, depth + 1)
                elseif attr then
                    local ext = name:match("%.([%w]+)$")
                    if ext and BOOK_EXT[ext:lower()] then
                        table.insert(out, { path = path, name = name, ext = ext:upper(), mtime = attr.modification or 0 })
                    end
                end
            end
        end
    end
    walk(DOCS, 0)
    return out
end

local function prettyName(name)
    return (name:gsub("%.[%w]+$", ""):gsub("[_]+", " "):gsub("%s+", " "))
end

-- Title, author and progress, from KOReader's own records when the book has been opened before.
local info_cache = {}
local function bookInfo(b)
    if info_cache[b.path] then return info_cache[b.path] end
    local inf = { title = prettyName(b.name), author = "", pct = nil }
    local ok, DocSettings = pcall(require, "docsettings")
    if ok then
        local ok2, ds = pcall(DocSettings.open, DocSettings, b.path)
        if ok2 and ds then
            local props = ds:readSetting("doc_props") or {}
            if props.title and props.title ~= "" then inf.title = props.title end
            if props.authors and props.authors ~= "" then inf.author = (props.authors:gsub("\n", ", ")) end
            inf.pct = ds:readSetting("percent_finished")
        end
    end
    info_cache[b.path] = inf
    return inf
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
    local ghost = style == "ghost" -- see-through outline for use on textures
    local tw = TextWidget:new{ text = str, face = f, bold = true,
        fgcolor = ghost and self.texfg or (style == "dark" and WHITE or BLACK) }
    local w = math.max(tw:getSize().w + px(28), min_w and px(min_w) or 0)
    local frame = FrameContainer:new{
        background = (not ghost) and (style == "dark" and BLACK or (style == "grey" and LIGHT or WHITE)) or nil,
        bordersize = (style == "outline" or ghost) and 2 or 0,
        color = ghost and self.texfg or BLACK,
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
    -- Night mode: KOReader reverses the whole screen except pictures. So use the dark artwork
    -- (shown as-is), and draw text that sits on a texture in black, which night mode turns white.
    self.night = G_reader_settings:isTrue("night_mode")
    self.texfg = self.night and BLACK or WHITE
    local bg = ({ home = "home", papers = "papers", subs = "substacks", library = "library",
        today = "today", checkin = "checkin" })[self.mode] .. (self.night and "_night.png" or ".png")
    if not exists(plugin_dir .. "/screens/" .. bg) then bg = bg:gsub("_night", "") end
    self:put(ImageWidget:new{ file = plugin_dir .. "/screens/" .. bg, width = Screen:getWidth(), height = Screen:getHeight(),
        file_do_cache = false, original_in_nightmode = true }, 0, 0)
    if self.mode == "home" then self:buildHome()
    elseif self.mode == "papers" then self:buildPapers()
    elseif self.mode == "library" then self:buildLibrary()
    elseif self.mode == "today" then self:buildToday()
    elseif self.mode == "checkin" then self:buildCheckin()
    else self:buildSubs() end
    self[1] = OverlapGroup:new{ dimen = self.dimen:copy(), allow_mirroring = false, unpack(self.items) }
    if refresh then UIManager:setDirty(self, refresh) end
end

function Canvas:go(mode)
    self.mode = mode
    self.sel, self.page = nil, 1
    if mode == "library" then self.books, info_cache = nil, {} end
    if (mode == "today" or mode == "checkin") and not self:dashFresh() then
        self:rebuild("full")
        self:loadDash()
        return
    end
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
    self:text(self:isToday() and todayLabel() or "Not downloaded yet", "sans", 14, p[1] + 20, p[2] + p[4] - 32, self.texfg)
    local s = L.subs
    if subs and self:isToday() then
        self:pill((subs.count or 0) .. " new", s[1] + s[3] - 110, s[2] + 16, 30, "light", 13, 90)
        self:text("New posts from your reads", "sans", 14, s[1] + 20, s[2] + s[4] - 32, self.texfg)
    else
        self:text("Nothing new yet", "sans", 14, s[1] + 20, s[2] + s[4] - 32, self.texfg)
    end

    local soon = function() UIManager:show(InfoMessage:new{ text = _("Coming in the next update."), timeout = 3 }) end
    self:zone(L.dash, function() self:go("today") end)
    self:zone(L.focus, soon)
    self:zone(L.papers, function() self:go("papers") end)
    self:zone(L.subs, function() self:go("subs") end)
    self:zone(L.library, function() self:go("library") end)
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

---------------------------------------------------------------- library

local SORTS = { "Recent", "Title", "Author", "Progress" }

function Canvas:bar(x, y, w, pct)
    local W, Hb = px(w), py(6)
    self:put(FrameContainer:new{ background = LIGHT, bordersize = 0, radius = math.floor(Hb / 2), padding = 0, margin = 0,
        Widget:new{ dimen = Geom:new{ w = W, h = Hb } } }, x, y)
    local fw = math.max(Hb, math.floor(W * math.min(1, pct or 0)))
    self:put(FrameContainer:new{ background = BLACK, bordersize = 0, radius = math.floor(Hb / 2), padding = 0, margin = 0,
        Widget:new{ dimen = Geom:new{ w = fw, h = Hb } } }, x, y)
end

function Canvas:openFiles()
    self:close()
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then pcall(function() FileManager.instance:onHome() end)
    else FileManager:showFiles(G_reader_settings:readSetting("home_dir")) end
end

function Canvas:searchDialog()
    local InputDialog = require("ui/widget/inputdialog")
    local st = self.lib
    local dlg
    dlg = InputDialog:new{
        title = _("Search your library"),
        input = st.query or "",
        input_hint = _("Title, author or file name"),
        buttons = { {
            { text = _("Clear"), callback = function() UIManager:close(dlg); st.query = nil; st.page = 1; self:rebuild("ui") end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local q = dlg:getInputText()
                UIManager:close(dlg)
                st.query = (q and q:match("%S")) and q or nil
                st.page = 1
                self:rebuild("ui")
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function Canvas:buildLibrary()
    local L = self.L.library
    self.lib = self.lib or { sort = 1, page = 1 }
    local st = self.lib
    self.books = self.books or scanBooks()
    local books = self.books
    self:zone(L.back, function() self:go("home") end)

    -- make sure each collection has its folder, so there's somewhere to put books
    for _i, fname in ipairs(L.folders) do
        local path = DOCS .. "/" .. fname
        if lfs.attributes(path, "mode") ~= "directory" then lfs.mkdir(path) end
    end

    -- reading now: your three most recent books (papers excluded)
    local reading = {}
    local ok, ReadHistory = pcall(require, "readhistory")
    for _i, h in ipairs(ok and ReadHistory.hist or {}) do
        if #reading >= 3 then break end
        if h.file and not h.file:find("/Daily reads/", 1, true) and exists(h.file) then
            table.insert(reading, { path = h.file, name = h.file:match("([^/]+)$") })
        end
    end
    self:text(#books .. " books · " .. #reading .. " reading now", "sans", 16, L.sub[1], L.sub[2], GREY)
    self:pill("All files", L.files[1], L.files[2], L.files[4], "outline", 15, L.files[3])
    self:zone(L.files, function() self:openFiles() end)

    local sx, sy = L.search[1], L.search[2]
    self:text(st.query and ("“" .. st.query .. "”") or "Search books and authors", "sans", 17, sx + 54, sy + 13, GREY, false, L.search[3] - 70)
    self:zone(L.search, function() self:searchDialog() end)
    self:pill(SORTS[st.sort], L.sort[1], L.sort[2], L.sort[4], "dark", 15, L.sort[3])
    self:zone(L.sort, function() st.sort = st.sort % #SORTS + 1; st.page = 1; self:rebuild("ui") end)

    for i, rect in ipairs(L.books) do
        local b = reading[i]
        if b then
            local inf = bookInfo(b)
            self:lines(inf.title, "serif", 15, rect[1] + 62, rect[2] + 12, 136, 3, BLACK, 19)
            if inf.author ~= "" then self:lines(inf.author, "sans", 11, rect[1] + 62, rect[2] + 72, 136, 1, GREY) end
            self:bar(rect[1] + 12, rect[2] + 100, 150, inf.pct)
            self:text(inf.pct and (math.floor(inf.pct * 100) .. "%") or "new", "sans", 12, rect[1] + 168, rect[2] + 94, BLACK, true)
            self:zone(rect, function() self:close(); openBook(b.path) end)
        elseif i == 1 then
            self:lines("Nothing open yet. Pick a book below.", "sans", 13, rect[1] + 62, rect[2] + 20, 136, 4, GREY, 18)
        end
    end

    -- collections
    local counts = {}
    for i, fname in ipairs(L.folders) do
        local prefix = DOCS .. "/" .. fname .. "/"
        local n = 0
        for _j, b in ipairs(books) do if b.path:sub(1, #prefix) == prefix then n = n + 1 end end
        counts[i] = n
        local r = L.cols[i]
        self:text(n .. (n == 1 and " book" or " books"), "sans", 12, r[1] + r[3] - 70, r[2] + 16, GREY)
        if st.col == i then self:outline(r, 22) end
        self:zone(r, function()
            if st.col == i then st.col = nil else st.col = i end
            st.page = 1
            self:rebuild("ui")
        end)
    end

    -- the list
    local list = {}
    local prefix = st.col and (DOCS .. "/" .. L.folders[st.col] .. "/") or nil
    local q = st.query and st.query:lower() or nil
    for _i, b in ipairs(books) do
        local keep = true
        if prefix and b.path:sub(1, #prefix) ~= prefix then keep = false end
        if keep and q then
            local inf = bookInfo(b)
            keep = (b.name:lower():find(q, 1, true) or inf.title:lower():find(q, 1, true) or inf.author:lower():find(q, 1, true)) and true or false
        end
        if keep then table.insert(list, b) end
    end
    local sortkey = SORTS[st.sort]
    table.sort(list, function(a, b)
        if sortkey == "Title" then return bookInfo(a).title:lower() < bookInfo(b).title:lower() end
        if sortkey == "Author" then
            local x, y = bookInfo(a).author:lower(), bookInfo(b).author:lower()
            if x == y then return bookInfo(a).title:lower() < bookInfo(b).title:lower() end
            if x == "" then return false end
            if y == "" then return true end
            return x < y
        end
        if sortkey == "Progress" then return (bookInfo(a).pct or -1) > (bookInfo(b).pct or -1) end
        return a.mtime > b.mtime
    end)

    local title = q and ("Results · " .. #list) or (st.col and (L.names[st.col] .. " · " .. #list) or "Recently added")
    self:lines(title, "serif", 24, 52, L.panel[2] + 14, 500, 1)
    local per = L.rows
    local pages = math.max(1, math.ceil(#list / per))
    if st.page > pages then st.page = pages end
    if pages > 1 then
        self:text(st.page .. "/" .. pages, "sans", 13, L.btn_prev[1] - 44, L.btn_prev[2] + 10, GREY)
        self:pill("‹", L.btn_prev[1], L.btn_prev[2], L.btn_prev[4], "outline", 18, L.btn_prev[3])
        self:pill("›", L.btn_next[1], L.btn_next[2], L.btn_next[4], "dark", 18, L.btn_next[3])
        self:zone(L.btn_prev, function() if st.page > 1 then st.page = st.page - 1; self:rebuild("ui") end end)
        self:zone(L.btn_next, function() if st.page < pages then st.page = st.page + 1; self:rebuild("ui") end end)
    end
    if #list == 0 then
        local msg = q and "Nothing matches that search." or
            (st.col and ("No books here yet. Put them in the “" .. L.folders[st.col] .. "” folder in your documents.") or "No books yet.")
        self:lines(msg, "sans", 15, 52, L.rows_y + 4, 640, 3, GREY, 22)
    end
    for k = 1, per do
        local b = list[(st.page - 1) * per + k]
        if not b then break end
        local y = L.rows_y + (k - 1) * L.row_h
        local inf = bookInfo(b)
        self:lines(inf.title, "serif", 18, 52, y, 560, 1)
        local meta = {}
        if inf.author ~= "" then table.insert(meta, inf.author) end
        if inf.pct then table.insert(meta, math.floor(inf.pct * 100) .. "% read") end
        table.insert(meta, (os.date("added %d %b", b.mtime):gsub(" 0", " ")))
        self:lines(table.concat(meta, " · "), "sans", 13, 52, y + 27, 560, 1, GREY)
        self:pill(b.ext, 640, y + 4, 26, "grey", 11, 60)
        self:zone({ 40, y - 6, 680, L.row_h - 4 }, function() self:close(); openBook(b.path) end)
    end
end

---------------------------------------------------------------- dashboard: shared

local TABS = { { "Today", "today" }, { "Check-in", "checkin" }, { "Log" }, { "Week" }, { "Work" } }

function Canvas:tabs(active, y)
    local x = 30
    for _i, t in ipairs(TABS) do
        local style = (t[2] == active) and "dark" or "outline"
        self:pill(t[1], x, y, 40, style, 14, 130)
        local target = t[2]
        self:zone({ x, y - 4, 130, 48 }, function()
            if target then
                if target ~= self.mode then self:go(target) end
            else
                UIManager:show(InfoMessage:new{ text = t[1] .. " is coming in the next update.", timeout = 3 })
            end
        end)
        x = x + 142
    end
end

function Canvas:dashFresh()
    return self.dash and self.dash.date == N.today() and self.dash.loaded
end

function Canvas:notionError(err)
    if err == "no_token" or err == "bad_token" then
        self.plugin:notionSetup(err == "bad_token")
    elseif err == "not_shared" then
        UIManager:show(InfoMessage:new{ text = _("Notion says the self.v2 page isn't shared with the Kindle connection yet. In Notion, open self.v2 → ••• → Connections → add your Kindle connection.") })
    else
        UIManager:show(InfoMessage:new{ text = "Notion: " .. tostring(err) .. "\nCheck Wi-Fi and try again.", timeout = 6 })
    end
end

-- Fetch everything Today and Check-in need, in one go.
function Canvas:loadDash()
    if not N.token() then self.plugin:notionSetup(false) return end
    NetworkMgr:runWhenOnline(function()
        local busy = InfoMessage:new{ text = _("Loading from Notion…") }
        UIManager:show(busy)
        UIManager:forceRePaint()
        local today, tomorrow = N.today(), N.nextDay(N.today())
        local d = { date = today, blocks = {}, todos = {}, attend = {}, lectures = {} }
        local ok, res = N.query(N.DS.checkin, { property = "Date", date = { equals = today } })
        if not ok then UIManager:close(busy); self:notionError(res); return end
        d.checkin = res[1]
        ok, res = N.query(N.DS.blocks, { ["or"] = {
            { ["and"] = {
                { property = "Planned", date = { on_or_after = today .. "T00:00:00+05:30" } },
                { property = "Planned", date = { before = tomorrow .. "T00:00:00+05:30" } } } },
            { property = "Repeat", select = { equals = "Every day" } },
            { property = "Repeat", select = { equals = "Weekdays" } },
            { property = "Repeat", select = { equals = "Mon to Sat" } },
        } })
        if ok then d.blocks = res end
        ok, res = N.query(N.DS.todos, { ["or"] = {
            { property = "Date", date = { equals = today } },
            { ["and"] = { { property = "Date", date = { before = today } }, { property = "Done", checkbox = { equals = false } } } },
        } })
        if ok then d.todos = res end
        ok, res = N.query(N.DS.attend, { property = "Date", date = { equals = today } })
        if ok then for _i, pg in ipairs(res) do d.attend[N.get(pg, "Type") or "?"] = pg end end
        ok, res = N.query(N.DS.lectures, { property = "Date", date = { equals = today } })
        if ok then for _i, pg in ipairs(res) do d.lectures[N.get(pg, "Subject") or "?"] = pg end end
        d.loaded = true
        self.dash = d
        UIManager:close(busy)
        self:rebuild("full")
    end)
end

-- Run a Notion write; on success apply `after` to local state and redraw.
function Canvas:write(fn, after)
    NetworkMgr:runWhenOnline(function()
        local ok, res = fn()
        if not ok then self:notionError(res) return end
        if after then after(res) end
        self:rebuild("ui")
    end)
end

-- Today's Daily Check-in row, created on first write.
function Canvas:checkinRow(cb)
    if self.dash.checkin then return cb(self.dash.checkin) end
    self:write(function()
        return N.create(N.DS.checkin, { Day = N.title(N.dayTitle()), Date = N.date(N.today()) })
    end, function(pg) self.dash.checkin = pg; cb(pg) end)
end

function Canvas:setProp(pg, name, value)
    pg.properties = pg.properties or {}
    local p = pg.properties[name] or {}
    if type(value) == "boolean" then p.type = "checkbox"; p.checkbox = value
    elseif type(value) == "number" then p.type = "number"; p.number = value
    elseif type(value) == "string" then p.type = "select"; p.select = { name = value } end
    pg.properties[name] = p
end

---------------------------------------------------------------- dashboard: Today

local WEEKDAYS = { Weekdays = { [2] = 1, [3] = 1, [4] = 1, [5] = 1, [6] = 1 },
    ["Mon to Sat"] = { [2] = 1, [3] = 1, [4] = 1, [5] = 1, [6] = 1, [7] = 1 } }

function Canvas:todayBlocks()
    local today = N.today()
    local wday = tonumber(os.date("%w")) + 1 -- 1 = Sunday
    local out = {}
    for _i, pg in ipairs(self.dash.blocks or {}) do
        local pl = N.get(pg, "Planned")
        local rep = N.get(pg, "Repeat")
        local s, sd = N.localTime(pl and pl.start)
        local e = N.localTime(pl and pl.finish)
        local include = (sd == today)
        if rep == "Every day" then include = true
        elseif WEEKDAYS[rep] then include = WEEKDAYS[rep][wday] ~= nil end
        if include and s then
            table.insert(out, { pg = pg, title = N.get(pg, "Block") or "", start = s, finish = e,
                cat = N.get(pg, "Category") or "", status = N.get(pg, "Status") or "Planned",
                repeats = rep and rep ~= "Once" })
        end
    end
    table.sort(out, function(a, b) return a.start < b.start end)
    return out
end

local NEXT_STATUS = { Planned = "Done", Done = "Skipped", Skipped = "Planned", Shifted = "Done" }

function Canvas:buildToday()
    local L = self.L.today
    self:zone(L.back, function() self:go("home") end)
    self:text((os.date("%A, %d %B"):gsub(" 0", " ")), "sans", 16, L.sub[1], L.sub[2], GREY)
    self:tabs("today", L.tabs_y)
    if not self:dashFresh() then
        self:lines("Loading from Notion…", "sans", 17, 52, L.blk_y, 600, 1, GREY)
        return
    end
    local blocks = self:todayBlocks()
    local nowm = tonumber(os.date("%H")) * 60 + tonumber(os.date("%M"))

    -- now / next
    local cur, nxt
    for _i, b in ipairs(blocks) do
        if b.start <= nowm and (b.finish or b.start + 60) > nowm then cur = cur or b end
        if b.start > nowm and not nxt then nxt = b end
    end
    local nw = L.now
    if cur then
        self:lines(cur.title, "serif", 28, nw[1] + 20, nw[2] + 40, 640, 1, self.texfg)
        self:text(N.hhmm(cur.start) .. "–" .. N.hhmm(cur.finish) .. (cur.cat ~= "" and ("  ·  " .. cur.cat) or ""), "sans", 15, nw[1] + 20, nw[2] + 84, self.texfg)
    else
        self:lines("Free time", "serif", 28, nw[1] + 20, nw[2] + 40, 640, 1, self.texfg)
        self:text(nxt and ("Next: " .. nxt.title .. " at " .. N.hhmm(nxt.start)) or "Nothing else planned today", "sans", 15, nw[1] + 20, nw[2] + 84, self.texfg)
    end

    -- time blocks, 6 per page
    local per = L.blk_rows
    self.blk_page = self.blk_page or 1
    local pages = math.max(1, math.ceil(#blocks / per))
    if self.blk_page > pages then self.blk_page = pages end
    if pages > 1 then
        self:pill("‹", L.blk_prev[1], L.blk_prev[2], L.blk_prev[4], "outline", 18, L.blk_prev[3])
        self:pill("›", L.blk_next[1], L.blk_next[2], L.blk_next[4], "dark", 18, L.blk_next[3])
        self:zone(L.blk_prev, function() if self.blk_page > 1 then self.blk_page = self.blk_page - 1; self:rebuild("ui") end end)
        self:zone(L.blk_next, function() if self.blk_page < pages then self.blk_page = self.blk_page + 1; self:rebuild("ui") end end)
    end
    if #blocks == 0 then
        self:lines("No time blocks today. Add them in Notion or the self.v2 app.", "sans", 15, 52, L.blk_y + 6, 640, 2, GREY, 22)
    end
    for k = 1, per do
        local b = blocks[(self.blk_page - 1) * per + k]
        if not b then break end
        local y = L.blk_y + (k - 1) * L.blk_h
        local live = b.start <= nowm and (b.finish or b.start + 60) > nowm
        self:text(N.hhmm(b.start) .. (b.finish and ("–" .. N.hhmm(b.finish)) or ""), "sans", 14, 52, y + 4, live and BLACK or GREY, true)
        self:lines(b.title, "serif", 19, 190, y, 380, 1)
        self:text(b.cat .. (b.repeats and "  ·  repeats" or ""), "sans", 12, 190, y + 28, GREY)
        if b.repeats then
            self:pill("Daily", 596, y + 4, 32, "grey", 12, 110)
        else
            local st = b.status
            self:pill(st, 596, y + 4, 32, st == "Done" and "dark" or (st == "Skipped" and "grey" or "outline"), 12, 110)
            self:zone({ 586, y - 4, 130, L.blk_h - 4 }, function()
                local new = NEXT_STATUS[st] or "Done"
                self:write(function() return N.update(b.pg.id, { Status = N.select(new) }) end,
                    function() self:setProp(b.pg, "Status", new) end)
            end)
        end
    end

    -- to-dos
    local todos = {}
    for _i, pg in ipairs(self.dash.todos or {}) do
        local dt = N.get(pg, "Date")
        table.insert(todos, { pg = pg, task = N.get(pg, "Task") or "", done = N.get(pg, "Done"),
            overdue = dt and dt.start and dt.start:sub(1, 10) < N.today() })
    end
    table.sort(todos, function(a, b) if a.done ~= b.done then return not a.done end return a.task < b.task end)
    self:pill("+ Add", L.todo_add[1], L.todo_add[2], L.todo_add[4], "dark", 14, L.todo_add[3])
    self:zone(L.todo_add, function() self:addTodo() end)
    local tper = L.todo_rows
    self.todo_page = self.todo_page or 1
    local tpages = math.max(1, math.ceil(#todos / tper))
    if self.todo_page > tpages then self.todo_page = tpages end
    local open = 0
    for _i, t in ipairs(todos) do if not t.done then open = open + 1 end end
    self:text(open .. " open" .. (tpages > 1 and ("  ·  page " .. self.todo_page .. "/" .. tpages .. " ›") or ""), "sans", 13, 180, L.todos[2] + 24, GREY)
    if tpages > 1 then
        self:zone({ 170, L.todos[2] + 8, 300, 40 }, function() self.todo_page = self.todo_page % tpages + 1; self:rebuild("ui") end)
    end
    if #todos == 0 then
        self:lines("Nothing on the list. Tap + Add.", "sans", 15, 52, L.todo_y + 6, 600, 1, GREY)
    end
    for k = 1, tper do
        local t = todos[(self.todo_page - 1) * tper + k]
        if not t then break end
        local y = L.todo_y + (k - 1) * L.todo_h
        self:dot(52, y + 4, 24, t.done)
        self:lines(t.task, "serif", 19, 92, y + 2, 520, 1, t.done and GREY or BLACK)
        if t.overdue and not t.done then self:pill("from before", 600, y + 2, 28, "grey", 11, 106) end
        self:zone({ 40, y - 6, 560, L.todo_h - 4 }, function()
            local new = not t.done
            self:write(function() return N.update(t.pg.id, { Done = N.check(new) }) end,
                function() self:setProp(t.pg, "Done", new) end)
        end)
    end
end

function Canvas:addTodo()
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = _("New to-do for today"),
        input_hint = _("What needs doing?"),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Add"), is_enter_default = true, callback = function()
                local task = dlg:getInputText()
                UIManager:close(dlg)
                if not task or not task:match("%S") then return end
                self:write(function()
                    local props = { Task = N.title(task), Date = N.date(N.today()), Done = N.check(false) }
                    if self.dash.checkin then props["Check-in day"] = { relation = { { id = self.dash.checkin.id } } } end
                    return N.create(N.DS.todos, props)
                end, function(pg) table.insert(self.dash.todos, pg) end)
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

---------------------------------------------------------------- dashboard: Check-in

local HABITS = { "Meditation", "News update", "Vit B12", "Vit D3", "Magnesium", "Gym", "5 pages", "Riyaaz", "Period day" }
local SUBJECTS = { "Jurisprudence", "Law of Contract", "Constitutional Law-I", "Torts MVA & CPA", "BNS", "Legal Aid", "Mentoring", "Tutorials" }
local SUBJECT_SHORT = { ["Constitutional Law-I"] = "Const. Law", ["Torts MVA & CPA"] = "Torts", ["Law of Contract"] = "Contract" }
local LECTURE_NEXT = { [""] = "Attended", Attended = "Skipped", Skipped = "Cancelled", Cancelled = "Attended", Holiday = "Attended" }
local DEFAULT_TIMES = { College = { "07:30", "13:00" }, Work = { "14:00", "18:30" } }

function Canvas:timeDialog(title, current, cb)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = title, input = current or "", input_hint = "HH:MM, e.g. 07:30", input_type = "number",
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

function Canvas:attendCard(kind, rect)
    local pg = self.dash.attend[kind]
    local status = pg and N.get(pg, "Status") or nil
    local x, y = rect[1], rect[2]
    local opts = { { "Went", "Attended" }, { "Missed", "Missed" }, { "Holiday", "Holiday" } }
    local bx = x + 16
    for _i, o in ipairs(opts) do
        local on = status == o[2]
        self:pill(o[1], bx, y + 62, 36, on and "light" or "ghost", 13, 96)
        self:zone({ bx, y + 58, 100, 44 }, function()
            self:setAttendance(kind, { Status = N.select(o[2]) }, function(p) self:setProp(p, "Status", o[2]) end)
        end)
        bx = bx + 102
    end
    local inn = pg and N.get(pg, "In")
    local out = pg and N.get(pg, "Out")
    local inm = inn and N.localTime(inn.start)
    local outm = out and N.localTime(out.start)
    local def = DEFAULT_TIMES[kind]
    self:text("In", "sans", 13, x + 18, y + 120, self.texfg, true)
    self:pill(inm and N.hhmm(inm) or def[1] .. "?", x + 16, y + 142, 40, "light", 16, 140)
    self:text("Out", "sans", 13, x + 176, y + 120, self.texfg, true)
    self:pill(outm and N.hhmm(outm) or def[2] .. "?", x + 174, y + 142, 40, "light", 16, 140)
    local function setTime(field, cur, label)
        self:timeDialog(kind .. " · time " .. label, cur, function(hhmm)
            local iso = N.isoAt(N.today(), hhmm)
            self:setAttendance(kind, { [field] = N.date(iso) }, function(p)
                p.properties = p.properties or {}
                p.properties[field] = { type = "date", date = { start = iso } }
            end)
        end)
    end
    self:zone({ x + 12, y + 136, 150, 52 }, function() setTime("In", inm and N.hhmm(inm) or def[1], "in") end)
    self:zone({ x + 170, y + 136, 150, 52 }, function() setTime("Out", outm and N.hhmm(outm) or def[2], "out") end)
    local hrs = (inm and outm and outm > inm) and string.format("%.1f hours", (outm - inm) / 60) or (status and status or "Not logged yet")
    self:text(hrs, "sans", 14, x + 18, y + 204, self.texfg)
end

function Canvas:setAttendance(kind, props, apply)
    local pg = self.dash.attend[kind]
    if pg then
        self:write(function() return N.update(pg.id, props) end, function() apply(pg) end)
    else
        props.Day = N.title(kind .. " · " .. N.dayTitle())
        props.Date = N.date(N.today())
        props.Type = N.select(kind)
        if not props.Status then props.Status = N.select("Attended") end
        self:write(function() return N.create(N.DS.attend, props) end, function(newpg) self.dash.attend[kind] = newpg end)
    end
end

function Canvas:buildCheckin()
    local L = self.L.checkin
    self:zone(L.back, function() self:go("home") end)
    self:text((os.date("%A, %d %B"):gsub(" 0", " ")), "sans", 16, L.sub[1], L.sub[2], GREY)
    self:tabs("checkin", L.tabs_y)
    if not self:dashFresh() then
        self:lines("Loading from Notion…", "sans", 17, 52, L.lectures[2] + 60, 600, 1, GREY)
        return
    end
    self:attendCard("College", L.college)
    self:attendCard("Work", L.work)

    -- lectures: tap to cycle Attended → Skipped → Cancelled
    local lx, ly = 52, L.lectures[2] + 52
    self:text("Tap: attended → skipped → cancelled", "sans", 12, 380, L.lectures[2] + 20, GREY)
    for _i, sub in ipairs(SUBJECTS) do
        local pg = self.dash.lectures[sub]
        local st = pg and N.get(pg, "Status") or ""
        local label = (SUBJECT_SHORT[sub] or sub) .. (st == "Skipped" and " ×" or (st == "Cancelled" and " –" or ""))
        local style = st == "Attended" and "dark" or (st == "" and "outline" or "grey")
        local w = self:pill(label, lx, ly, 36, style, 13)
        self:zone({ lx, ly - 4, w, 44 }, function()
            local new = LECTURE_NEXT[st] or "Attended"
            if pg then
                self:write(function() return N.update(pg.id, { Status = N.select(new) }) end,
                    function() self:setProp(pg, "Status", new) end)
            else
                self:write(function()
                    return N.create(N.DS.lectures, { Lecture = N.title(sub .. " · " .. N.dayTitle()),
                        Subject = N.select(sub), Date = N.date(N.today()), Status = N.select(new) })
                end, function(newpg) self.dash.lectures[sub] = newpg end)
            end
        end)
        lx = lx + w + 8
        if lx > 620 then lx, ly = 52, ly + 46 end
    end

    -- habits
    local row = self.dash.checkin
    local hx0, hy0 = 52, L.habits[2] + 50
    for i, h in ipairs(HABITS) do
        local col, r = (i - 1) % 3, math.floor((i - 1) / 3)
        local x, y = hx0 + col * 220, hy0 + r * 46
        local on = row and N.get(row, h) or false
        self:dot(x, y + 6, 24, on)
        self:text(h, "sans", 16, x + 34, y + 6, BLACK, on)
        self:zone({ x - 6, y - 4, 214, 44 }, function()
            self:checkinRow(function(pg)
                local new = not (N.get(pg, h) or false)
                self:write(function() return N.update(pg.id, { [h] = N.check(new) }) end,
                    function() self:setProp(pg, h, new) end)
            end)
        end)
    end

    -- herbal tea, calm, focus
    local dy = L.dials[2]
    local tea = row and N.get(row, "Herbal tea") or 0
    self:text("Herbal tea", "sans", 15, 52, dy + 18, BLACK, true)
    self:pill("–", 52, dy + 48, 40, "outline", 18, 52)
    self:text(tostring(tea) .. " / 2", "serif", 24, 116, dy + 52)
    self:pill("+", 186, dy + 48, 40, "dark", 18, 52)
    local function setNum(name, value)
        self:checkinRow(function(pg)
            self:write(function() return N.update(pg.id, { [name] = N.num(value) }) end,
                function() self:setProp(pg, name, value) end)
        end)
    end
    self:zone({ 48, dy + 44, 60, 50 }, function() if tea > 0 then setNum("Herbal tea", tea - 1) end end)
    self:zone({ 182, dy + 44, 60, 50 }, function() setNum("Herbal tea", tea + 1) end)
    for k, name in ipairs({ "Calm", "Focus" }) do
        local x0 = 276 + (k - 1) * 224
        local v = row and N.get(row, name) or nil
        self:text(name, "sans", 15, x0, dy + 18, BLACK, true)
        for n = 1, 5 do
            local x = x0 + (n - 1) * 42
            self:pill(tostring(n), x, dy + 48, 38, (v and n <= v) and "dark" or "outline", 14, 38)
            self:zone({ x - 2, dy + 44, 42, 48 }, function() setNum(name, n) end)
        end
    end
end

---------------------------------------------------------------- substacks

function Canvas:showFollowing()
    local list = self.manifest and self.manifest.substack_following or {}
    local lines = {}
    for _i, f in ipairs(list) do table.insert(lines, "• " .. (f.name or "") .. "  —  " .. (f.area or "")) end
    if #lines == 0 then table.insert(lines, "Nothing yet. Tap Download on Home first.") end
    table.insert(lines, "")
    table.insert(lines, "To add a Substack, subscribe to it in the Substack app or website. It appears here the next morning. Unsubscribe there to remove it.")
    local ok, TextViewer = pcall(require, "ui/widget/textviewer")
    if ok then
        UIManager:show(TextViewer:new{ title = "Following · " .. #list, text = table.concat(lines, "\n") })
    else
        UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
    end
end

function Canvas:buildSubs()
    local L = self.L.subs
    self:zone(L.back, function() self:go("home") end)
    local nfollow = #(self.manifest and self.manifest.substack_following or {})
    self:pill("Following · " .. nfollow, 548, 130, 30, "outline", 13, 150)
    self:zone({ 548, 120, 160, 44 }, function() self:showFollowing() end)
    local d = self:isToday() and self:files("substacks")[1] or nil
    local posts = d and d.posts or {}
    local st = readState()
    local date = self.manifest and self.manifest.date or ""
    local pk = L.pick

    if #posts == 0 then
        self:text("No new posts today", "sans", 16, L.sub[1], L.sub[2], GREY)
        self:lines("Nothing new yet", "serif", 26, pk[1] + 22, pk[2] + 60, 640, 1, self.texfg)
        self:lines("New posts from the Substacks you follow arrive with the morning papers. Tap Following to see the list.", "sans", 17, 52, L.rows_y + 10, 620, 4, GREY, 26)
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
    self:text((p.pub or "") .. " · " .. (p.mins or 1) .. " min", "sans", 14, pk[1] + 200, pk[2] + 20, self.texfg)
    self:lines(p.title or "", "serif", 24, pk[1] + 22, pk[2] + 54, 650, 1, self.texfg)
    self:lines(p.summary or "", "sans", 15, pk[1] + 22, pk[2] + 92, 650, 2, self.texfg, 22)
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
    N = N or dofile(self.path .. "/notion.lua")
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
    UIManager:nextTick(function() self:hookFileBrowser() end)
end

-- In the file browser (Library), the house icon at the top left goes back to self.v2 Home.
-- Holding it still opens your home folder, as KOReader normally does.
function SelfV2:hookFileBrowser()
    local tb = self.ui and self.ui.title_bar
    if not tb then return end
    local original = tb.left_icon_tap_callback
    local cb = function() self:showHome() end
    tb.left_icon_tap_callback = cb
    if tb.left_button then
        tb.left_button.callback = cb
        if original then
            tb.left_button.hold_callback = original
            tb.left_icon_hold_callback = original
        end
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

function SelfV2:onToggleNightMode()
    if self.canvas and self.canvas.is_open then
        UIManager:scheduleIn(0.2, function() self.canvas:rebuild("full") end)
    end
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

function SelfV2:notionSetup(bad)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = bad and _("Notion didn't accept that key") or _("Connect Notion"),
        description = _("Paste or type your Notion integration secret (it starts with ntn_). Easier: copy it into koreader/settings/selfv2_notion_token.txt over USB."),
        input = "", input_hint = "ntn_…",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local t = dlg:getInputText()
                UIManager:close(dlg)
                if t and t:match("%S") then
                    N.setToken(t)
                    if self.canvas and self.canvas.is_open then self.canvas.dash = nil; self.canvas:loadDash() end
                end
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
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
            item(_("Connect Notion"), function() self:notionSetup(false) end),
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
