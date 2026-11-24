-- Users currently being looked up, and the messages waiting for their result.
local util = require("util")
local cache = require("cache")

local pending = {
    -- users[login] = { uid = "123", waiting = { {channel=, msg=}, ... },
    --                  pdb_unconfirmed = true|nil, list_retried = true|nil }
    users = {},
    -- called as on_resolved(channel, msg) for each waiting message; set by init.lua
    on_resolved = util.noop,
}

-- Returns true if login is new (caller must start a lookup).
function pending.add(login, uid, channel, msg)
    local waiter = { channel = channel, msg = msg }
    local entry = pending.users[login]
    if entry then
        entry.waiting[#entry.waiting + 1] = waiter
        return false
    end
    pending.users[login] = { uid = uid, waiting = { waiter } }
    return true
end

function pending.get(login)
    return pending.users[login]
end

-- Store the result and hand every waiting message to on_resolved.
-- pronouns: label string or false; failed: cache only for ERROR_BACKOFF_S.
function pending.resolve(login, pronouns, failed)
    cache.store(login, pronouns, failed)
    local entry = pending.users[login]
    pending.users[login] = nil
    if not entry then return end
    for _, waiter in ipairs(entry.waiting) do
        util.try(pending.on_resolved, waiter.channel, waiter.msg)
    end
end

return pending
