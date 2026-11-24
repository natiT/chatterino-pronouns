-- Show pronouns (PronounDB batched, alejo.io fallback) directly in chat.
-- Each user is looked up at most once per CACHE_TTL_S; cache lives in data/cache.json.
--
-- Modules:
--   config        tunables
--   util          logging, protected calls, timers, time
--   http          request factory
--   cache         users + pronoun list, persisted to cache.json
--   pronoun_list  alejo.io pronoun list and labels
--   pending       running lookups and the messages waiting for them
--   pronoundb     PronounDB batch lookups (primary)
--   alejo         alejo.io lookups (fallback)
--   decorate      inserts the label into a message
--   update_check  notifies about a newer plugin version on GitHub
local config = require("config")
local util = require("util")
local cache = require("cache")
local pronoun_list = require("pronoun_list")
local pending = require("pending")
local pronoundb = require("pronoundb")
local alejo = require("alejo")
local decorate = require("decorate")
local update_check = require("update_check")

local SYSTEM_FLAG = c2.MessageFlag.System

pending.on_resolved = decorate

local function on_message(channel, msg)
    local login = msg.login_name
    if not login or login == "" or (msg.flags & SYSTEM_FLAG) ~= 0 then return end

    local user = cache.lookup(login)
    if user then
        if user.pronouns then
            -- do not replace synchronously inside the append signal
            c2.later(function() util.try(decorate, channel, msg) end, config.DEFER_MS)
        end
        return
    end

    local uid = msg.user_id
    if not pending.add(login, uid, channel, msg) then return end -- already being looked up
    if util.is_id(uid) then
        pronoundb.enqueue(login, uid)
    else
        alejo.enqueue(login, true) -- PronounDB not asked: don't trust "no pronouns"
    end
end

---------------------------------------------------------------- Channel hooks
local hooked = {} -- channel name -> { channel = Channel, handle = ConnectionHandle }

local function hook(channel)
    if not (channel and channel:is_valid()) or channel:get_type() ~= c2.ChannelType.Twitch then return end
    local name = channel:get_name()
    local existing = hooked[name]
    if existing and existing.channel:is_valid() and existing.handle:is_connected() then return end
    local handle = channel:on_message_appended(function(msg)
        util.try(on_message, channel, msg)
    end)
    hooked[name] = { channel = channel, handle = handle }
end

-- Hook every Twitch channel shown in any split of any window.
local function scan()
    for _, window in ipairs(c2.windows:all()) do
        local notebook = window.notebook
        for i = 0, notebook.page_count - 1 do -- page_at is 0-based
            local page = notebook:page_at(i)
            if page then
                for _, split in ipairs(page:splits()) do
                    util.try(hook, split.channel)
                end
            end
        end
    end
end

-- Show a system message in every hooked channel.
local function notify(text)
    for _, entry in pairs(hooked) do
        if entry.channel:is_valid() then
            util.try(entry.channel.add_system_message, entry.channel, text)
        end
    end
end

---------------------------------------------------------------- Start
util.try(cache.load)
pronoun_list.with(util.noop) -- warm up the list
c2.later(util.every(config.SAVE_INTERVAL_MS, cache.save), config.SAVE_INTERVAL_MS)
c2.later(util.every(config.SCAN_INTERVAL_MS, scan), config.SCAN_START_DELAY_MS)
c2.later(util.every(config.PDB_FLUSH_MS, pronoundb.flush), config.PDB_FLUSH_MS)
c2.later(function() util.try(update_check.run, notify) end, config.UPDATE_CHECK_DELAY_MS)

util.log("loaded, users in cache:", cache.count())
