-- Small helpers shared by all modules: logging, protected calls, timers, time.
local util = {}

function util.log(...) c2.log(c2.LogLevel.Info, "[pronouns]", ...) end
function util.warn(...) c2.log(c2.LogLevel.Warning, "[pronouns]", ...) end

function util.noop() end

-- Calls fn(...) protected; logs instead of propagating errors. Returns success.
function util.try(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then util.warn(err) end
    return ok
end

-- Returns a tick function that runs fn protected and always reschedules
-- itself, so a single error never kills the loop.
function util.every(interval_ms, fn)
    local function tick()
        util.try(fn)
        c2.later(tick, interval_ms)
    end
    return tick
end

-- Non-empty string. JSON null arrives as a truthy lightuserdata, so check the type.
function util.is_id(value)
    return type(value) == "string" and value ~= ""
end

---------------------------------------------------------------- Time
-- Chatterino does not load Lua's `os` library, so use c2.DateTime.
local function utc_now()
    return c2.DateTime.current_utc():to_unix_seconds()
end

-- Fallback for builds without to_unix_seconds (local wall time; shifts ±1 h on DST).
-- Howard Hinnant's algorithm: http://howardhinnant.github.io/date_algorithms.html#days_from_civil
local function days_from_civil(year, month, day)
    year = (month <= 2) and (year - 1) or year
    local era = (year >= 0 and year or year - 399) // 400
    local year_of_era = year - era * 400
    local month_from_march = (month + 9) % 12
    local day_of_year = (153 * month_from_march + 2) // 5 + day - 1
    local day_of_era = year_of_era * 365 + year_of_era // 4 - year_of_era // 100 + day_of_year
    return era * 146097 + day_of_era - 719468
end

local function local_now()
    local iso = c2.DateTime.current_local():to_iso_string_without_ms()
    local year, month, day, hour, minute, second = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    return days_from_civil(tonumber(year), tonumber(month), tonumber(day)) * 86400
        + tonumber(hour) * 3600 + tonumber(minute) * 60 + tonumber(second)
end

-- Seconds since epoch.
do
    local ok, sample = pcall(utc_now)
    util.now = (ok and type(sample) == "number") and utc_now or local_now
end

return util
