-- alejo.io lookups (fallback, one request per user, limited parallelism).
local json = require("chatterino.json")
local config = require("config")
local util = require("util")
local http = require("http")
local pending = require("pending")
local pronoun_list = require("pronoun_list")

local alejo = {}

local queue = {} -- FIFO of logins: queue[head..tail]
local head, tail = 1, 0
local running = 0

local pump -- forward

-- Queue a lookup (waits for the pronoun list, needed for labels).
-- pdb_unconfirmed: PronounDB failed or was not asked -> "no pronouns" is not final.
function alejo.enqueue(login, pdb_unconfirmed)
    local entry = pending.get(login)
    if entry then entry.pdb_unconfirmed = pdb_unconfirmed or nil end
    tail = tail + 1
    queue[tail] = login
    pronoun_list.with(pump)
end

-- outcome: "found" | "none" | "unknown_id" | "error"
local function resolve(login, outcome, pronouns)
    local entry = pending.get(login)
    if outcome == "found" then
        pending.resolve(login, pronouns)
    elseif outcome == "none" then
        -- "no pronouns" is only trusted if PronounDB answered too
        pending.resolve(login, false, entry and entry.pdb_unconfirmed or false)
    elseif outcome == "unknown_id" then
        if entry and not entry.list_retried and pronoun_list.age() >= config.ERROR_BACKOFF_S then
            -- list probably outdated: refresh it and retry this user once
            entry.list_retried = true
            pronoun_list.mark_stale()
            alejo.enqueue(login, entry.pdb_unconfirmed)
        else
            -- list is recent and still lacks the id: show what we know, normal TTL
            util.warn("unknown pronoun id for", login)
            pending.resolve(login, pronouns or false)
        end
    else
        pending.resolve(login, false, true)
    end
end

local function fetch(login)
    local req = http.get(config.ALEJO_API .. "/users/" .. login)
    if not req then return pending.resolve(login, false, true) end
    running = running + 1
    local outcome, pronouns = "error", false -- stays "error" if on_success throws
    req:on_success(function(res)
        local ok, data = pcall(json.parse, res:data())
        if not ok or type(data) ~= "table" then return end
        if not util.is_id(data.pronoun_id) then
            outcome = "none"
            return
        end
        local label, complete = pronoun_list.label(data.pronoun_id, data.alt_pronoun_id)
        pronouns = label or false
        outcome = complete and "found" or "unknown_id"
    end)
    req:on_error(function(res)
        if res:status() == 404 then outcome = "none" end -- 404 = user has no pronouns set
    end)
    req:finally(function()
        running = running - 1
        if not util.try(resolve, login, outcome, pronouns) then
            util.try(pending.resolve, login, false, true)
        end
        -- via the list: if a refresh is due, wait for it instead of using the old one
        pronoun_list.with(pump)
    end)
    req:execute()
end

pump = function()
    while running < config.ALEJO_MAX_PARALLEL and head <= tail do
        local login = queue[head]
        queue[head] = nil
        head = head + 1
        fetch(login)
    end
    if head > tail then
        queue, head, tail = {}, 1, 0
    end
end

return alejo
