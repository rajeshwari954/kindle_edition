--[[
Tiny Notion API client for the Kindle (KOReader's LuaSocket + LuaSec, rapidjson).
The integration token is read from KOReader's settings, or once from the file
koreader/settings/selfv2_notion_token.txt (copied over USB), then remembered.
]]

local DataStorage = require("datastorage")
local rapidjson = require("rapidjson")
local logger = require("logger")

local N = {}
N.VERSION = "2025-09-03"
N.TZ_MIN = 330 -- India: UTC+05:30

N.DS = {
    checkin  = "4c7beacd-8cd4-4a30-85ba-ad76dc0ee4a5",
    blocks   = "835dea4b-ac50-44eb-8920-c74093e4e5df",
    todos    = "3433145a-d537-40d4-92e9-3f9b1a53602a",
    attend   = "42126113-480c-813c-8b0e-000b63a190dd",
    lectures = "42126113-480c-818e-80fc-000beaf9718f",
    sleep    = "f23d3475-5992-46c1-8484-34d3aa17724a",
}

function N.token()
    local t = G_reader_settings:readSetting("selfv2_notion_token")
    if t and t ~= "" then return t end
    local path = DataStorage:getSettingsDir() .. "/selfv2_notion_token.txt"
    local fh = io.open(path, "r")
    if fh then
        t = (fh:read("*a") or ""):match("%S+")
        fh:close()
        if t then
            G_reader_settings:saveSetting("selfv2_notion_token", t)
            return t
        end
    end
    return nil
end

function N.setToken(t)
    G_reader_settings:saveSetting("selfv2_notion_token", t and t:match("%S+") or nil)
end

-- Returns ok, decoded-response-or-error-message
function N.request(method, path, body)
    local token = N.token()
    if not token then return false, "no_token" end
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local payload = body and rapidjson.encode(body) or nil
    local chunks = {}
    local headers = {
        ["Authorization"] = "Bearer " .. token,
        ["Notion-Version"] = N.VERSION,
        ["Accept"] = "application/json",
    }
    if payload then
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#payload)
    end
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code = socket.skip(1, http.request{
        url = "https://api.notion.com/v1" .. path, method = method, headers = headers,
        source = payload and ltn12.source.string(payload) or nil, sink = ltn12.sink.table(chunks),
    })
    socketutil:reset_timeout()
    local raw = table.concat(chunks)
    local ok, data = pcall(rapidjson.decode, raw)
    if code == 200 and ok and type(data) == "table" then return true, data end
    local msg = (ok and type(data) == "table" and data.message) or tostring(code)
    logger.warn("selfv2 notion", method, path, code, msg)
    if code == 401 then return false, "bad_token" end
    if code == 404 then return false, "not_shared" end
    return false, msg
end

function N.query(ds, filter, sorts)
    local body = { page_size = 100 }
    if filter then body.filter = filter end
    if sorts then body.sorts = sorts end
    local ok, res = N.request("POST", "/data_sources/" .. ds .. "/query", body)
    if not ok then return false, res end
    return true, res.results or {}
end

function N.create(ds, props)
    return N.request("POST", "/pages", { parent = { type = "data_source_id", data_source_id = ds }, properties = props })
end

function N.update(id, props)
    return N.request("PATCH", "/pages/" .. id, { properties = props })
end

function N.trash(id)
    return N.request("PATCH", "/pages/" .. id, { in_trash = true })
end

---------------------------------------------------------------- property helpers

function N.title(s) return { title = { { text = { content = s } } } } end
function N.text(s) return { rich_text = { { text = { content = s } } } } end
function N.check(b) return { checkbox = b and true or false } end
function N.num(n) return { number = n } end
function N.select(name) return { select = name and { name = name } or rapidjson.null } end
function N.date(start, finish)
    if not start then return { date = rapidjson.null } end
    return { date = { start = start, ["end"] = finish } }
end

local function plain(arr)
    if type(arr) ~= "table" then return "" end
    local out = {}
    for _i, t in ipairs(arr) do out[#out + 1] = t.plain_text or "" end
    return table.concat(out)
end

-- Read a property's value in a simple form.
function N.get(page, name)
    local p = page.properties and page.properties[name]
    if type(p) ~= "table" then return nil end
    local t = p.type
    if t == "title" then return plain(p.title) end
    if t == "rich_text" then return plain(p.rich_text) end
    if t == "checkbox" then return p.checkbox == true end
    if t == "number" then return type(p.number) == "number" and p.number or nil end
    if t == "select" then return type(p.select) == "table" and p.select.name or nil end
    if t == "date" then
        if type(p.date) ~= "table" then return nil end
        return { start = p.date.start, finish = type(p.date["end"]) == "string" and p.date["end"] or nil }
    end
    return nil
end

---------------------------------------------------------------- dates and times

N.today = function() return os.date("%Y-%m-%d") end
N.dayTitle = function(date) return (os.date("%a, %d %b", date and N.dateTime(date) or nil):gsub(" 0", " ")) end

local function days_from_civil(y, m, d)
    y = (m <= 2) and (y - 1) or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

-- "2026-10-26T09:00:00.000Z" or "...+05:30" → minutes since local midnight, and the local date
function N.localTime(iso)
    if type(iso) ~= "string" then return nil end
    local y, mo, d, h, mi = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+)")
    if not y then return nil end
    local off = 0
    local sign, oh, om = iso:match("([%+%-])(%d%d):(%d%d)$")
    if sign then off = (tonumber(oh) * 60 + tonumber(om)) * (sign == "-" and -1 or 1) end
    local total = days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 1440 + tonumber(h) * 60 + tonumber(mi) - off + N.TZ_MIN
    local day = math.floor(total / 1440)
    local mins = total - day * 1440
    -- back to a date string
    local z = day + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local yy = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local dd = doy - math.floor((153 * mp + 2) / 5) + 1
    local mm = mp < 10 and mp + 3 or mp - 9
    if mm <= 2 then yy = yy + 1 end
    return mins, string.format("%04d-%02d-%02d", yy, mm, dd)
end

function N.hhmm(mins)
    if not mins then return "" end
    return string.format("%02d:%02d", math.floor(mins / 60), mins % 60)
end

-- local "HH:MM" today → ISO with the India offset
function N.isoAt(date, hhmm)
    return string.format("%sT%s:00+05:30", date, hhmm)
end

function N.prevDay(date)
    local y, m, d = date:match("(%d+)-(%d+)-(%d+)")
    local t = os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d) - 1, hour = 12 }
    return os.date("%Y-%m-%d", t)
end

function N.dateTime(date)
    local y, m, d = date:match("(%d+)-(%d+)-(%d+)")
    return os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
end

function N.nextDay(date)
    local y, m, d = date:match("(%d+)-(%d+)-(%d+)")
    local t = os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d) + 1, hour = 12 }
    return os.date("%Y-%m-%d", t)
end

return N
