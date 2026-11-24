-- Inserts the pronoun label in front of the username of a chat message.
local cache = require("cache")

local USERNAME_FLAG = c2.MessageElementFlag.Username
local REPLIED_FLAG = c2.MessageElementFlag.RepliedMessage

-- Replaces msg with a copy that has the pronoun label inserted before the username.
local function decorate(channel, msg)
    local user = cache.users[msg.login_name]
    if not (user and user.pronouns) or not channel:is_valid() then return end

    local orig = msg:elements()
    local username_idx
    for i = 1, #orig do
        local flags = orig[i].flags
        if (flags & USERNAME_FLAG) ~= 0 and (flags & REPLIED_FLAG) == 0 then
            username_idx = i
            break
        end
    end
    if not username_idx then return end

    -- Trim the copy up to the username, insert pronouns, re-append the rest.
    local new = msg:clone()
    local els = new:elements()
    for i = #els, username_idx, -1 do els:erase(i) end
    new:append_element({
        type = "text",
        text = user.pronouns,
        color = "system",
        style = c2.FontStyle.ChatMediumSmall,
        flags = c2.MessageElementFlag.Text,
        tooltip = "Pronouns (PronounDB / alejo.io)",
    })
    for i = username_idx, #orig do new:append_element(orig[i]) end
    channel:replace_message(msg, new)
end

return decorate
