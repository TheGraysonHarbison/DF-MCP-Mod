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

**Second Pass (unit analysis):**

1. Unit lists in three buckets, each with its own method, plus one for everything: Citizens (the fort's permanent
   population), Domesticated (pets, livestock, war and hunting animals) and Other (visitors, merchants, enemies,
   wildlife, undead). Every row carries the unit id, which is the key every other unit method takes, plus a finer
   `kind` label, gender, creature, and mood or owner.
2. A search method so Claude can go from a name, nickname, or description like "cat" to a unit id.
3. A basic-info method for one unit, matching the list row.
4. A unit sheet method that reads one category of the in-game profile, with its sub-category where the game has one:
   Overview, Relations, Groups, Military (squads, uniform, kills), Thoughts (recent, memories), Personality (traits,
   values, preferences, needs), Items, Health (status, wounds, treatment, history, description), Skills (labor, combat,
   social, other, knowledge), Rooms and Labor (work details, workshops, locations, work animals).
5. A method that returns the whole unit sheet in one JSON, with every list capped by a per-call limit.
6. A method to nickname a unit. This is the first action that changes the game and sits behind its own permission
   toggle, off by default.

**Phase 2 addendums:**

- 2.1 See the fort's noble and administrative positions with their holders, and appoint a citizen to one (behind its
  own permission, off by default).
- 2.2 The `claude-bridge` console allowlist entry can no longer be used to change the mod's own settings.

**MORE TO BE ADDED**

## Progress

Plan and rationale live in [docs/ProjectPlan.md](docs/ProjectPlan.md). Wire protocol in [docs/protocol.md](docs/protocol.md).

| Phase | Item | State |
|---|---|---|
| 0 | Repo scaffold, mod skeleton, Python RPC client, `ping` round trip | verified in-game 2026-10-12 (DFHack 53.16-r2, DF 53.16 Steam) |
| 1 | 1. Settings panel and permission allowlist | verified in-game 2026-10-12 (`claude-bridge settings`) |
| 1 | 2. Season, month, day, time, weather | verified in-game 2026-10-12 (`get_time`) |
| 1 | 3. Console access with allowlist | verified in-game 2026-10-12 (`run_console_command`) |
| 1 | 4. All units on the map | superseded by Phase 2 item 1 |
| 2 | 1. Unit lists by bucket and the unit id key (`list_units`, `list_citizens`, `list_domesticated`, `list_others`) | verified in-game 2026-10-12; design in [plan section 8](docs/ProjectPlan.md#8-phase-2-addendum-unit-analysis-planned-2026-10-12) |
| 2 | 2. Unit search (`find_unit`) | verified in-game 2026-10-12 |
| 2 | 3. Basic info for one unit (`get_unit`) | verified in-game 2026-10-12 |
| 2 | 4. Unit sheet by category and sub-category (`get_unit_sheet`) | all eleven tabs implemented, verified in-game 2026-10-12; appearance text still best-effort |
| 2 | 5. Whole unit sheet in one call (`get_unit_full_sheet`) | verified in-game 2026-10-12 |
| 2 | 6. Nickname a unit (`set_unit_nickname`, `units_write` permission) | verified in-game 2026-10-12 |
| 2.1 | Noble positions: list and assign (`list_nobles`, `assign_noble`, `nobles_write` permission) | implemented, awaiting in-game verification |
| 2.2 | Console op refuses `claude-bridge perm/allow/deny` | verified in-game 2026-10-12 |
| 3 | Event queue, in-game chat, autonomy timer | not started |
| 4 | Actions: petitions, quickfort, orders, military | not started |

## Known bugs

- Allowlisting the `claude-bridge` console command (handy for `claude-bridge reload` during development) also allows
  `claude-bridge perm ...`, `allow ...`, and `deny ...` through the console tool, so Claude could change its own
  permissions. Planned fix: the console op refuses the mod's own settings subcommands regardless of the allowlist.
  Until then, only allowlist `claude-bridge` while developing.

## Running it

1. `tools/link-mod.sh <Dwarf Fortress folder>` once, then `enable claude-bridge` in the DFHack console.
2. Open Claude Code in this repository. The `.mcp.json` here starts the server with `uv run --project server df-mcp`.
3. Ask Claude to `ping`.
