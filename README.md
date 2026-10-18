# DFHack Claude Integration Mod

A mod for DFHack, the Dwarf Fortress modding engine, plus an MCP server for Claude Code.

It acts as a bridge for Claude to interface with the game and play: analysing units, responding to events, striking the
earth, building, farming, trading, and running the militia, with the player able to limit what Claude may touch.

Claude is given the powers the player allows it in the mod's settings window. The player can also talk to Claude directly
in Claude Code, send it goals from a window inside the game, and read Claude's replies as in-game announcements.

Whenever an important event happens in-game (a siege, a death, a caravan, a strange mood, a petition) Claude is prompted
to respond, as long as the player enabled that kind of event.

A prompt timer can also prompt Claude after a number of in-game days, each month, or a number of real minutes, so it can
play on its own. The timer pauses when the game is paused.

## Requirements

- Dwarf Fortress 53.16 (Steam) with DFHack 53.16-r2 installed and working. Newer stable DFHack builds should work; older
  ones are untested.
- Python 3.11 or newer and [uv](https://docs.astral.sh/uv/). uv installs the server's dependencies from the lock file.
- [Claude Code](https://code.claude.com/) signed in with a claude.ai account. The mod's event push uses Claude Code
  channels, which are in research preview: a Team or Enterprise organization needs an Owner to turn on Channels under
  Organization settings > Claude Code; Pro and Max accounts without an organization skip that step. Bedrock, Vertex, and
  Foundry logins cannot receive pushed events (everything else works, and events can be polled instead).
- A terminal with bash for the one-time link script (Linux, macOS, Git Bash or WSL on Windows).

## Installation

The game is assumed to be installed already. Everything below happens in the folder you extract the release into; keep
that folder where it is afterwards, because step 3 writes its path into DFHack's configuration.

1. **Download the latest release.** Get `claude-bridge-<version>.zip` from the
   [Releases page](https://github.com/TheGraysonHarbison/DF-MCP-Mod/releases), extract it, and open a terminal in the
   extracted folder.

2. **Install the Python dependencies.**

   ```
   uv sync --project server
   ```

   This creates `server/.venv` with the pinned MCP library. Nothing is installed outside the folder.

3. **Install the Lua mod into DFHack.**

   ```
   tools/link-mod.sh <path to your Dwarf Fortress folder>
   ```

   The script adds the mod's scripts folder to `dfhack-config/script-paths.txt` inside your Dwarf Fortress install, so
   DFHack finds `claude-bridge` in every world without adding a mod at world generation. Run it once; running it again
   is harmless.

4. **Open a fortress and enable the mod.** Start Dwarf Fortress, load or create a fort, open the DFHack console, and run:

   ```
   enable claude-bridge
   claude-bridge status
   ```

   The status line shows the enabled state, the permissions, and the console allowlist. The mod re-enables itself when
   you load a save it was enabled in. It also appears in `gui/control-panel`.

5. **Open the settings and configure.** In the DFHack console:

   ```
   claude-bridge settings
   claude-bridge goals
   ```

   The settings window has four tabs: Permissions (what Claude may read and change; reads are on, writes are off until
   you turn them on), Console (the allowlist of DFHack commands Claude may run; empty means none), Events (which event
   kinds are pushed to Claude), and Timer (the prompt timer). The goals window holds your goals for the fort and the
   prompt they are sent with; Ctrl+S sends them to Claude. See [Settings](#settings).

6. **Start Claude Code and enable the MCP server, the skills, and the channel.** In the extracted folder:

   ```
   claude mcp add --transport stdio --scope project dfhack -- uv run --project server df-mcp
   claude plugin marketplace add ./df-skills
   claude plugin install claude-df@claude-df --scope project
   claude --dangerously-load-development-channels server:dfhack
   ```

   - The first command registers the `dfhack` MCP server for this folder (it writes a `.mcp.json` here). The server
     uses experimental Claude Code features, which is why it is added by hand rather than shipped pre-configured. Claude
     Code asks you to approve the project server when it starts; say yes.
   - The second and third commands install the `claude-df` plugin, the skills that teach Claude how to run a fort
     (see [Skills](#skills)). They write `.claude/settings.json` in this folder.
   - The last command starts Claude Code with the server loaded as a channel, so events, goals, and timer prompts reach
     Claude on their own. Channels are in research preview, so the flag is needed on every launch and shows a
     confirmation screen; confirm it with "I am using this for local development". Without the flag everything still
     works, but Claude has to poll for events (see [Playing](#playing)).

7. **Enjoy.** Ask Claude to `ping`. It confirms the bridge is up and a map is loaded, reads your goals and its plan, and
   starts playing within the permissions you gave it.

## Uninstalling

From the extracted folder, with Dwarf Fortress closed (or restart it afterwards so DFHack forgets the scripts):

```
tools/unlink-mod.sh <path to your Dwarf Fortress folder>
```

The script removes the mod from that Dwarf Fortress install: every line in `dfhack-config/script-paths.txt` that points
at this mod's scripts folder (this copy, another copy, or an older release you deleted) and the settings folder
`dfhack-config/mods/claude-bridge/` (permissions, console allowlist, event toggles, timer). Every other line of
`script-paths.txt` stays. It leaves your saves alone (each fort's `claude-df/` folder with `goals.md` and `plan.md` and
its enabled flag stay, and do nothing without the mod) and does not touch Claude Code: to remove those too, delete
`.mcp.json` and `.claude/` in the extracted folder, or the folder itself. Running it twice is harmless.

## Playing

Each session:

1. Load the fort. `claude-bridge status` in the DFHack console shows whether the mod is enabled.
2. In the extracted folder, start `claude --dangerously-load-development-channels server:dfhack` and confirm the dialog.
3. Ask Claude to `ping`. From then on, every batch of enabled events reaches Claude as a channel message, two quiet
   seconds or 50 events at a time; Claude handles them when it is idle and queues them while it is busy.

Claude reads your goals from `claude-bridge goals` (Ctrl+S sends them), keeps its own plan in the save, and answers in
the game with short light-red announcements on the left side, which you can click to zoom to the spot. Write to it in
Claude Code at any time.

The prompt timer (Timer tab, or `claude-bridge timer on|off|days N|month|minutes N`) prompts Claude on its own: every N
in-game days, at each change of month, or every N real minutes of unpaused play, with the prompt written on that tab. Any
event batch sent to Claude re-arms it, so a busy fort is driven by its events and a quiet one by the timer. Off by default.

Two things stay with you: pressing Trade on the depot's trade screen once Claude has selected the goods, and clicking
through the outpost liaison's meeting once Claude has set the import requests, or let Claude drive both with the
`screens_write` toggle. Claude tells you when either is ready.

Without the channel (no flag, or a login that cannot use channels) everything still works by hand: Claude can read
batches with `poll_events`, and `/loop` can drive a polling loop.

If events never arrive, Claude Code's log for the server is in `~/.cache/claude-cli-nodejs/<project>/mcp-logs-dfhack/`.
"channels not enabled by org policy" means the organization's Channels switch is off; "server did not declare
claude/channel capability" means the session was started without the flag.

## Settings

`claude-bridge settings` opens the settings window; the same toggles exist as console commands
(`claude-bridge perm <namespace> on|off`, `claude-bridge allow|deny <command>`, `claude-bridge event <kind> on|off`,
`claude-bridge timer ...`). Settings are stored in DFHack's mod state folder and apply to every world; the enabled flag
is per fort.

**Permissions** (reads on by default, writes off):

| Group | Read (on) | Write (off) |
|---|---|---|
| General | date, time, weather; these settings; send in-game events; read and write the plan file and read goals | pause and unpause the game |
| Units | units and their sheets; noble positions; squads | rename units; assign noble positions; create, edit, disband squads and give orders |
| Items | stocks and artifacts; true stock counts (turn off for the bookkeeper's view) | change kitchen cook and brew settings |
| Logistics | work orders; workshops, buildings, farms; caravans, depot, broker, diplomats; stockpiles | create, edit, delete work orders; place and remove buildings, constructions, furniture, farm crops; trade; paint and configure stockpiles |
| World | map, tiles, designations, plants; zones | dig, channel, smooth, engrave, chop, gather; paint and edit zones |
| Commands | | run allowlisted DFHack console commands; `lua` additionally needs its own toggle |

Sending messages to you needs no permission. **Console**: Claude may run only the commands you add to the allowlist, and
can never change the mod's own settings through it. **Events**: each kind has a toggle; mineral discovered, units
fighting, and petitions are on by default; the "Send in-game events" permission on the first tab must stay on for any to
be sent. **Timer**: enabled, mode, interval, and the prompt text.

## Skills

The `claude-df` plugin in `df-skills/` teaches Claude how to run a fort. The skills trigger on their own when the
situation matches, and each can be invoked by hand as `/claude-df:<name>`.

- **fortress-planner**: what Claude does at the start of every session (ping, permissions, time, goals, plan, fort
  status), how it takes stock of the whole fort, its planning rules (plan seasons ahead in phases and tasks, pause while
  planning, act within your permissions and tell you in-game after each batch of changes), the fixed template for the
  plan it keeps in the save, and what it does when your goals, the timer, or events arrive.
- **work-subdivision**: how Claude splits work for speed and token economy. The session model (Opus or better) manages,
  plans, and talks to you; a Sonnet agent (`df-steward`) handles judgment calls such as a trade or crop choice; a Haiku
  agent (`df-scout`) sorts lists, surveys the map, and places orders in bulk from exact instructions.
- **fortress-quirks**: what the game and the bridge have taught us: dwarves move diagonally so rooms need solid corners,
  crops are set after a plot is built, work orders need a manager, every bridge call pauses the game briefly, lists are
  capped unless asked otherwise, what each error code means and what Claude should do about it.

- **fortress-basics**: strategy an experienced player would follow: yearly food and drink targets, spare barrels and
  bins, cut gems as the trade good and never an artifact, wealth made rather than bought, engraved rooms, busy miners,
  no tree quota for the elves, and how Claude answers petitions on its own.

`df-skills/README.md` has the details and the commands to reinstall the plugin after editing a skill.

## Known bugs and open issues

No bugs open.

Open issues (features without a DFHack API, or where the game offers only mouse-driven UI):

- Petitions: reading and answering petitions through the bridge is not built. Petition events still arrive, and the
  player answers them in the game. The design is in the plan (13.1).
- Trade counter-offers: the Accept and Decline buttons of a merchant counter-offer are not measured yet, so
  `press_trade` refuses `accept_counter` and `decline_counter`; the player answers a counter-offer by hand until a live
  session measures them (`claude-bridge trade-snapshot` while hovering).
- Liaison land-holder offers: the bridge presses the candidate's name on the land-holder step, but no save has offered a
  barony yet, so that one step is unverified; the player can click it if it fails.
- Lever linking and pulling: the link job has no DFHack reference outside adventure-mode code.
- Multi-weapon weapon traps: DFHack's input table models one weapon per trap.
- Siege engine aiming: DFHack's siege-engine plugin is unavailable on 53.16-r2.
- Unit spawning for dev tests: `spawnunit` and `modtools/create-unit` are experimental on DFHack 53.16-r2 and stop with
  "Cannot read field world.arena_spawn". Revisit when DFHack validates the script for this build.

Fixed 2026-10-13: a work order created without a material showed in the game as "unknown material"; `create_work_order`
now takes plain words and refuses orders the game would label that way.

Fixed 2026-10-16: `ping` reported mod version 0.3.0; `MOD_VERSION` now follows `info.txt`.

Fixed: allowlisting `claude-bridge` used to let the console tool run `claude-bridge perm`, `allow`, and `deny`; the
console op now refuses those subcommands regardless of the allowlist (only `status`, `help`, `reload`, `test`, `send`,
`trade-snapshot`, and `dialog-snapshot` pass).

## Resources

Dwarf Fortress Wiki: https://dwarffortresswiki.org/index.php/Main_Page

Dwarf Fortress Modding Guide: https://dwarffortresswiki.org/Modding

DFHack Documentaion: https://docs.dfhack.org/en/stable/

DFHack Modding Guide: https://docs.dfhack.org/en/stable/docs/guides/modding-guide.html

Quickfort Command For DFHack: https://docs.dfhack.org/en/stable/docs/tools/quickfort.html

## Feature list

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

**Phase 12: Dev tools.** `dev_create_item` and `dev_exterminate` build the console lines for
`modtools/create-item` and `exterminate`; the console allowlist still decides. Unit spawning is an open issue.

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
trade through a mod-side API (17.0). See diplomats, the pending meeting, and the trade agreement; set next year's import requests while
the player holds the meeting (17.1).

**Phase 18: Mods.** The active Dwarf Fortress mods in load order with their source, and the loaded DFHack plugins
with their commands and on/off state, through `list_mods`.

**Phase 19: Skills.** A Claude Code plugin in `df-skills/` for release sessions, which have no `CLAUDE.md`: `fortress-planner`
(session start, taking stock, phased long-term plans in `plan.md` with a fixed template), `work-subdivision` (the session
model manages, a Sonnet steward judges, a Haiku scout surveys and places in bulk), and `fortress-quirks` (what the game and the
bridge have taught us, with a troubleshooting table). Installed with `claude plugin marketplace add ./df-skills` and
`claude plugin install claude-df@claude-df --scope project`; see `df-skills/README.md`.

**Phase 20: Final touches.** MIT license and a player-first README (Requirements, Installation, Playing, Settings, Skills), and (20.1) a release workflow that zips the player files.

**Phase 21: Release.** Alpha 1.0.0.

**Patch 1: Alpha 1.0.1.** Planned 2026-10-16, design in
[plan section 15](docs/ProjectPlan.md#15-patch-1-addendum-labor-migrants-screens-popups-hotkeys-planned-2026-10-16).
Three new permission toggles, all off by default: `labor_write`, `hotkeys_write`, and `screens_write` (anything that
drives a game screen).

- P1.0 Labor: see the work details (Miners, Woodcutters, Haulers and the rest) and put citizens on or off them, and set a
  detail's mode (everybody, nobody, only selected). Claude cannot create details or change which labors a detail holds.
- P1.1 Seeds: the fortress-quirks skill teaches sustainable farming: a seed reserve per crop, what returns seeds, the
  200-seed cap, buying seeds, a seed check at every season change.
- P1.2 Migrants: a `migrants_arrived` event for every migrant wave (and the no-migrants messages) that names the
  newcomers.
- P2.0 Trade screen: open the depot's trade screen, press Trade, Offer, or Seize and answer counter-offers through the
  game's own button handlers (a synthesized click through DFHack's input API, not the mouse), read the merchant's reply
  and mood, close the screen.
- P3.0 Diplomacy dialog: see when the liaison's dialog is available, open it, read its text and choices, step through it
  and finish it, with the requests step still set by `set_trade_requests`.
- P4.0 Popups: the pausing box popups (embark message, first caravan, megabeasts, sieges) arrive as events with their
  text and Claude closes them, unpausing if allowed.
- P5.0 Hotkeys: list the game's 16 zoom hotkeys and name, place, and clear them as points of interest.
- P6.0 Release: Alpha 1.0.1, released 2026-10-16.

**Future plans** (after Patch 2, not scheduled):

- Burrows and defend-burrow orders, per-month squad schedules, lever linking and pulling, multi-weapon traps, siege
  engine aiming.
- Quickfort blueprints, custom work details and workshop worker lists, locations (taverns, temples, libraries), tracks
  and minecarts, door and hatch toggles, the left-side alert buttons.
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
| 11.0 | Squads: list, create, rename, symbol, members, leader, disband (`list_squads`, `get_squad`, `create_squad`, `rename_squad`, `set_squad_symbol`, `add_to_squad`, `remove_from_squad`, `set_squad_leader`, `disband_squad`, `military` and `military_write` permissions) | verified in-game 2026-10-15: the seats, routines, and four vanilla presets read back; "Test Squad" was created on the militia commander seat with the metal armor preset in all ten slots, the commander set as leader, two dwarves added and one removed, the mason made leader (the game then titled him militia commander), symbol and colours written, and a half-made squad disbanded. The badge on screen does not redraw at once; forcing it crashed the game, hence rule 13 |
| 11.1 | Squad orders and routines (`order_squad`, `set_squad_routine`, `list_routes`, `create_route`) | verified in-game 2026-10-15: a station order moved both soldiers to the tiles beside the target within twenty seconds, a two-point patrol route was created and patrolled, a kill order on a barn owl was written and cancelled before any fight, a kill order on a citizen was refused, cancel cleared the orders, and the routine switched to Constant training and back with an unknown name refused |
| 11.2 | Squad equipment (`get_squad_equipment`, `set_squad_uniform`, `set_squad_ammo`) | verified in-game 2026-10-15 on a crossbow test squad: the read showed the leather crossbow preset, 100 bolts, and the leader's carried clothes and axe; a metal breastplate and a metal crossbow replaced their slots, a buckler was added beside the shield, unknown items and material classes were refused with the known names, and metal combat-only bolts replaced the ammunition |
| 12 | Dev tools (`dev_create_item`, `dev_exterminate`, via the console allowlist) | verified in-game 2026-10-15: five granite boulders created at a tile and read back; `exterminate list` reported the map's wildlife; a race the fort owns was refused without `include_friendly`. Unit spawning dropped: `modtools/create-unit` fails on 53.16-r2 (open issue) |
| 13 | Events batched and pushed through a Claude Code channel, per-kind toggles (`list_event_kinds`, `poll_events`, `events` permission, settings tabs, `claude-bridge send`) | verified in-game 2026-10-15 up to the org gate: hooks and pollers run, every mapped announcement type exists on 53.16-r2, synthetic events batched after the two-second quiet window and disabled kinds were refused, the server declared the channel capability and emitted the notification, and Claude Code accepted the capability once the server forced the classic handshake (the 2026-07-28 revision never registers a channel). Delivery into the session waits on the organization's Channels switch |
| 13.1 | Petitions: list and answer | not built; open issue (decided 2026-10-15), design kept in plan section 13 |
| 14.0 | Plan and goals files in the save, goals window with Send (`get_plan_info`, `read_plan`, `write_plan`, `append_plan`, `read_goals`, `plan` permission, `claude-bridge goals`) | verified in-game 2026-10-15: `claude-df/plan.md` and `goals.md` created inside the save on enable, plan written, appended (accents intact), read back, and a 70 KB write refused; goals window and Ctrl+S delivery checked by the player |
| 14.1 | No server buffer; the channel queue holds batches until Claude is idle | planned 2026-10-15, delivered with 13 |
| 14.2 | In-game messages from Claude (`send_message`, `list_message_badges`, no permission needed) | verified in-game 2026-10-15: four messages posted under the rumor, research, deity, and general badges showed in light red in the announcement log and the left-side alerts, the plan message carrying a zoom position; the player approved the look and the rumor default. The owner's icon lives in `mod/assets/` for a later overlay |
| 15 | Prompt timer (settings Timer tab, `claude-bridge timer`, `get_timer_status`) | verified in-game 2026-10-15: set to one real minute, the prompt arrived as a `timer` channel message after a minute of unpaused play and fired once; the settings window became four scrolling tabs (Permissions, Console, Events, Timer) with no per-row hotkeys after the player found cropping and a stale interval field |
| 16 | Traps, siege engines, trade depot (`place_furniture` types lever, pressure_plate, cage_trap, stone_fall_trap, weapon_trap, upright_spike, catapult, ballista, trade_depot; pressure plate trigger settings) | verified in-game 2026-10-15: dry runs named the missing mechanisms, spikes, and siege parts with the work orders that make them; two granite mechanisms were created with the dev tool and a lever and a units-only pressure plate were placed in the east loam room; the trade depot and siege engines dry-ran with their 5 by 5 and 3 by 3 footprints |
| 17.0 | Trade: caravans, depot, broker, bring goods, evaluate and select a deal (`list_caravans`, `get_trade_depot`, `get_broker`, `get_trade_screen`, `request_broker`, `bring_to_depot`, `cancel_bring`, `offer_trade`, `select_trade_goods`, `trade` and `trade_write` permissions) | verified in-game 2026-10-15 against two forced dwarven caravans: caravan, depot, and broker states read back; the broker request and the game's TradeAtDepot job; five boulders and ten figurines hauled to the depot; the weight model matched the game's "too heavy" refusal to the kilogram (1,095 over a 2,100 kg capacity); then ten figurines were selected for a black bronze flask on the player's open trade screen, the player pressed Trade, and the merchant accepted (mood 50 to 53, depot used once). Opening the screen and pressing Trade stay with the player for now |
| 17.1 | Diplomats: list, request options, set requests (`list_diplomats`, `get_trade_request_options`, `set_trade_requests`) | verified in-game 2026-10-15 on a liaison meeting between the outpost liaison and the expedition leader: the waiting diplomat, site leader, and open meeting read back; all 61 request categories listed with item names; steel bars and an iron anvil at priority 4 and all drinks at 2 were set on the open Requests step and showed selected in the game; after the player pressed Done the agreement read back with the game's prices (steel 205%, iron anvil 208%, drinks 142 to 150%, and sheets bought at 207%). Holding the meeting stays with the player |
| 18 | Active mods and plugins (`list_mods`) | verified in-game 2026-10-15: 26 mods in load order (25 vanilla plus the installed no_aquifers mod) with versions and sources; 78 loaded DFHack plugins with their commands, 35 of them switchable and 8 on (buildingplan, burrow, logistics, overlay, preserve-rooms, preserve-tombs, stonesense, RemoteFortressReader), matching DFHack's own `enable` listing |
| 19 | Skills plugin `claude-df` (`df-skills/`: `fortress-planner`, `work-subdivision`, `fortress-quirks`; agents `df-scout` on Haiku, `df-steward` on Sonnet) | built 2026-10-15: single-folder marketplace and project-scope install checked on the dev machine with DF off (`claude plugin details` lists three skills and two agents); play-through with the skills alone is the owner's Phase 21 check |
| 20 | MIT license, README reordered for players (Requirements, Installation, Playing, Settings, Skills, open issues, then the feature list and progress) | built 2026-10-15 |
| 20.1 | Release workflow (`.github/workflows/release.yml`): lint, test, zip `LICENSE`, `README.md`, `.gitignore`, `server/`, `mod/`, `tools/`, `df-skills/` without `CLAUDE.md`, `docs/`, `.mcp.json`, `.claude/`, or caches; artifact on every run, draft prerelease on a `v*` tag | built 2026-10-16 |
| 21 | Alpha 1.0.0 release (version bumps, tag `v1.0.0-alpha`, draft prerelease) | tagged 2026-10-16 (PR #58) |
| P1.0 | Work details: list, assign and remove citizens, set mode (`list_work_details`, `assign_work_detail`, `set_work_detail_mode`, `labor_write` permission) | verified in-game 2026-10-16: the 11 default details read back with modes and members; a metalcrafter was added to Woodcutters and CUTWOOD appeared in his labors, then removed; Haulers set to nobody cleared hauling on all seven citizens and everybody restored it; everybody on Miners and an unknown mode were refused |
| P1.1 | Sustainable farming section in the fortress-quirks skill | built 2026-10-16 |
| P1.2 | `migrants_arrived` event kind with the newcomers | verified in-game 2026-10-16: the kind lists all six announcement types on 53.16-r2; a MIGRANT_ARRIVAL announcement raised from Lua became a migrants_arrived event with the type, position, and newcomer fields and reached the channel; the newcomer names fill at the first real wave |
| P2.0 | Trade screen: open, press Trade, Offer, Seize, answer counter-offers, read the reply, close (`open_trade_screen`, `press_trade`, `screens_write` permission) | verified in-game 2026-10-16 on a dwarven caravan: the opener replayed the depot's Trade press (field diff recorded live) and the screen appeared; ten figurines were selected against eight merchant goods, the bridge's Trade click answered DFHack's confirm dialog itself and the merchant accepted (mood 50 to 52, goods swapped); Offer was greyed out by the game for a two-rope gift and the click correctly did nothing; close from the bridge matched Escape. Counter-offer buttons are unmeasured (open issue) |
| P3.0 | Diplomacy dialog: availability event, open, read text and choices, step, finish (`get_meeting_dialog`, `open_meeting_dialog`, `step_meeting_dialog`) | verified in-game 2026-10-16 on two liaison meetings: the opener replayed the player's recorded alert click and the dialog appeared; the bridge pressed the game's Okay and Done buttons by their on-screen labels, set a seed request on the requests step (priced 116% by the game), read the export agreement, and the farewell press closed the meeting with the agreement recorded; Escape part-way and a reopen resumed it. The land-holder step is untested (no barony offered) |
| P4.0 | Popups: `popup` event with the text, `list_popups`, `close_popup` with optional unpause | verified in-game 2026-10-16: three boxes raised through DFHack while the game was paused were caught by the frame poller, reached the channel, listed with their text, and closed from the bridge; close without unpause left the game paused, close with unpause resumed it; focus stays dwarfmode/Default under a box |
| P5.0 | Hotkeys: list the 16 slots, set and clear zoom hotkeys (`list_hotkeys`, `set_hotkey`, `clear_hotkey`, `hotkeys_write` permission) | verified in-game 2026-10-16: 16 slots read back with their keys (F1 to F8, Shift+F1 to Shift+F8) and F1 as the wagon; a point of interest written to F2 showed in the game's Hotkeys window and F2 jumped to it; F1 refused without overwrite, an off-map position refused, names clip at the game's 16 characters, clear emptied the slot |
| P6.0 | Alpha 1.0.1 release (version bumps to 1.0.1a1 and 1.0.1-alpha, protocol 30, tag `v1.0.1-alpha`) | released 2026-10-16 |
| P2-1.0 | Uninstall script (`tools/unlink-mod.sh`) | verified 2026-10-17 on the owner's DF install: removed the 1.0.1 release's script-path line and the settings folder and nothing else; a link and unlink round trip left the file otherwise unchanged |
| P2-2.0 | Workshop tasks without a manager: list what a shop can make, add, suspend, repeat, and cancel its jobs | built 2026-10-17, awaiting live test |
| P2-3.0 | Plan and goals survive autosaves and saves to a new folder (bug): stored in DFHack's per-fort site data, `claude-df/` files kept as a mirror, `get_plan_info` reports the storage (protocol 32) | verified in-game 2026-10-17: a plan and a goal written on the "Test" save carried over when the game moved the fort to "region2" mid-session (mirror files written into the new folder from site data), survived a quit and reload, and a 65,536-byte plan saved and reloaded intact with one more byte refused |
| P2-4.0 | Map area: missing tool descriptions, box caps, wagon-centred defaults (bug); the whole map is in reach, boxes clip at the map edge, `find_build_space` takes `whole_map`, `remove_constructions` and `place_furniture` report truncation (protocol 33) | verified in-game 2026-10-17 on a 48 by 48, 142-level map: whole-map area read in 0.03 s, a 61-level whole-map dig dry run in 2.2 s, whole-map designations over all 142 levels in 1.3 s, a radius-60 circle and overhanging boxes clipped with `clipped` and `requested`, off-map boxes refused, `find_build_space` at 40 by 3 and with `whole_map`, the game's 31-tile road and farm-plot limit kept, `remove_constructions` truncation flags; a 40-wide stockpile passed the size check (the game then refused shrubs) |
| P2-5.0 | `fortress-basics` skill from the owner's gameplay notes | built 2026-10-17; the stock categories it relies on (`barrel`, `bin`, `smallgem`, `rough`) checked against the game 2026-10-17 |
| P2-6.0 | Petitions: list and answer (replaces 13.1) | planned 2026-10-17 |
| P2-7.0 | Alpha 1.0.2 release | owner's, after P2-1.0 to P2-6.0 |
