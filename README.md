# DFHack Claude Integration Mod

This is a mod for DFHack, The Dwarf Fortress Modding Engine.

It acts as a bride for Claude to interface with the game and play. Answering petitions, anaylizing units, responding to events and striking the
earth.

Claude will basically be given all of the power the player has. The player can also chat with claude directly in game to have it act on their promts.

Whenever an important event happens in-game (Petition, Siege, Death, ETC) Claude will automatically be promted to respond.

There is also a setting toggle for claude to be promted after a certain amount of time so it can play autonomously. This can be configured after
a certain amount of ingame days, monthes, seasons or reallife seconds. This timer is to be paused when the game is paused.

## Resources:

Dwarf Fortress Wiki: https://dwarffortresswiki.org/index.php/Main_Page

Dwarf Fortress Modding Guide: https://dwarffortresswiki.org/Modding

DFHack Documentaion: https://docs.dfhack.org/en/stable/

DFHack Modding Guide: https://docs.dfhack.org/en/stable/docs/guides/modding-guide.html

Quickfort Command For DFHack: https://docs.dfhack.org/en/stable/docs/tools/quickfort.html

## Feature List:

**First Pass:**

1. Settings Panel To limit what Claude is allowed to access, handle connections, artifacts, system prompts and event hools.
2. Method for Claude to see the Season, Month, Day, Time and Weather. (Basically the time related information.)
3. Method for Claude to access the DFHack Console, execute commands and see its output.
4. Method for Claude to see all units on the map including Citizens, vistors, animals and enemies.

**MORE TO BE ADDED**

## Progress

Plan and rationale live in [docs/ProjectPlan.md](docs/ProjectPlan.md). Wire protocol in [docs/protocol.md](docs/protocol.md).

| Phase | Item | State |
|---|---|---|
| 0 | Repo scaffold, mod skeleton, Python RPC client, `ping` round trip | verified in-game 2026-10-12 (DFHack 53.16-r2, DF 53.16 Steam) |
| 1 | 1. Settings panel and permission allowlist | verified in-game 2026-10-12 (`claude-bridge settings`) |
| 1 | 2. Season, month, day, time, weather | verified in-game 2026-10-12 (`get_time`) |
| 1 | 3. Console access with allowlist | verified in-game 2026-10-12 (`run_console_command`) |
| 1 | 4. All units on the map | implemented (`list_units`, `get_unit`), awaiting in-game verification |
| 2 | Event queue, in-game chat, autonomy timer | not started |
| 3 | Actions: petitions, quickfort, orders, military | not started |

## Running it

1. `tools/link-mod.sh <Dwarf Fortress folder>` once, then `enable claude-bridge` in the DFHack console.
2. Open Claude Code in this repository. The `.mcp.json` here starts the server with `uv run --project server df-mcp`.
3. Ask Claude to `ping`.
