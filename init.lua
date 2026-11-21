-- Show pronouns (PronounDB batched, alejo.io fallback) directly in chat.
-- Each user is looked up at most once per TTL; cache lives in data/cache.json.
local json = require("chatterino.json")

---------------------------------------------------------------- Constants
local API = "https://api.pronouns.alejo.io/v1"
local TTL = 24 * 3600           -- 1 day per user (also for "no pronouns")
local ERR_TTL = 15 * 60         -- after an error: back off 15 min (user and list)
local MAX_PARALLEL = 3          -- concurrent requests
local TIMEOUT_MS = 10000
local SAVE_INTERVAL_MS = 60 * 1000
local SCAN_INTERVAL_MS = 3000
local CACHE_FILE = "cache.json"
local CACHE_VERSION = 2         -- 2: "no pronouns" also checked via PronounDB
local PDB_API = "https://pronoundb.org/api/v2/lookup?platform=twitch&ids="
local PDB_BATCH = 50            -- max IDs per PronounDB request
local PDB_FLUSH_MS = 2000       -- collect, then query in one batch
local USER_AGENT = "chatterino-pronouns-plugin/1.1.0 (Chatterino Lua plugin)"

local USERNAME = c2.MessageElementFlag.Username
local REPLIED = c2.MessageElementFlag.RepliedMessage
local SYSTEM = c2.MessageFlag.System

local function log(...) c2.log(c2.LogLevel.Info, "[pronouns]", ...) end
local function warn(...) c2.log(c2.LogLevel.Warning, "[pronouns]", ...) end

-- Runs fn protected and always reschedules it,
-- so a single error never kills the loop.
local function every(ms, fn)
    local function tick()
        local ok, err = pcall(fn)
        if not ok then warn(err) end
        c2.later(tick, ms)
    end
    return tick
end

---------------------------------------------------------------- Time
local function _days_from_civil(y, m, d)
    y = (m <= 2) and (y - 1) or y
    local era = (y >= 0 and y or y - 399) // 400
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = (153 * mp + 2) // 5 + d - 1
    local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468
end

-- Seconds since epoch (local time is fine for TTL comparisons).
local now
if os and os.time then
    now = os.time
else
    now = function()
        local s = c2.DateTime.current_local():to_iso_string_without_ms()
        local y, mo, d, h, mi, se = s:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
        return _days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
            + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(se)
    end
end

---------------------------------------------------------------- Cache
-- users[login] = { p = "He/Him" | false, t = epoch, err = true|nil }
local cache = { users = {}, pronouns = nil, pronouns_t = 0 }
local dirty = false

local function is_fresh(e, t)
    return t - (e.t or 0) < (e.err and ERR_TTL or TTL)
end

local function prune()
    local t = now()
    for login, e in pairs(cache.users) do
        if not is_fresh(e, t) then cache.users[login] = nil end
    end
end

local function load_cache()
    local f = io.open(CACHE_FILE, "r")
    if not f then return end
    local raw = f:read("a")
    f:close()
    local ok, data = pcall(json.parse, raw)
    if not ok or type(data) ~= "table" then
        warn("cache corrupt, rebuilding")
        return
    end
    cache.pronouns = type(data.pronouns) == "table" and data.pronouns or nil
    cache.pronouns_t = tonumber(data.pronouns_t) or 0
    local old = data.v ~= CACHE_VERSION -- recheck old negative entries (now with PronounDB)
    for login, e in pairs(type(data.users) == "table" and data.users or {}) do
        if type(e) == "table" and not e.err and not (old and not e.p) then cache.users[login] = e end
    end
    prune()
end

local function save_cache()
    prune()
    if not dirty then return end
    local users = {}
    for login, e in pairs(cache.users) do
        if not e.err then users[login] = e end
    end
    local f = io.open(CACHE_FILE, "w")
    if not f then
        warn("cache not writable")
        return
    end
    f:write(json.stringify({ v = CACHE_VERSION, users = users, pronouns = cache.pronouns, pronouns_t = cache.pronouns_t }))
    f:close()
    dirty = false
end

local function lookup(login)
    local e = cache.users[login]
    if e and is_fresh(e, now()) then return e end
    cache.users[login] = nil
    return nil
end

---------------------------------------------------------------- Pronoun list
local list_loading = false
local list_failed_t = -math.huge
local list_waiters = {}

local function label(pid, alt)
    local list = cache.pronouns
    local p = list and list[pid]
    if not p then return nil end
    local a = alt and list[alt]
    if a then return p.subject .. "/" .. a.subject end
    if p.singular then return p.subject end
    return p.subject .. "/" .. p.object
