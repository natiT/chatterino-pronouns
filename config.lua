-- All tunables in one place.
-- Plugin version; keep in sync with info.json (the plugin cannot read it at runtime).
local VERSION = "1.2.1"

return {
    VERSION = VERSION,
    ALEJO_API = "https://api.pronouns.alejo.io/v1",
    PDB_API = "https://pronoundb.org/api/v2/lookup?platform=twitch&ids=",
    -- PronounDB asks for name + version.
    USER_AGENT = "chatterino-pronouns-plugin/" .. VERSION .. " (Chatterino Lua plugin)",

    -- latest GitHub release, its tag (v1.2.0) is compared against VERSION once per start
    UPDATE_INFO_URL = "https://api.github.com/repos/natiT/chatterino-pronouns/releases/latest",
    UPDATE_PAGE_URL = "https://github.com/natiT/chatterino-pronouns/releases/latest",
    UPDATE_CHECK_DELAY_MS = 10 * 1000, -- after startup, once channels are hooked

    CACHE_TTL_S = 24 * 3600,          -- per user (also for "no pronouns") and for the pronoun list
    ERROR_BACKOFF_S = 15 * 60,        -- after an error: retry user / list after this
    ALEJO_MAX_PARALLEL = 3,           -- concurrent alejo.io requests
    PDB_BATCH_SIZE = 50,              -- max IDs per PronounDB request
    HTTP_TIMEOUT_MS = 10000,

    SAVE_INTERVAL_MS = 60 * 1000,
    SCAN_INTERVAL_MS = 3000,          -- look for newly opened channels
    SCAN_START_DELAY_MS = 500,
    PDB_FLUSH_MS = 2000,              -- collect IDs, then query them in one batch
    DEFER_MS = 1,                     -- "next tick": leave the current signal handler first
    LIST_RETRY_MS = 15 * 60 * 1000 + 1000, -- just after the list backoff (ERROR_BACKOFF_S) ends

    CACHE_FILE = "cache.json",
    CACHE_VERSION = 3,                -- 2: "no pronouns" also checked via PronounDB; 3: readable keys
}
