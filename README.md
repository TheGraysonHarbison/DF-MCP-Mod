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

**Phase 3: Stocks and Pops.** Claude can see stock amounts and search for items and artifacts.

- 3.1 A setting that controls stock accuracy: read the true counts, or only what the fort appears to have through its
  bookkeeper (or the lack of one).
- 3.2 Settlement wealth and status.

**Phase 4: Logistics and World.** Claude can observe the map, zones, workshops, and work orders. Starts with reading and
making work orders.

- 4.1 Look at all workshops and select one, seeing its inventory and assigned work orders.
- 4.2 Read tiles at positions in the world: solid, empty, or what is on the ground.
- 4.3 Build workshops.
- 4.4 Look at all stockpiles, their settings and contents.
- 4.5 Paint stockpiles.

**Phase 5: Work order fix.** Orders made without a material showed in the game as "unknown material". Claude can now
say "any stone" or "any wood" in plain words, and every order reports the label the game shows.

**Phase 6: Striking the Earth.** Claude digs out a fortress.

- 6.0 See solid walls: the material at a position and whether a wall is natural, smoothed, engraved, or constructed.
  Plus a one-call scan for exposed walls, those bordering walkable floor, so hallway planning does not need a tile walk.
- 6.1 See digging, staircase, channel, ramp, smoothing, and engraving orders, and whether a dwarf has taken the job.
- 6.2 Designate mining, staircases, channels, ramps, and stair removal in a box across z-levels, never overwriting
  existing orders; erase orders in a box. Behind its own permission, off by default.
- 6.3 Designate smoothing and engraving.
- 6.4 Filled circles for digging, smoothing, and stockpiles from a centre and a radius in one call.

**Phase 7: Building.** Claude builds structures. Planned 2026-10-14, design in
[plan section 12](docs/ProjectPlan.md#12-phases-7-to-9-addendum-building-zoning-pause-planned-2026-10-14).

- 7.0 Pick materials: use the game's closest-material default, or name one in plain words ("granite", "any stone",
  "blocks", "granite blocks", "logs"). A read lists usable building materials with counts.
- 7.1 Constructions: walls, floors, ramps, stairs across levels, fortifications, bridges with a direction, roads, and
  supports. Walls between two points at any angle, filled or hollow boxes, filled or hollow circles.
- 7.2 Furniture and doors, each from an item made beforehand in a workshop; a missing item is refused with the work
  order that makes it. Doors need an adjacent wall.
- 7.3 Cancel blueprints, dismantle buildings, remove constructions, suspend and resume build jobs; a list of every
  building with its state.

**Phase 8: Zoning.**

- 8.0 See every zone: list by type, name, or active state; read one with its tiles, owner, assigned animals, squads,
  location, and settings.
- 8.1 Paint zones in boxes and circles (walls and water count), rename, activate, resize, configure, assign and
  unassign owners and animals, delete.

**Phase 9: Pause.**

- 9.0 See the pause state and pause or unpause the game, behind its own permission.

**Future plans** (after 9.0, not scheduled):

- Event queue, in-game chat window, and an autonomy timer so Claude is prompted by petitions, sieges, deaths, and on a
  schedule.
- Petitions, quickfort blueprints, military (squads, alerts, stations, barracks and archery assignment), labor
  assignment, locations (taverns, temples, libraries), traps and levers, tracks and minecarts.