end

-- Calls after() once a valid list is available.
local function with_pronoun_list(after)
    local t = now()
    if cache.pronouns and t - cache.pronouns_t < TTL then
        after()
        return
    end
    if cache.pronouns and t - list_failed_t < ERR_TTL then
        after() -- reuse stale list instead of hammering the API
        return
    end
    list_waiters[after] = true -- set: same function only once
    if list_loading or t - list_failed_t < ERR_TTL then return end

    list_loading = true
    local req = c2.HTTPRequest.create(c2.HTTPMethod.Get, API .. "/pronouns")
    req:set_timeout(TIMEOUT_MS)
    req:on_success(function(res)
        local ok, data = pcall(json.parse, res:data())
        if ok and type(data) == "table" then
            cache.pronouns, cache.pronouns_t, dirty = data, now(), true
        else
            list_failed_t = now()
        end
    end)
    req:on_error(function(res)
        list_failed_t = now()
        warn("pronoun list error:", res:error())
    end)
    req:finally(function()
        list_loading = false
        if not cache.pronouns then return end -- waiters stay until the next attempt
        local waiters = list_waiters
        list_waiters = {}
        for fn in pairs(waiters) do fn() end
    end)
    req:execute()
end

---------------------------------------------------------------- User lookups
-- pending[login] = { uid = "123", waiting = { {channel, msg}, ... }, pdb_err = bool }
local pending = {}
local queue = {}   -- FIFO of alejo lookups
local queue_head = 1
local running = 0

local decorate -- forward
local pump     -- forward

