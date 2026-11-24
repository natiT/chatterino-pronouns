-- HTTP request factory with timeout and User-Agent set.
local config = require("config")
local util = require("util")

local http = {}

-- Returns a configured GET request, or nil if it could not be created.
function http.get(url, extra_headers)
    local ok, request = pcall(function()
        local req = c2.HTTPRequest.create(c2.HTTPMethod.Get, url)
        req:set_timeout(config.HTTP_TIMEOUT_MS)
        req:set_header("User-Agent", config.USER_AGENT)
        for name, value in pairs(extra_headers or {}) do req:set_header(name, value) end
        return req
    end)
    if not ok then
        util.warn("request failed:", request)
        return nil
    end
    return request
end

return http
