-- PronounDB lookups (primary, batched by Twitch user id). Misses go to alejo.io.
local json = require("chatterino.json")
local config = require("config")
local util = require("util")
local http = require("http")
local pending = require("pending")
local alejo = require("alejo")

local pronoundb = {}

local NAMES = {
    he = { "He", "Him" }, she = { "She", "Her" }, it = { "It", "Its" }, they = { "They", "Them" },
    any = { "Any" }, ask = { "Ask" }, avoid = { "Avoid" }, other = { "Other" },
}

local queue = {} -- { {login=, uid=}, ... }
local busy = false

-- sets = { en = { "he", "they" } } -> "He/They"; single set -> "He/Him";
-- none or any unknown id -> false (let alejo.io try instead).
local function label(sets)
    local ids = type(sets) == "table" and sets.en
    if type(ids) ~= "table" or #ids == 0 then return false end
    local subjects = {}
    for i, id in ipairs(ids) do
        local names = NAMES[id]
        if not names then return false end
        subjects[i] = names[1]
    end
    if #ids == 1 then return table.concat(NAMES[ids[1]], "/") end
    return table.concat(subjects, "/")
end

local function resolve(item, results, failed)
    local found = type(results) == "table" and results[item.uid]
    local pronouns = type(found) == "table" and label(found.sets) or false
    if pronouns then
        pending.resolve(item.login, pronouns)
    else
        alejo.enqueue(item.login, failed)
    end
end

-- Sends up to PDB_BATCH_SIZE queued ids in one request.
function pronoundb.flush()
    if busy or #queue == 0 then return end
    local count = math.min(config.PDB_BATCH_SIZE, #queue)
    local batch = table.move(queue, 1, count, 1, {})
    queue = table.move(queue, count + 1, #queue, 1, {})
    local uids = {}
    for i, item in ipairs(batch) do uids[i] = item.uid end

    local results, failed = nil, true -- stays failed if on_success throws
    local function finish()
        busy = false
        for _, item in ipairs(batch) do
            if not util.try(resolve, item, results, failed) then
                util.try(pending.resolve, item.login, false, true)
            end
        end
        if #queue >= config.PDB_BATCH_SIZE then pronoundb.flush() end
    end

    local req = http.get(config.PDB_API .. table.concat(uids, ","),
        { ["X-PronounDB-Source"] = config.USER_AGENT })
    if not req then return finish() end
    busy = true
    req:on_success(function(res)
        local ok, data = pcall(json.parse, res:data())
        if ok and type(data) == "table" then results, failed = data, false end
    end)
    req:on_error(function(res)
        util.warn("PronounDB error:", res:error())
    end)
    req:finally(finish)
    req:execute()
end

function pronoundb.enqueue(login, uid)
    queue[#queue + 1] = { login = login, uid = uid }
    if #queue >= config.PDB_BATCH_SIZE then pronoundb.flush() end
end

return pronoundb
