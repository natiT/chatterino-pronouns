-- Checks once whether a newer plugin release is published on GitHub.
local json = require("chatterino.json")
local config = require("config")
local util = require("util")
local http = require("http")

local update_check = {}

-- "1.10.2" -> { 1, 10, 2 }; nil if not a dotted number version.
local function parse_version(text)
    if not util.is_id(text) or not text:match("^%d+[%.%d]*$") then return nil end
    local parts = {}
    for number in text:gmatch("%d+") do parts[#parts + 1] = tonumber(number) end
    return parts
end

local function is_newer(remote, current)
    for i = 1, math.max(#remote, #current) do
        local a, b = remote[i] or 0, current[i] or 0
        if a ~= b then return a > b end
    end
    return false
end

-- Calls notify(text) if the published version is newer than config.VERSION.
function update_check.run(notify)
    local req = http.get(config.UPDATE_INFO_URL)
    if not req then return end
    req:on_success(function(res)
        -- GitHub release JSON: { tag_name = "v1.2.0", html_url = "https://github.com/..." }
        local ok, release = pcall(json.parse, res:data())
        if not ok or type(release) ~= "table" or not util.is_id(release.tag_name) then return end
        local remote_version = release.tag_name:gsub("^v", "")
        local remote = parse_version(remote_version)
        local current = parse_version(config.VERSION)
        if not (remote and current) then return end
        if is_newer(remote, current) then
            local link = util.is_id(release.html_url) and release.html_url or config.UPDATE_PAGE_URL
            local text = ("Pronouns plugin update available: %s -> %s (%s)")
                :format(config.VERSION, remote_version, link)
            util.log(text)
            notify(text)
        end
    end)
    req:on_error(function(res)
        if res:status() == 404 then return end -- no release published yet
        util.warn("update check failed:", res:error())
    end)
    req:execute()
end

return update_check
