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

**Phase 7: Building.** Claude builds structures. Planned and delivered 2026-10-14, design in
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

**Phase 10: Kitchen, farms, chop and gather.** Planned 2026-10-15, design in
[plan section 13](docs/ProjectPlan.md#13-phases-10-to-18-addendum-farming-military-events-autonomy-trade-planned-2026-10-15).

- 10.0 See and change kitchen preferences: which ingredients in stock may be cooked and which brewed.
- 10.1 Farm plots: read a plot's soil (type, mud, above or below ground, cavern), place and remove plots, set the crop
  for each season and the fertilize flag. Plots go on soil floors or floors with mud. The crop list follows DFHack
  autofarm's rule, which approximates the game's.
- 10.2 Chop and gather orders in boxes and circles, and a list of trees and shrubs in a box.

**Phase 11: Military.** Squads: list, create (melee or crossbow by uniform, or a game preset), nickname, add and remove
members, set the leader, disband (11.0). Orders: station, kill, patrol a route, cancel, and training through the
squad's routine (11.1). Equipment: see uniforms, worn gear, and ammunition; set uniform slots by item type and material
class, and ammunition (11.2). Where DFHack has no API the mod ships its own.

**Phase 12: Dev tools.** `dev_spawn_unit`, `dev_create_item`, and `dev_exterminate` build the console lines for
`modtools/create-unit`, `modtools/create-item`, and `exterminate`; the console allowlist still decides.

**Phase 13: Events.** The mod collects announcements and polled changes (minerals, caverns, adamantine, artifacts,
strange moods, thefts, missing and dead citizens, ghosts, caravans, diplomats, monsters, invaders, seasons, fights,
petitions) into two-second batches of at most 50 and the server pushes each batch to Claude Code as a channel
notification, delivered when Claude is idle. Each kind has its own toggle; mineral discovered, units fighting, and
petition are on by default.

- 13.1 Read petitions and accept or reject them.

**Phase 14: Plans, goals, messages.** The mod keeps `claude-df/goals.md` and `claude-df/plan.md` in the save. Claude
reads and writes its plan; the player edits goals and the goal prompt in a `claude-bridge goals` window and sends them
with a button (14.0). No server-side buffer: Claude Code's channel queue is the buffer (14.1). `send_message` posts a
short message as an in-game announcement on the left side, in light red, with optional click-to-zoom (14.2).

**Phase 15: Prompt timer.** Every N in-game days, every month, or every N real minutes, a configurable prompt is sent
so Claude can play on its own. Resets whenever the mod sends Claude an event batch; pauses with the game.

**Phase 16: Traps and military buildings.** Levers, pressure plates with trigger settings, cage, stone-fall, and
weapon traps, upright spikes, catapults, ballistae, and the trade depot through `place_furniture`. Lever linking is an
open issue.

**Phase 17: Trade.** See caravans, the depot, and the broker; request the broker; bring goods to the depot; perform the
trade through a mod-side API (17.0). See diplomats and the trade agreement, set next year's requests, hold the
meeting (17.1).

**Phase 18: Mods.** The active Dwarf Fortress mods and loaded DFHack plugins.

**Future plans** (after 18, not scheduled):

- Burrows and defend-burrow orders, per-month squad schedules, lever linking and pulling, multi-weapon traps, siege
  engine aiming.
- Quickfort blueprints, labor assignment, locations (taverns, temples, libraries), tracks and minecarts, door and hatch
  toggles.
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
| 7.0 | Building materials in plain words for workshops and everything below (`place_workshop(material=...)`); usable material list (`list_building_materials`) | verified in-game 2026-10-14 on a fresh embark with only logs in stock: the list grouped 52 logs by tree; "any wood" placed a Masons shop with the wood class bit and the dwarves built it; "plum wood" placed one whose builder fetched a plum log; "granite blocks" was refused with zero available and nothing placed; a form word in a work order is refused |
| 7.1 | Constructions: walls, floors, ramps, stairs, fortifications, bridges, roads, supports in lines, boxes, and circles, filled or hollow (`plan_construction`, `place_construction`) | verified in-game 2026-10-14: dry runs of every kind and shape (a tree in a bridge footprint refused, roads cutting bad tiles, the shops skipped as buildings, "granite" refused with nothing placed); then an 8-tile plum wood wall line, a hollow 4 by 4 wall box, and a two-level stairwell placed and built by the dwarves within a minute, the line reading back as plum wood and the stairs as up stair below, down stair above |
| 7.2 | Furniture, doors, hatches, grates, bars, windows from made items (`plan_furniture`, `place_furniture`) | verified in-game 2026-10-14: dry runs refused a door on open grass, a bed outdoors, a well on a floor, and reported the missing table and hatch cover with the work order job that makes them; then a roofed 5 by 5 room was built from the bridge in rounds (walls and floor, then roof, door, and chair; a ramp for roof access), and the door and chair were installed from the fort's one door and one chair. `get_tile` now says whether a building is built |
| 7.3 | List every building, cancel or dismantle any, remove constructions, suspend and resume (`list_buildings`, `remove_building`, `remove_constructions`, `suspend_building`) | verified in-game 2026-10-14: the list showed the wagon, workshops, door, and chair with build stages and filtered by kind, subtype, planned state, and box; three floor blueprints were suspended, listed as suspended, resumed, one cancelled by id and two by box; a built ramp was designated for removal and a miner took it apart, returning the log |
| 8.0 | Zones: list and inspect (`list_zones`, `get_zone`, `zones` permission) | verified in-game 2026-10-14 against the player's gather zone and pasture: tiles, settings (gather toggles, pen occupants flag), filters by type alias, name, and active state; owner, animal, and squad fields are exercised by 8.1 |
| 8.1 | Zones: paint, edit, assign, delete (`create_zone`, `edit_zone`, `assign_zone`, `unassign_zone`, `delete_zone`, `zones_write` permission) | verified in-game 2026-10-14: the roofed room became an office zone with the chair listed inside it, the expedition leader and manager was assigned as owner and the office appeared on his rooms tab, a dog was refused as owner, and rename, grow by a tile, shrink, deactivate, reactivate, and a wrong-type setting all behaved; delete and animal assignment are covered by unit tests and the same code paths, not yet exercised live |

| 10.0 | Kitchen preferences: list and set (`list_kitchen`, `set_kitchen`, `kitchen_write` permission) | verified in-game 2026-10-15: 11 ingredients in stock listed across the four tabs with the game's default seed bans read back; cooking of the plump helmet plant was banned by key, read back as banned, and restored by plant name; a brew request on a seed changed nothing and warned |
| 10.1 | Farm plots: soil report, crops per season, place, remove, set crops (`list_farms`, `get_farm`, `set_farm_crops`, `place_furniture(type=farm_plot)`) | verified in-game 2026-10-15 on a new embark (surface z 122): dry runs cut walls, stone floors, and a workshop out of a plot and named the loam under surface grass; a 49-tile plot was placed in a dug loam room at z 121 and built by the planter; the soil report read underground loam outside a cavern with the yield note; the plantable list gave the six underground crops in their seasons with seed counts; crops and fertilize were set and read back, a wrong-season crop and an unknown id were refused. The game clears crops when construction finishes, so crop writes now wait for a built plot |
| 10.2 | Chop and gather designations, tree and shrub list (`list_plants`, `designate_dig` kinds `chop` and `gather`) | verified in-game 2026-10-15: 148 plants listed by kind and species over the map and in a circle; a pecan tree near the wagon was marked for felling and seven shrubs for gathering, `list_designations` showed them as chop and gather, a repeat refused them as already marked, and erase cleared the gather orders alone |
| 11.0 | Squads: list, create, rename, members, leader, disband (`list_squads`, `get_squad`, `create_squad`, `rename_squad`, `add_to_squad`, `remove_from_squad`, `set_squad_leader`, `disband_squad`, `military` and `military_write` permissions) | planned 2026-10-15 |
| 11.1 | Squad orders and routines (`order_squad`, `set_squad_routine`, `list_routes`, `create_route`) | planned 2026-10-15 |
| 11.2 | Squad equipment (`get_squad_equipment`, `set_squad_uniform`, `set_squad_ammo`) | planned 2026-10-15 |
| 12 | Dev tools (`dev_spawn_unit`, `dev_create_item`, `dev_exterminate`, via the console allowlist) | planned 2026-10-15 |
| 13 | Events batched and pushed through a Claude Code channel, per-kind toggles (`list_event_kinds`, `events` permission) | planned 2026-10-15 |
| 13.1 | Petitions: list and answer (`list_petitions`, `answer_petition`, `petitions_write` permission) | planned 2026-10-15 |
| 14.0 | Plan and goals files in the save, goals window with Send (`read_plan`, `write_plan`, `append_plan`, `read_goals`, `plan` permission) | planned 2026-10-15 |
| 14.1 | No server buffer; the channel queue holds batches until Claude is idle | planned 2026-10-15, delivered with 13 |
| 14.2 | In-game messages from Claude (`send_message`) | planned 2026-10-15 |
| 15 | Prompt timer (settings only) | planned 2026-10-15 |
| 16 | Traps, siege engines, trade depot (`place_furniture` new types) | planned 2026-10-15 |
| 17.0 | Trade: caravans, depot, broker, bring goods, offer (`list_caravans`, `get_trade_depot`, `get_broker`, `request_broker`, `bring_to_depot`, `cancel_bring`, `offer_trade`, `trade` and `trade_write` permissions) | planned 2026-10-15 |
| 17.1 | Diplomats: list, set requests, hold the meeting (`list_diplomats`, `set_trade_requests`, `hold_meeting`) | planned 2026-10-15 |
| 18 | Active mods and plugins (`list_mods`) | planned 2026-10-15 |

## Known bugs and open issues

No bugs open.

Open issues (features skipped on 2026-10-15 because DFHack has no API and the game offers only mouse-driven UI; see
plan section 13):

- Lever linking and pulling (Phase 16): the link job has no DFHack reference outside adventure-mode code.
- Multi-weapon weapon traps (Phase 16): DFHack's input table models one weapon per trap.
- Siege engine aiming: DFHack's siege-engine plugin is unavailable on 53.16-r2.
- The trade itself (17.0), the diplomat meeting (17.1), and answering petitions (13.1) are built as mod-side APIs;
  any of them that the game refuses to honour headlessly moves to this list with its reads kept.

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
4. For events, goals, and the prompt timer (Phases 13 to 15) the server must be loaded as a channel: an org Owner
   enables Channels under Organization settings > Claude Code, and the session is started with
   `claude --dangerously-load-development-channels server:dfhack` while custom channels are in research preview.
   `docs/playing.md` (Phase 13) walks through a play session.
