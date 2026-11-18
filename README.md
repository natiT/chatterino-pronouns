# Chatterino Pronouns

Chatterino Lua plugin that shows pronouns directly in chat, right before the username.

The built-in pronouns integration in Chatterino sucks (pronouns only show up in the user card) and they not willing to fix this, so I fixed it.

- Primary source: [pronouns.alejo.io](https://pronouns.alejo.io), fallback: [PronounDB](https://pronoundb.org) (batched, up to 50 IDs per request)
- Each user is looked up at most once per day; results are cached in `data/cache.json`

## Installation

Put this folder at:

- Linux: `~/.local/share/chatterino/Plugins/pronouns`
- Windows (untested): `%APPDATA%\Chatterino2\Plugins\pronouns`

Then enable it in Chatterino under Settings → Plugins and grant the permissions (Network, Filesystem).
Requires a Chatterino build with `CHATTERINO_PLUGINS` enabled.

Tested on CachyOS  with Chatterino7 2.5.6 (commit `910b01d`, AUR `chatterino2-7tv-git`).

## Credits

Script written with AI assistance.

Built for [Chatterino](https://github.com/Chatterino/chatterino2) and [Chatterino7](https://github.com/SevenTV/chatterino7).

Pronoun data from [alejo.io Pronouns](https://pronouns.alejo.io).
