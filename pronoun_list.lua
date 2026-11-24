-- alejo.io pronoun list (id -> subject/object), needed to turn alejo ids into labels.
local json = require("chatterino.json")
local config = require("config")
local util = require("util")
local cache = require("cache")
local http = require("http")

local pronoun_list = {}

local loading = false
local failed_at = -math.huge
local waiters = {} -- set of callbacks: same function only once
local retry_scheduled = false

-- A usable list entry, or nil.
local function entry_for(id)
    local list = cache.pronoun_list
    local entry = util.is_id(id) and list and list[id]
    if type(entry) == "table" and util.is_id(entry.subject) and util.is_id(entry.object) then return entry end
    return nil
end

-- Builds a display label from alejo.io pronoun ids, e.g. "She/Her" or "He/They".
-- Returns label|nil, complete (false if an id is missing from the list).
function pronoun_list.label(pronoun_id, alt_pronoun_id)
    local main = entry_for(pronoun_id)
    if not main then return nil, false end
    local alt = entry_for(alt_pronoun_id)
    local complete = alt ~= nil or not util.is_id(alt_pronoun_id)
    if alt then return main.subject .. "/" .. alt.subject, complete end
    if main.singular == true then return main.subject, complete end
    return main.subject .. "/" .. main.object, complete
end

function pronoun_list.age()
    return util.now() - cache.pronoun_list_fetched_at
end

-- Force a reload on the next pronoun_list.with() call.
function pronoun_list.mark_stale()
    cache.pronoun_list_fetched_at = 0
end

-- No list at all and waiters pending: try again once the backoff is over,
-- otherwise users that are already pending would wait forever.
local function schedule_retry()
    if retry_scheduled or next(waiters) == nil then return end
    retry_scheduled = true
    c2.later(function()
        retry_scheduled = false
        pronoun_list.with(util.noop)
    end, config.LIST_RETRY_MS)
end

local function loaded()
    loading = false
    if not cache.pronoun_list then return schedule_retry() end -- waiters stay
    local ready = waiters
    waiters = {}
    for callback in pairs(ready) do util.try(callback) end
end

-- Calls on_ready() once a usable list is available.
function pronoun_list.with(on_ready)
    local current_time = util.now()
    local has_list = cache.pronoun_list ~= nil
    local fresh = has_list and current_time - cache.pronoun_list_fetched_at < config.CACHE_TTL_S
    local backing_off = current_time - failed_at < config.ERROR_BACKOFF_S
    if fresh or (has_list and backing_off) then
        util.try(on_ready) -- stale list is better than hammering the API
        return
    end
    waiters[on_ready] = true
    if loading or backing_off then return end

    local req = http.get(config.ALEJO_API .. "/pronouns")
    if not req then
        failed_at = util.now()
        return loaded()
    end
    loading = true
    req:on_success(function(res)
        local ok, data = pcall(json.parse, res:data())
        if ok and type(data) == "table" then
            cache.pronoun_list, cache.pronoun_list_fetched_at, cache.dirty = data, util.now(), true
        else
            failed_at = util.now()
        end
    end)
    req:on_error(function(res)
        failed_at = util.now()
        util.warn("pronoun list error:", res:error())
    end)
    req:finally(loaded)
    req:execute()
end

return pronoun_list
