-- In-memory cache of users and the alejo.io pronoun list, persisted to data/cache.json.
local json = require("chatterino.json")
local config = require("config")
local util = require("util")

local cache = {
    -- users[login] = { pronouns = "He/Him" | false, fetched_at = epoch seconds, failed = true|nil }
    users = {},
    -- alejo.io /pronouns response (id -> { subject, object, singular })
    pronoun_list = nil,
    pronoun_list_fetched_at = 0,
    -- set when something worth saving changed
    dirty = false,
}

local function is_fresh(user, current_time)
    local ttl = user.failed and config.ERROR_BACKOFF_S or config.CACHE_TTL_S
    return current_time - user.fetched_at < ttl
end

local function prune()
    local current_time = util.now()
    for login, user in pairs(cache.users) do
        if not is_fresh(user, current_time) then cache.users[login] = nil end
    end
end

-- Reads one cached user; also accepts the short keys of cache versions 1-2
-- (p = pronouns, t = fetched_at). Returns nil for invalid or dropped entries.
-- recheck_negatives: drop "no pronouns" so they get rechecked via PronounDB.
local function read_cached_user(user, recheck_negatives)
    if type(user) ~= "table" or user.failed or user.err then return nil end
    local pronouns = user.pronouns
    if pronouns == nil then pronouns = user.p end
    local fetched_at = user.fetched_at or user.t
    if type(fetched_at) ~= "number" then return nil end
    if pronouns == false then
        if recheck_negatives then return nil end
    elseif not util.is_id(pronouns) then
        return nil
    end
    return { pronouns = pronouns, fetched_at = fetched_at }
end

function cache.load()
    local file = io.open(config.CACHE_FILE, "r")
    if not file then return end
    local raw = file:read("a")
    file:close()
    local ok, data = pcall(json.parse, raw)
    if not ok or type(data) ~= "table" then
        util.warn("cache corrupt, rebuilding")
        return
    end
    local version = tonumber(data.version or data.v) or 1
    local list = data.pronoun_list or data.pronouns
    cache.pronoun_list = type(list) == "table" and list or nil
    cache.pronoun_list_fetched_at = tonumber(data.pronoun_list_fetched_at or data.pronouns_t) or 0
    local recheck_negatives = version < 2
    for login, user in pairs(type(data.users) == "table" and data.users or {}) do
        cache.users[login] = read_cached_user(user, recheck_negatives)
    end
    prune()
end

function cache.save()
    prune()
    if not cache.dirty then return end
    local users = {}
    for login, user in pairs(cache.users) do
        if not user.failed then users[login] = user end
    end
    -- Serialize before opening: "w" truncates, a failing stringify would wipe the cache.
    local ok, text = pcall(json.stringify, {
        version = config.CACHE_VERSION,
        users = users,
        pronoun_list = cache.pronoun_list,
        pronoun_list_fetched_at = cache.pronoun_list_fetched_at,
    })
    if not ok then
        util.warn("cache not serializable:", text)
        return
    end
    local file = io.open(config.CACHE_FILE, "w")
    if not file then
        util.warn("cache not writable")
        return
    end
    file:write(text)
    file:close()
    cache.dirty = false
end

-- Fresh cache entry for login, or nil (expired entries are dropped).
function cache.lookup(login)
    local user = cache.users[login]
    if user and is_fresh(user, util.now()) then return user end
    cache.users[login] = nil
    return nil
end

-- pronouns: label string or false; failed: keep only for ERROR_BACKOFF_S, never saved.
function cache.store(login, pronouns, failed)
    cache.users[login] = { pronouns = pronouns, fetched_at = util.now(), failed = failed or nil }
    if not failed then cache.dirty = true end
end

function cache.count()
    local count = 0
    for _ in pairs(cache.users) do count = count + 1 end
    return count
end

return cache