- Push transport, a headless Python conductor, Steam Workshop packaging, legends and adventure mode.

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
| 2.1 | Noble positions: list and assign (`list_nobles`, `assign_noble`, `nobles_write` permission) | verified in-game 2026-10-12 |
| 2.2 | Console op refuses `claude-bridge perm/allow/deny` | verified in-game 2026-10-12 |
| 3 | Stock amounts, item and artifact search (`get_stock_bar`, `list_stocks`, `find_items`, `list_artifacts`) | verified in-game 2026-10-12 |
| 3.1 | Stock accuracy setting (true counts vs. bookkeeper view), settings grouped into General, Units, Items, Commands | verified in-game 2026-10-12 |
| 3.2 | Settlement wealth and status (`get_fort_status`) | verified in-game 2026-10-12 |
| 4 | Work orders: read, search job types, create, edit, delete (`list_work_orders`, `find_job_types`, `create_work_order`, `edit_work_order`, `delete_work_order`, `orders_write` permission) | verified in-game 2026-10-12 |
| 4.1 | Workshops: list, filter by type, inspect jobs and contents (`list_workshops`, `get_workshop`) | verified in-game 2026-10-12 |
| 4.2 | Map: bounds, wagon, tile read, text area map, free-space finder (`get_map_bounds`, `get_wagon`, `get_tile`, `get_area_map`, `find_build_space`) | verified in-game 2026-10-12 |
| 4.3 | Place workshop blueprints with footprint and material checks, and call for removal (`place_workshop`, `remove_building`, `build_write` permission) | verified in-game 2026-10-12 |
| 4.4 | Stockpiles: list by category, bounds, settings, links, contents (`list_stockpiles`, `get_stockpile`) | verified in-game 2026-10-12 |
| 4.5 | Paint a rectangular stockpile, configure categories and presets, rename, delete (`create_stockpile`, `configure_stockpile`, `rename_stockpile`, `delete_stockpile`, `list_stockpile_presets`, `stockpiles_write` permission) | verified in-game 2026-10-12 |
| 5.0 | Work order materials in plain words ("any stone", "any wood", "silver"), game label on every order, orders that would read "unknown material" refused | verified in-game 2026-10-13; design in [plan section 11.1](docs/ProjectPlan.md#11-phases-5-and-6-addendum-work-order-fix-and-striking-the-earth-planned-2026-10-13) |
| 6.0 | Wall material and kind on `get_tile`, material and designation views on `get_area_map`, exposed-wall scan (`find_exposed_walls`) | verified in-game 2026-10-13: soil, trees, layer stone (sandstone), mineral veins (kaolinite, bituminous coal, turquoise), and the exposed-wall scan; constructed walls still unchecked |
| 6.1 | List dig, stair, channel, ramp, smooth, and engrave designations with their assigned dwarf (`list_designations`, designation view on `get_area_map`) | verified in-game 2026-10-13: pending tiles, queued jobs, and the assigned miner's name all read back from a player-designated block |
| 6.2 | Preview, place, and erase digging orders in a box across z-levels (`plan_dig`, `designate_dig`, `erase_designations`, `dig_write` permission) | verified in-game 2026-10-13: a 6-level stair column and three chambers (102 orders) placed from a dry-run plan, overlaps skipped, all dug by the miner; erase cleared a test order with and without a kind filter |
| 6.3 | Designate smoothing and engraving (`designate_dig` kinds `smooth` and `engrave`) | verified in-game 2026-10-13: 147 smoothing orders over the dug chambers, all carried out; walls and floors read back as smoothed, a repeat refuses them; 147 engraving orders then placed and taken as jobs within a second |
| 6.4 | Filled circles for digging, smoothing, and stockpiles (`plan_dig` and `designate_dig` with `center_x`, `center_y`, `center_z`, `radius`; `create_stockpile` with `center_x`, `center_y`, `radius`) | verified in-game 2026-10-13: a radius-3 round room (37 orders) with a doorway corridor, and a radius-2 round stockpile (21 tiles, corners left as floor) |
| 9.0 | Pause and unpause (`set_paused`, `pause_write` permission; `get_time` reads `paused`) | verified in-game 2026-10-14: unpaused from the bridge, 202 frames ran in two seconds, paused again and the frame counter held; the op is refused until the player enables the toggle |
| 7.0 | Building materials in plain words for workshops and everything below; usable material list (`list_building_materials`) | planned 2026-10-14 |
| 7.1 | Constructions: walls, floors, ramps, stairs, fortifications, bridges, roads, supports in lines, boxes, and circles, filled or hollow (`plan_construction`, `place_construction`) | planned 2026-10-14 |
| 7.2 | Furniture, doors, hatches, grates, bars, windows from made items (`place_furniture`) | planned 2026-10-14 |
| 7.3 | List every building, cancel or dismantle any, remove constructions, suspend and resume (`list_buildings`, `remove_building`, `remove_constructions`, `suspend_building`) | planned 2026-10-14 |
| 8.0 | Zones: list and inspect (`list_zones`, `get_zone`, `zones` permission) | planned 2026-10-14 |
| 8.1 | Zones: paint, edit, assign, delete (`create_zone`, `edit_zone`, `assign_zone`, `unassign_zone`, `delete_zone`, `zones_write` permission) | planned 2026-10-14 |

## Known bugs

None open.

Fixed 2026-10-13: a work order created without a material showed in the game as "unknown material" (for example
"make unknown material rock blocks") because "any stone" was not expressible; `create_work_order` now takes plain
words and refuses orders the game would label that way.

Fixed: allowlisting `claude-bridge` used to let the console tool run `claude-bridge perm`, `allow`, and `deny`; the
console op now refuses those subcommands regardless of the allowlist (only `status`, `help`, `reload`, and `test`
pass).

## Running it

1. `tools/link-mod.sh <Dwarf Fortress folder>` once, then `enable claude-bridge` in the DFHack console.
2. Open Claude Code in this repository. The `.mcp.json` here starts the server with `uv run --project server df-mcp`.
3. Ask Claude to `ping`.