-- Queue an alejo lookup (needs the pronoun list for labels).
local function alejo_enqueue(login, pdb_err)
    local entry = pending[login]
    if entry then entry.pdb_err = pdb_err or nil end
    queue[#queue + 1] = login
    with_pronoun_list(pump)
end

local function finish(login, p, err)
    cache.users[login] = { p = p, t = now(), err = err or nil }
    if not err then dirty = true end
    local entry = pending[login]
    pending[login] = nil
    if not entry then return end
    for _, w in ipairs(entry.waiting) do
        local ok, e = pcall(decorate, w[1], w[2])
        if not ok then warn(e) end
    end
end

local function request(url)
    local req = c2.HTTPRequest.create(c2.HTTPMethod.Get, url)
    req:set_timeout(TIMEOUT_MS)
    req:set_header("User-Agent", USER_AGENT)
    return req
end

------------------------------------------------ PronounDB (primary, batched)
local PDB_NAMES = {
    he = { "He", "Him" }, she = { "She", "Her" }, it = { "It", "Its" }, they = { "They", "Them" },
    any = { "Any" }, ask = { "Ask" }, avoid = { "Avoid" }, other = { "Other" },
}

local function pdb_label(sets)
    local list = type(sets) == "table" and sets.en
    if type(list) ~= "table" or #list == 0 then return false end
    local first = PDB_NAMES[list[1]]
    if not first then return false end
    if #list == 1 then return table.concat(first, "/") end
    local parts = {}
    for _, k in ipairs(list) do
        local n = PDB_NAMES[k]
        if n then parts[#parts + 1] = n[1] end
    end
    return table.concat(parts, "/")
end

local pdb_queue = {} -- { {login, uid}, ... }
local pdb_busy = false

local function pdb_flush()
    if pdb_busy or #pdb_queue == 0 then return end
    local batch, ids = {}, {}
    while #batch < PDB_BATCH and #pdb_queue > 0 do
        local item = table.remove(pdb_queue, 1)
        batch[#batch + 1] = item
        ids[#ids + 1] = item[2]
    end
    pdb_busy = true
    local results, failed = nil, false
    local req = request(PDB_API .. table.concat(ids, ","))
    req:set_header("X-PronounDB-Source", USER_AGENT)
    req:on_success(function(res)
        local ok, d = pcall(json.parse, res:data())
        if ok and type(d) == "table" then results = d else failed = true end
    end)
    req:on_error(function(res)
        failed = true
        warn("PronounDB error:", res:error())
    end)
    req:finally(function()
        pdb_busy = false
        for _, item in ipairs(batch) do
            local login, uid = item[1], item[2]
            local p = results and results[uid] and pdb_label(results[uid].sets) or false
            if p then
                finish(login, p)
            else
                alejo_enqueue(login, failed)
            end
        end
        if #pdb_queue >= PDB_BATCH then pdb_flush() end
    end)
    req:execute()
end

local function pdb_enqueue(login, uid)
    pdb_queue[#pdb_queue + 1] = { login, uid }
    if #pdb_queue >= PDB_BATCH then pdb_flush() end
end

------------------------------------------------ alejo.io (fallback, one per user)
local function alejo_done(login, p, err)
    local entry = pending[login]
    if p then return finish(login, p) end
    finish(login, false, err or (entry and entry.pdb_err) or false)
end

local function fetch(login)
    running = running + 1
    local p, err = false, false
    local req = request(API .. "/users/" .. login)
    req:on_success(function(res)
        local ok, d = pcall(json.parse, res:data())
        if ok and type(d) == "table" then
            p = d.pronoun_id and label(d.pronoun_id, d.alt_pronoun_id) or false
        else
            err = true
        end
    end)
    req:on_error(function(res)
        err = res:status() ~= 404
    end)
    req:finally(function()
        running = running - 1
        alejo_done(login, p, err)
        pump()
    end)
    req:execute()
end

pump = function()
    while running < MAX_PARALLEL and queue_head <= #queue do
        local login = queue[queue_head]
        queue[queue_head] = nil
        queue_head = queue_head + 1
        fetch(login)
    end
    if queue_head > #queue then
        queue, queue_head = {}, 1
    end
end

---------------------------------------------------------------- Message rewriting
decorate = function(channel, msg)
    local e = cache.users[msg.login_name]
    if not (e and e.p) or not channel:is_valid() then return end

    local orig = msg:elements()
    local idx
    for i = 1, #orig do
        local f = orig[i].flags
        if (f & USERNAME) ~= 0 and (f & REPLIED) == 0 then
            idx = i
            break
        end
    end
    if not idx then return end

    -- Trim the copy up to the username, insert pronouns, re-append the rest.
    local new = msg:clone()
    local els = new:elements()
    for i = #els, idx, -1 do els:erase(i) end
    new:append_element({
        type = "text",
        text = e.p,
        color = "system",
        style = c2.FontStyle.ChatMediumSmall,
        flags = c2.MessageElementFlag.Text,
        tooltip = "Pronouns (PronounDB / alejo.io)",
    })
    for i = idx, #orig do new:append_element(orig[i]) end
    channel:replace_message(msg, new)
end

local function on_message(channel, msg)
    local login = msg.login_name
    if not login or login == "" or (msg.flags & SYSTEM) ~= 0 then return end

    local e = lookup(login)
    if e then
        if e.p then
            -- do not replace synchronously inside the append signal
            c2.later(function() pcall(decorate, channel, msg) end, 1)
        end
        return
    end

    local entry = pending[login]
    if entry then
        table.insert(entry.waiting, { channel, msg })
        return
    end
    local uid = msg.user_id
    pending[login] = { uid = uid, waiting = { { channel, msg } } }
    if uid and uid ~= "" then
        pdb_enqueue(login, uid)
    else
        alejo_enqueue(login)
    end
end

---------------------------------------------------------------- Channel hooks
local hooked = {} -- name -> { ch = Channel, h = ConnectionHandle }

local function hook(ch)
    if not (ch and ch:is_valid()) or ch:get_type() ~= c2.ChannelType.Twitch then return end
    local name = ch:get_name()
    local cur = hooked[name]
    if cur and cur.ch:is_valid() and cur.h:is_connected() then return end
    local h = ch:on_message_appended(function(msg)
        local ok, err = pcall(on_message, ch, msg)
        if not ok then warn(err) end
    end)
    hooked[name] = { ch = ch, h = h }
end

local function scan()
    for _, win in ipairs(c2.windows:all()) do
        local nb = win.notebook
        for i = 0, nb.page_count - 1 do
            local page = nb:page_at(i)
            if page then
                for _, split in ipairs(page:splits()) do
                    local ok, err = pcall(hook, split.channel)
                    if not ok then warn(err) end
                end
            end
        end
    end
end

---------------------------------------------------------------- Start
load_cache()
with_pronoun_list(function() end)
c2.later(every(SAVE_INTERVAL_MS, save_cache), SAVE_INTERVAL_MS)
c2.later(every(SCAN_INTERVAL_MS, scan), 500)
c2.later(every(PDB_FLUSH_MS, pdb_flush), PDB_FLUSH_MS)

local n = 0
for _ in pairs(cache.users) do n = n + 1 end
log("loaded, users in cache:", n)
