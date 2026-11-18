# Chatterino Pronouns

Chatterino-Lua-Plugin: zeigt Pronomen direkt im Chat vor dem Namen.

- Quelle 1: [pronouns.alejo.io](https://pronouns.alejo.io), Fallback: [PronounDB](https://pronoundb.org) (gebündelt, max. 50 IDs/Request)
- Jeder User wird max. 1x pro Tag abgefragt; Cache in `data/cache.json`

## Installation

Ordner nach `~/.local/share/chatterino/Plugins/pronouns` legen, in Chatterino unter
Einstellungen → Plugins aktivieren und Berechtigungen (Network, Filesystem) erlauben.
Benötigt einen Chatterino-Build mit `CHATTERINO_PLUGINS`.
