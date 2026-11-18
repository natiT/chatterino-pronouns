# Chatterino Pronouns

Chatterino Lua plugin that shows pronouns directly in chat, right before the username.

- Primary source: [pronouns.alejo.io](https://pronouns.alejo.io), fallback: [PronounDB](https://pronoundb.org) (batched, up to 50 IDs per request)
- Each user is looked up at most once per day; results are cached in `data/cache.json`

## Installation

Put this folder at `~/.local/share/chatterino/Plugins/pronouns`, then enable it in
Chatterino under Settings → Plugins and grant the permissions (Network, Filesystem).
Requires a Chatterino build with `CHATTERINO_PLUGINS` enabled.
