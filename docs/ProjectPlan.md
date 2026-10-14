# Project Plan: DFHack Claude Integration Mod

Status: Phases 0 through 9 merged and verified in-game against DFHack 53.16-r2; Phases 7 to 9 (building, zoning, pause) were planned, built, and verified on 2026-10-14 (PRs #28 to #35), design in section 12. Nothing is scheduled beyond them; see Future in section 3. Last updated 2026-10-14.

This document is the agreed plan for the project. The README describes the idea and current progress for readers; this file describes how we build it. When the two disagree, fix this file first, then the README.

---

## 1. Goal and constraints

Give Claude the same powers as the player in a Dwarf Fortress fortress-mode game, through DFHack, with the player able to limit those powers, chat with Claude in-game, and let Claude act autonomously on a timer.

Constraints that shaped every decision below:

- Claude access comes through Claude Code on a Team seat. No API keys anywhere in this project.
- MCP servers cannot start a Claude turn. Something must ask Claude to act; see section 3.
- Nothing in this repo may touch player save data or `dfhack-config` beyond the mod's own state file.
- Target DFHack 53.16-r2 (stable, released 2026-09-29) or newer. Documentation references use the `stable` docs path, not a pinned old version.

---

## 2. Architecture

```
 Claude Code (Team seat)
     |  MCP over stdio (.mcp.json in this repo)
     v
 server/  Python MCP server  (mcp 2.x, MCPServer class, Python 3.11)
     |  DFHack remote RPC: protobuf over TCP, localhost:5000
     |    RunLua -> rpc.claude_bridge.dispatch(json) -> json
     |    (console commands run inside the dispatcher after the allowlist check)
     v
 mod/     DFHack Lua mod "claude-bridge"
     |  eventful hooks, repeat-util pollers, overlay settings panel
     v
 Dwarf Fortress
```

Three processes: Dwarf Fortress with DFHack, the Python MCP server, and Claude Code. The server is stateless apart from its socket connection; all game-facing state lives in Lua.

### 2.1 Transport decision

Chosen: DFHack's built-in remote server plus `RunLua`.

Why:

- Already running in every DFHack install, localhost-only by default, no plugin to enable.
- `RunLua` suspends the DF core for the duration of the call, so Lua reads game state safely without us managing suspension.
- Console commands run through `dfhack.run_command_silent` inside the dispatcher, so the allowlist check and the execution are one code path. `RunCommand` stays available in the client for dev tooling only.
- The Python side is a small protobuf framing client (handshake, `BindMethod`, request, reply, quit) with a hand-rolled codec for the five messages we use (see `docs/decisions/0002-protobuf-codec.md`). No maintained Python client exists and the dev machine has no `protoc`.

Rejected for now: the `luasocket` plugin with our own newline-delimited JSON port. It gives true push, but the plugin is tagged dev and we would own buffering, reconnects, and partial reads. The Lua dispatch layer is written transport-agnostic so this can be added later if poll latency becomes a problem.

### 2.2 RPC envelope

`RunLua` passes string arguments and returns a list of strings. We use exactly one argument and one return value, both JSON.

Request:
```json
{"op": "units.list", "args": {"filter": "citizens"}, "id": "optional-correlation-id"}
```

Response:
```json
{"ok": true, "result": {...}}
{"ok": false, "error": {"code": "NOT_ALLOWED", "message": "..."}}
```

Rules:

- `op` is `namespace.verb`. Namespaces map one to one onto Lua modules in `internal/claude-bridge/`.
- Every op is registered in a single table in `rpc.lua`; the dispatcher checks the permission allowlist before calling the handler.
- Error codes are a closed set documented in `docs/protocol.md`: `BAD_REQUEST`, `NOT_ALLOWED`, `NO_WORLD`, `NO_MAP`, `NOT_FOUND`, `INTERNAL`.
- Payloads are plain data: numbers, strings, booleans, arrays, objects. Never raw DF structs or pointers. Unit references use the DF unit id.
- Any change to an op's shape updates `docs/protocol.md`, the Lua handler, the Python tool, and a protocol version constant in the same commit.

The module name must satisfy DFHack's `RunLua` filter (`rpc.*`). Mod scripts are loaded with `reqscript`, not `require`, so the control script publishes the dispatcher by assigning it into `package.loaded["rpc.claude_bridge"]` on enable. Implemented in the scaffold PR; still to be verified against a running game. The fallback is `RunCommand` with a `claude-bridge rpc <json>` subcommand. See `docs/decisions/0001-transport.md`.

### 2.3 Events

DFHack has no petition event, and `eventful` covers only some of what we need. Lua keeps a bounded event queue (default 200 entries, oldest dropped) fed by:

- `eventful` hooks: `onUnitDeath`, `onInvasion`, `onReport` (filtered to announcement types we care about), `onJobCompleted` for artifact creation.
- `repeat-util` pollers at a low frequency (default every 100 ticks): pending petitions, new visitors, siege flag, weather change, season change.
- The in-game chat window, which appends `chat.message` events.
- The autonomy timer, which appends `timer.fired` events.

Each event: `{"seq": n, "kind": "petition.new", "tick": ..., "data": {...}}`. The server drains with `events.poll(after_seq)`. Nothing is removed on poll; the queue is a ring, so a client that falls behind loses old events rather than blocking the game.

### 2.4 Driver loop

Chosen: a Claude Code session with a blocking `wait_for_event` tool.

The MCP server exposes `wait_for_event(timeout_seconds)`, which polls `events.poll` on a short interval until an event arrives or the timeout passes. Claude runs a loop: wait, act, wait. The in-game chat and the autonomy timer are just event kinds, so one loop handles all three README features (event response, chat, autonomy).

Why: no second runtime, uses the Team seat, and the whole system is observable from one terminal. A Python conductor using the Agent SDK remains a future candidate if running without a terminal matters.

### 2.5 Permissions

The settings panel (a DFHack overlay window) owns a permission table stored under `scriptmanager.getModStatePath("claude-bridge")`:

- Per-namespace toggles: `time`, `units`, `units_write`, `console`, `events`, `petitions`, `build`, `orders`, `military`.
- Console allowlist: explicit command names allowed via `console.run`, with a deny-all default. Wildcard only by explicit player choice.
- Autonomy timer: off, or one of in-game days, months, seasons, or real seconds, with the interval. Paused when DF is paused.
- Event hooks: per-kind enable.

Enforcement happens in Lua at dispatch, not in Python. The Python server mirrors the table for tool descriptions only, so a misbehaving server cannot bypass it.

---

## 3. Features and phases

Each phase ends with a demo and a README progress update.

### Phase 0: Skeleton and round trip

- Repo layout from section 4, `CLAUDE.md`, `.gitignore`, `.mcp.json`, licenses.
- `mod/` with `info.txt`, control script with enable/disable, `rpc.lua` dispatcher, `ping` op.
- `server/` with the DFHack RPC client, `MCPServer` with a `ping` tool, stderr-only logging.
- `tools/link-mod.sh` to add the mod to `script-paths.txt` for development.
- Verify the `package.loaded` trick for `RunLua`. Record the result as `docs/decisions/0001-transport.md`.
- Done when: `claude` in this repo can call `ping` and get the DF version and current tick back.

### Phase 1: Observe plus gated console (README first pass)

| README item | Op(s) | Tool | Notes |
|---|---|---|---|
| 1. Settings panel | `settings.get` | `get_permissions` | Overlay window, state file, permission enforcement in dispatch |
| 2. Time and weather | `time.now` | `get_time` | year, season, month, day, tick, paused, weather at map centre, elapsed real seconds since save |
| 3. Console | `console.run` | `run_console_command` | `dfhack.run_command_silent` inside the dispatcher after the allowlist check; `lua` also needs the `lua_eval` permission |
| 4. Units | `units.list`, `units.get` | `list_units`, `get_unit` | Categories: citizens, residents, visitors, merchants, diplomats, animals, wildlife, invaders, undead. Summary rows plus a detail op with health, mood, labors, skills, relationships |

Also in Phase 1: `docs/protocol.md` for every op above, and a `tools/smoke-test.py` that exercises each op against a running game.

### Phase 2: Unit analysis

Let Claude see every unit on the map in three buckets (citizen, domesticated, other), select one reliably by id, read its unit sheet by category and sub-category or all at once, and give it a nickname. Full design in section 8. Ops: `units.list`, `units.find`, `units.get`, `units.sheet`, `units.full_sheet`, `units.set_nickname`. The nickname op is the first write and lives behind its own `units_write` permission, off by default.

Roadmap revised 2026-10-12 so each phase covers one distinct area. Phases 3 and 4 are observe-then-act within their area; everything that used to be Phases 3 to 5 (events, chat, autonomy, petitions, quickfort, military, transport and packaging candidates) is unscheduled and listed under "Future" below.

### Phase 3: Stocks and Pops

Namespace `stocks` (read, default on). Each item is its own PR with a design pass first, as in section 8.

- 3.0 Stock amounts by category, and search for items and artifacts by name, type, or material. Candidates: `stocks.summary`, `stocks.find`, `stocks.artifacts`.
- 3.1 Stock accuracy setting in the settings panel: `true` reads the real counts from the item vectors; `bookkeeper` reports what the fort's Stocks screen would show given the bookkeeper's precision level, or nothing without one. Default to be decided in the design pass.
- 3.2 Settlement wealth and status: created, imported, exported, and architectural wealth, fort title and population tier, and whatever else the Status screen shows.

### Phase 4: Logistics and World

Reads stay under one namespace (`world` or `logistics`, decided in the design pass); every write gets its own `_write` namespace, off by default, following `units_write` and `nobles_write`.

- 4.0 Work orders: read the manager's orders and create new ones.
- 4.1 Workshops: list them, select one by id, read its inventory and assigned orders.
- 4.2 Tiles: read what is at a map position, whether it is solid, empty, or what lies on the ground.
- 4.3 Build workshops.
- 4.4 Stockpiles: list them with settings and contents.
- 4.5 Paint stockpiles.

### Phase 5: Work order fix

- 5.0 Orders created without a material show in the game as "unknown material". Verified live on 2026-10-13: the game has no stone material category, so "any stone" is the generic inorganic material, and an order with no material at all gets that label. Fix: plain-word materials, the game's own label on every order row, and a refusal when the label would say "unknown material". Design in section 11.1.

### Phase 6: Striking the Earth

Reads stay under `map`. Every write in this phase goes under one new namespace, `dig_write`, off by default.

- 6.0 See solid walls: the material at a position (granite, clay, a vein, a construction), and whether a wall is natural, smoothed, engraved, or constructed. Plus a scan for exposed walls, those bordering walkable floor, so hallway planning takes one call instead of a tile walk.
- 6.1 See digging, staircase, channel, ramp, smoothing, and engraving designations, and whether a dwarf has taken the job.
- 6.2 Designate mining, staircases, channels, ramps, and stair removal in a box across z-levels, never overwriting an existing designation; erase designations in a box.
- 6.3 Designate smoothing and engraving.
- 6.4 Filled circles for mining, channels, ramps, smoothing, engraving, and stockpiles, from a centre and a radius in one call. Not for staircases.

Design for all of Phase 6 in section 11.2 to 11.6.

### Phase 7: Building

Reads stay under `workshops` (relabelled "Read workshops and buildings") and `stocks`; every write stays under the one `build_write` namespace, relabelled "Place and remove buildings and constructions". Design in section 12.

- 7.0 Materials: Claude either takes the closest material (the game's default filter) or names one in plain words, as work orders do since Phase 5: a material ("granite", "any stone", "wood"), a form ("blocks", "logs", "bars"), or both ("granite blocks"). A read lists usable building materials with counts by material and form. `build.workshop` takes the same words.
- 7.1 Constructions: walls, floors, ramps, stairs across levels, fortifications, bridges with their direction, paved and dirt roads, and supports. Walls go between two points at any angle, in filled or hollow boxes, and in filled or hollow circles, the way dig orders do. Tracks, track stops, and rollers are deferred.
- 7.2 Furniture and doors: beds, tables, chairs, cabinets, chests, and the rest of the furniture tab, plus doors, floodgates, hatches, grates, bars, and windows, each consuming an item made beforehand in a workshop. Doors follow the game's rule (one adjacent wall) and warn when not between two opposite walls.
- 7.3 Cancel and dismantle: cancel any blueprint, dismantle any built building, remove finished constructions in a box or circle, suspend and resume build jobs. A general building list read gives Claude the targets.

### Phase 8: Zoning

Namespace `zones` (read, on) and `zones_write` (off), both in the World group. Design in section 12.

- 8.0 See every zone: list by type, name, or active state, and read one zone with its tiles, owner, assigned units, squads, location, and per-type settings.
- 8.1 Paint zones in boxes and circles over floors, walls, and water; rename, activate, resize, and configure them; assign and unassign owners and animals; delete them. Locations (taverns, temples, libraries, guildhalls, hospitals) are read in 8.0 and created in a later 8.2; squad assignment waits for the military phase.

### Phase 9: Pause

- 9.0 See the pause state (already in `time.now`) and set it, behind a new `pause_write` toggle, off by default. Delivered first because every live test benefits.

### Future (after 9.0, not scheduled)

- Event queue (2.3) with `events.poll` and `wait_for_event`; chat overlay with `chat.message` and `chat.say`; autonomy timer; event-kind filters; a documented play loop in `docs/playing.md`. The driver loop design in 2.4 stays as written.
- Petitions, quickfort blueprints through the quickfort command, military (squads, alerts, stations, barracks and archery range assignment), labor assignment, locations (8.2), traps and levers, tracks and minecarts, door and hatch toggles.
- Luasocket push transport, a headless Python conductor using the Agent SDK, Steam Workshop packaging, legends and adventure mode.

---

## 4. Repository structure

```
DF-MCP-Mod/
  README.md                 idea and progress, for readers
  CLAUDE.md                 rules for Claude Code in this repo
  LICENSE                   to be chosen before first public push
  .gitignore
  .mcp.json                 stdio entry: uv run --project server df-mcp
  docs/
    ProjectPlan.md          this file
    protocol.md             every RPC op, request and response shapes, error codes
    playing.md              how to run a play session (future)
    decisions/              short ADRs, numbered, one decision each
  mod/                      the DFHack mod, installable as-is
    info.txt                ID claude-bridge, versions, author, description
    README.md               player-facing install and settings guide
    scripts_modinstalled/
      claude-bridge.lua     control script: enable/disable, hooks, overlay registration
      internal/claude-bridge/
        rpc.lua             op table, dispatcher, permission check, JSON envelope
        state.lua           settings load/save, persistent site data
        time.lua            time and weather ops
        units.lua           unit listing and detail ops
        console.lua         console allowlist and execution
        events.lua          event queue, eventful hooks, pollers
        timer.lua           autonomy timer
        ui/settings.lua     settings overlay window
        ui/chat.lua         chat overlay window (future)
  server/                   the Python MCP server
    pyproject.toml          uv project, package df_mcp, entry point df-mcp
    src/df_mcp/
      __init__.py
      wire.py               hand-rolled protobuf codec for the CoreProtocol messages we use
      dfhack_rpc.py         framing client for the DFHack remote server
      bridge.py             call(op, args) -> result, error mapping, reconnect
      server.py             MCPServer construction and transport
      tools/                one module per namespace, registers tools
    tests/
      test_wire.py          codec round trips
      test_dfhack_rpc.py    framing tests against a scripted fake socket
      test_bridge.py        envelope and error mapping with a fake client
      test_server.py        tool registration and annotations
  tools/
    link-mod.sh             adds mod/scripts_modinstalled to DFHack script-paths.txt
    smoke-test.py           exercises every op against a running game
```

Naming: mod ID and namespace `claude-bridge`, Lua RPC module `rpc.claude_bridge`, Python package `df_mcp`, MCP server name `dfhack`.

---

## 5. How changes are committed

Workflow: feature branches and pull requests.

- Default branch is `main`. The current local branch `master` is renamed to `main` before the initial commit.
- The initial commit goes directly on `main` and contains only planning and scaffolding: this file, `CLAUDE.md`, `.gitignore`, README.
- Everything after that is a branch named `<scope>/<short-topic>`, for example `mod/units-list` or `server/rpc-client`, merged via a GitHub PR with `gh`. Squash or merge is the reviewer's call; keep the PR title in conventional commit form so squash history stays clean.
- One PR per op or per feature. A protocol change ships Lua, Python, and `docs/protocol.md` together, never split across PRs.

Commit messages use Conventional Commits:

```
<type>(<scope>): <imperative summary under 70 chars>

<why, not what, when the diff does not make it obvious>

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
```

- Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `build`.
- Scopes: `mod`, `server`, `docs`, `tools`, `repo`.
- The commit that completes a phase item also updates the README progress section.
- No commits of DF saves, `dfhack-config` contents, logs, or anything under `data/`.
- Versions: `mod/info.txt` `NUMERIC_VERSION` bumps on every protocol version bump; `server/pyproject.toml` follows semver and must declare which protocol version it speaks.

PR description ends with the generated-with line required by the workspace.

---

## 6. CLAUDE.md rules

These are the rules the repo's `CLAUDE.md` carries. Kept here so the rationale survives.

1. Read `docs/ProjectPlan.md` before structural work and `docs/protocol.md` before touching any op. Reason: both sides of the bridge must agree.
2. A protocol change edits the Lua handler, the Python tool, `docs/protocol.md`, and the protocol version in one branch. Reason: a split change breaks the bridge on whichever side lands first.
3. Permission checks live in Lua at dispatch. Never add a Python-side shortcut that calls DFHack without going through `rpc.claude_bridge.dispatch`. The raw `RunCommand` method on the client is for dev tooling (`tools/smoke-test.py`) only. Reason: the player's settings panel is the only trust boundary.
4. No tool that evaluates arbitrary Lua ships unless it is behind its own permission and off by default. Reason: that is full code execution in the player's game.
5. Lua follows DFHack script conventions: `--@ module = true` header on every module, module-level functions are the exports and everything else is `local`, internal modules load with `reqscript('internal/claude-bridge/<name>')`, 4-space indent, snake_case, the control script returns early on `dfhack_flags.module`. Use `dfhack.*` helpers over raw `df.global` walks when one exists, and wrap uncertain struct access in `pcall` so one missing field cannot take down an op.
6. Python uses uv, ruff, pytest, type hints, Python 3.11. The MCP server logs to stderr only. Reason: stdout is the MCP transport.
7. DFHack docs are cited by the `stable` URL and the version they were checked against. Do not rely on memory for `df.*` struct fields; look them up or check in-game with `:lua`.
8. Never read, write, or commit DF save folders or `dfhack-config` beyond the mod's own state file. Never put ports, paths, or credentials in committed files; `.mcp.json` uses relative paths only.
9. Branch per change, conventional commit messages, PR via `gh`. Do not commit to `main`. Every branch starts from `main`; stacking on another branch needs the owner's explicit permission. Once the owner has approved a branch's functions, Claude may merge its PR, but only after asking and getting a yes for that specific merge (agreed 2026-10-13). Reason: stacked branches make PR diffs and merge order depend on each other; the merge question keeps the owner in control of what lands on `main`.
10. When a feature lands, update the README progress section in the same PR. The README is for readers; this file is for builders.
11. Confirm before anything that affects a running game beyond reads: pausing, running console commands, or changing settings during a test session.
12. Any list that can grow large is capped at 25 entries by default, with a per-call `limit` to raise it and a `truncated` marker in the response. Reason: one call pauses the game and lands in Claude's context; an uncapped inventory or memory list can be thousands of rows.

---

## 7. Open items

- License choice before the first public push.
- The `package.loaded` route for `RunLua` is confirmed working in-game (2026-10-12).
- `gh` installed and authenticated on the dev machine on 2026-10-13; PRs and approved merges go through it.
- Decide whether `.mcp.json` is committed or templated as `.mcp.json.example` once the uv entry point exists.
- The section 8.6 struct check was done by iteration against the live game on 2026-10-12 instead of `:lua`; findings are in `docs/protocol.md` under `units.sheet`. Still unverified because the test fort had none: squad uniforms and orders, kills, wounds and treatment, memories, occupations, workshop assignments, work animals.

---

## 8. Phase 2 addendum: unit analysis (planned 2026-10-12)

Phase 1 shipped `units.list` and `units.get` with eleven categories and a flat detail row. Phase 2 replaces that surface with one that matches how the player thinks: three buckets, a stable key, and the in-game unit sheet read by tab. Decisions below were agreed on 2026-10-12.

### 8.1 Decisions

| Question | Decision |
|---|---|
| Phase numbering | Unit analysis is Phase 2. Events, chat, and autonomy move to Phase 3; actions to Phase 4; candidates to Phase 5. |
| Row keys | `id`, `name`, `unit`, `kind`, `gender`, `creature`, then `mood` or `owner`. Values are readable words, never DF enum codes. |
| Buckets vs. categories | `unit` is one of `citizen`, `domesticated`, `other`. `kind` keeps the finer Phase 1 label so a goblin invader and a human guest are still distinguishable. |
| Nickname gating | New namespace `units_write`, default off, its own toggle in the settings panel. Reads stay under `units`. |
| Sheet categories | All eleven in-game tabs with their sub-tabs. Tabs that DFHack cannot reconstruct fully are returned best-effort and marked in the response. |
| Payload size | Every list-valued section is capped. The cap is a per-call `limit` argument, default 50. A capped section carries `truncated: true` and `total`. |

### 8.2 Selecting a unit

The key is the DF unit id (`df.unit.id`, `global_id` in DF). It is unique within a save, stable for the life of the unit, and `df.unit.find(id)` resolves it without a scan. Every row and every detail response carries `id`, and every per-unit op takes `id`. Names are not keys: they are not unique, many animals have none, and nicknames change.

Two conveniences on top of the id:

- `units.find` takes a case-insensitive substring and matches it against the native name, the English translation, the nickname, and the readable name (which includes race and profession, so "cat" or "mason" work). It returns the same rows as `units.list`, so Claude can go from "the dwarf called Urist" to an id in one call.
- `hist_figure_id` is included in `units.get` for citizens and named visitors. It survives the unit leaving and returning to the map, which the unit id does not. It is `-1` for most animals, so it is a secondary field, not the key.

### 8.3 Buckets and rows

Bucket tests, in this order, all `dfhack.units.*` helpers from the stable Lua API (checked 2026-10-12):

| Bucket | Test | `kind` values |
|---|---|---|
| `citizen` | `isCitizen(u, true)` or `isResident(u, true)` | `citizen`, `resident` |
| `domesticated` | `isAnimal(u)` and (`isTame(u)` or `isDomesticated(u)` or `isOwnCiv(u)` or `isPet(u)`) | `pet`, `livestock`, `war_animal`, `hunting_animal`, `stray` |
| `other` | everything else | `visitor`, `merchant`, `diplomat`, `invader`, `undead`, `wildlife`, `agitated`, `hostile`, `other` |

`kind` for domesticated animals: `pet` when `isPet(u)`, `war_animal` when `isWar(u)`, `hunting_animal` when `isHunter(u)`, otherwise `livestock` if the caste is a grazer, egg layer, or milkable, else `stray`. Dead units are excluded unless `include_dead` is true. Insane citizens are included because the player sees them in the citizen list.

Row shapes:

```json
{"id": 1234, "name": "Urist McMason", "unit": "citizen", "kind": "citizen", "gender": "female", "creature": "dwarf", "mood": "content"}
{"id": 1301, "name": "Stray Cat (Tame)", "unit": "domesticated", "kind": "stray", "gender": "male", "creature": "cat", "owner": "None"}
{"id": 1402, "name": "Shelldon", "unit": "other", "kind": "invader", "gender": "male", "creature": "goblin", "mood": "content"}
```

- `name` is `dfhack.units.getReadableName(u)`. For nameless animals this yields the same text the game shows, such as "Stray Cat (Tame)"; verify the exact capitalisation in-game (8.6).
- `gender` maps `unit.sex` (`pronoun_type`) to `female`, `male`, or `none`.
- `creature` is `dfhack.units.getRaceReadableName(u)`.
- `mood` is `dfhack.units.getStressCategory(u)` mapped through the same seven names DFHack's unit viewer uses: `miserable`, `unhappy`, `displeased`, `content`, `pleased`, `happy`, `ecstatic`. Units without a soul get `"none"`.
- `owner` is the readable name of `unit.relationship_ids.PetOwner`, or `"None"`.

### 8.4 Ops

All ops need a map. Namespace is `units` unless stated.

| Op | Args | Result |
|---|---|---|
| `units.list` | `bucket` (`citizen`, `domesticated`, `other`, or null for all), `kind` (optional finer filter), `include_dead` (false), `limit` (200), `offset` (0) | `total`, `count`, `offset`, `units` (rows), `counts_by_bucket`, `counts_by_kind` |
| `units.find` | `query` (string), `bucket` (optional), `limit` (20) | `units` (rows), `total` |
| `units.get` | `id` | The row plus `nickname`, `caste`, `profession`, `age`, `pos`, `job`, `hist_figure_id`, `civ_id`, `squad`, `flags` |
| `units.sheet` | `id`, `category`, `subcategory` (optional), `limit` (50) | `id`, `name`, `category`, `subcategory`, `data`, `truncated` (bool), `total` (when capped), `best_effort` (bool) |
| `units.full_sheet` | `id`, `limit` (50) | `id`, `name`, `sheet` (object keyed by category, then sub-category), `truncated` (array of `category.subcategory` paths that hit the cap), `best_effort` (array of paths) |
| `units.set_nickname` | `id`, `nickname` (string; empty clears) | `id`, `name`, `nickname`. Namespace `units_write`. |

`units.sheet` with a category that has sub-tabs and no `subcategory` returns every sub-tab of that category, each capped. Unknown category or sub-category is `BAD_REQUEST` with the valid list in the message.

MCP tools: `list_units` (all, with optional `bucket`), `list_citizens`, `list_domesticated`, `list_others`, `find_unit`, `get_unit`, `get_unit_sheet`, `get_unit_full_sheet`, `set_unit_nickname`. The three bucket tools and `list_units` are thin wrappers over one Lua op. `set_unit_nickname` is the first tool without the read-only annotation.

Protocol version bumps to 2. The Phase 1 `category` argument and the old `units.get` field set go away; nothing outside this repo depends on them.

### 8.5 Sheet categories and where the data comes from

Tabs and sub-tabs follow the 53.16 unit profile as documented on the wiki (https://dwarffortresswiki.org/index.php/Profile, checked 2026-10-12). Struct paths are from df-structures `master` (`df.unit.xml`, `df.soul.xml`, `df.personality.xml`, `df.skill_enum.xml`) and must be confirmed in-game per section 8.6 before they are written into `docs/protocol.md`.

| Category | Sub-categories | Source | Confidence |
|---|---|---|---|
| `overview` | none | Row fields plus `getNoblePositions`, `getGoalName` (dream), `getKillCount`, squad, top skills by rating, mood and long-term mood (`personality.longterm_stress` via `getStressCategoryRaw`), kin summary from `relationship_ids`, hauled item from `unit.inventory` | high |
| `relations` | none | Kin from `unit.relationship_ids` (Spouse, Mother, Father, Lover, Sibling, Child, PetOwner, Pet). Friends, grudges, acquaintances, and deities from the historical figure's links and relationship records. Each entry `{relation, id, name, hist_figure_id}` | medium: histfig side needs the struct check |
| `groups` | none | `historical_figure.entity_links` resolved to entity name, link type, and positions from `getNoblePositions` | medium |
| `military` | `squads`, `uniform`, `kills` | `unit.military.squad_id` and `getSquadName`, squad orders; uniform from `squad.positions[squad_position]`; kills from `getKillCount` and the histfig kill record | medium |
| `thoughts` | `recent`, `memories` | `personality.emotions` (type, strength, thought, severity, year, year_tick); memories from `personality.memories` | medium: caption strings for thought types need the check |
| `personality` | `traits`, `values`, `preferences`, `needs` | `personality.traits` indexed by `personality_facet_type` plus `soul.mental_attrs`; `personality.values` (type, strength); `soul.preferences` resolved to readable item, material, creature, or form names; `personality.needs` (id, focus_level, need_level) | high |
| `items` | none | `unit.inventory` (item, mode: worn, hauled, weapon) and `unit.owned_items`, described with `dfhack.items.getReadableDescription` | high |
| `health` | `status`, `wounds`, `treatment`, `history`, `description` | `unit.health.flags` and body part flags; `unit.body.wounds` per wound with body part and severity; treatment flags from `unit.health`; description from caste description, `getPhysicalAttrValue`, and `unit.appearance` | low for status, treatment, history; high for wounds and description |
| `skills` | `labor`, `combat`, `social`, `other`, `knowledge` | `soul.skills` grouped by `df.job_skill.attrs[id].type`: `labor` = Normal and Medical; `combat` = MilitaryWeapon, MilitaryAttack, MilitaryDefense, MilitaryUnarmed, MilitaryMisc; `social` = Social; `other` = Personal and Cultural; `knowledge` = `soul.performance_skills` (poetic, musical, dance forms, instruments). Each skill `{skill, caption, rating, level, experience, rusty}` | high; the Cultural placement in `other` needs an in-game compare |
| `rooms` | none | `unit.owned_buildings` with `dfhack.buildings.getRoomDescription(b, u)` and position | high |
| `labor` | `work_details`, `workshops`, `locations`, `work_animals` | Enabled labors from `unit.status.labors`; work detail membership from `plotinfo.labor_info`; workshops whose `profile.permitted_workers` contains the id; occupations from `world.occupations`; work animals are units whose `PetOwner` is this unit and are war or hunting trained | medium |

Rules for sheet data:

- Every entry is plain data with readable names. Enum values are emitted as their DF token (`SWORD`, `MINING`) plus a caption where DF has one.
- A category or sub-category that could not be built is returned as `{"best_effort": true, "note": "..."}` rather than failing the whole op.
- Lists are sorted by what the player would sort by: skills by rating, thoughts newest first, relations kin first.

### 8.6 In-game struct check before implementation

`lua_eval` is off by default, so this is done by the player at the DFHack console with `:lua`, or in a dev session with it temporarily on. Record results in `docs/decisions/0003-unit-sheet-fields.md`.

1. `dfhack.units.getReadableName` output for a stray tame cat, a named pet, a war dog, a merchant, and a goblin invader.
2. `unit.relationship_ids` indices present in 53.16 (`PetOwner`, `Pet`, `Spouse`, `Lover`, `Sibling`, `Child`) and whether `Pet` is set on the owner or only `PetOwner` on the animal.
3. The historical figure fields that hold friends, grudges, and deity worship, and `entity_links` for groups.
4. `df.unit_thought_type.attrs` and `df.emotion_type.attrs` captions, and the shape of `personality.memories`.
5. `unit.health` flag names for the Status and Treatment sub-tabs.
6. Which skills the in-game Skills tab lists under Other versus Knowledge, to confirm the `job_skill_class` grouping.
7. `plotinfo.labor_info.work_details` path and membership field.
8. `dfhack.units.setNickname` on a dwarf and on an animal, and that the change shows in the unit list immediately.

### 8.7 Delivery order

One PR per row, each updating `docs/protocol.md`, the README progress table, and the smoke test.

1. `mod/units-buckets`: `units.list` with buckets and new rows, `units.find`, new `units.get`, protocol 2, `list_*` and `find_unit` tools.
2. `mod/units-sheet`: `units.sheet` and `units.full_sheet` for the high-confidence categories (`overview`, `personality`, `items`, `skills`, `rooms`, `wounds`, `description`).
3. `mod/units-sheet-2`: remaining categories after the struct check.
4. `mod/units-nickname`: `units_write` namespace, settings toggle, `units.set_nickname`, `set_unit_nickname` tool.

### 8.8 Addendums (2026-10-12)

- **2.1 Nobility.** `nobles.list` describes every position of the site government (`plotinfo.main.fortress_entity`, falling back to `plotinfo.group_id`) with holders resolved through the historical figure's `unit_id`. `nobles.assign` follows the bookkeeping DFHack's `make-monarch` script does: swap `assignment.histfig`, erase the previous holder's `histfig_entity_link_positionst`, insert one for the appointee. Military positions are refused because their seats are tied to squads. Namespaces `nobles` (on) and `nobles_write` (off).
- **2.2 Console guard.** `console.run` refuses `claude-bridge perm`, `allow`, and `deny`, and any `claude-bridge` line containing `;`, so the allowlist entry needed for `reload` cannot change permissions. Closes the README bug.
- The op module list moved from the control script to `rpc.OP_MODULES` so `reload` can register a new module. Adding a module still needs one `disable`/`enable` on installs whose control script predates the move.

---

## 9. Phase 3 addendum: stocks and pops (planned 2026-10-12)

Decisions agreed on 2026-10-12 after a live probe of the fort's `plotinfo` record. Everything here reads; the only new write is the settings toggle, which the player owns.

### 9.1 What the game keeps

| Need | Source (checked live, DFHack 53.16-r2) | Notes |
|---|---|---|
| Top-bar counts | `df.global.plotinfo.tasks.food` fields `total`, `drink`, `seeds`, `meat`, `fish`, `plant`, `other` | Exact even with no bookkeeper: on the test fort every value matched a live count of the item vectors. `total` is meat + fish + plant + other (not drink or seeds). |
| Bookkeeper | `plotinfo.nobles.bookkeeper_precision` (achieved level), `bookkeeper_settings` (goal, `record_precision_level_type`: `NONE`, `nearest_10`, `nearest_100`, `nearest_1000`, `nearest_10000`, `all_accurate`), `bookkeeper_cooldown` | With nobody appointed the fort reads achieved 0, goal `all_accurate`. |
| Bookkeeper's stock records | `plotinfo.tasks.item_counts` (per `item_type`) and `unit_counts` (per profession) | All zero on the test fort: these are what the bookkeeper writes, so they are the honest "what the player's Stocks screen knows" source. |
| Live items | `df.global.world.items.other.IN_PLAY`, `item:getType()`, `item:getStackSize()`, `dfhack.matinfo.decode(item):toString()`, `dfhack.items.getReadableDescription`, `df.item_type.attrs[t].caption` (the game's own category captions such as "headwear", "raw fish") | DFHack's old stocks plugin excluded `hostile`, `trader`, `in_building`, `garbage_collect`, `removed`, `dead_dwarf`, `murder`, `construction`; the Stocks screen counts built, forbidden, dump and melt items but shows them as unavailable. |
| Artifacts | `df.global.world.artifacts.all` | Name, item, holder or position. |
| Wealth | `plotinfo.tasks.wealth` fields `total`, `weapons`, `armor`, `furniture`, `other`, `architecture`, `displayed`, `held`, `imported`, `exported`, `offered` | `total` is created wealth; imported is separate. |
| Fort status | `plotinfo.fortress_rank` (0 outpost, 1 hamlet, 2 village, 3 town, 4 city, 5 metropolis), `progress_population`, `progress_trade`, `progress_production`, `tasks.population`, `potential_soldiers`, `trained_animals`, `other_animals`, `carnivores`, `omnivores`, `num_artifacts`, `total_deaths`, `invaders_repelled`, `excavated_tiles`, `discovered_*_features`, `happiness_number` | Rank thresholds from the wiki (defaults): hamlet 20 pop or 5,000 created or 500 exported; village 50 / 25,000 / 2,500; town 80 / 100,000 / 10,000; city 110 / 200,000 / 20,000; metropolis 140 / 300,000 / 30,000. |

### 9.2 Decisions

| Question | Decision |
|---|---|
| "~" rule | The stored counts are exact, so the estimate marker is a display rule, and the game's own rule is undocumented, so we define ours: when the achieved precision is below `all_accurate`, round **up** to the next multiple of the step the level names (`nearest_10` to 10, `nearest_100` to 100, and so on; `NONE` behaves as 10) and prefix `~`. 15 shows as `~20`, 71 as `~80`. |
| Stocks shape | Category, then rows of item kind plus material: `{"weapons": {"name": "weapon", "total": 8, "rows": [{"item": "short sword", "material": "copper", "count": 3, "unavailable": 0}]}}`. Empty categories are omitted entirely. |
| 3.1 default | The setting is on: Claude reads true counts. Off puts Claude in bookkeeper view. |
| Bookkeeper view | Top bar: rounded per the rule above. Stocks: category totals from `tasks.item_counts` rounded the same way, with no rows unless the achieved precision is `all_accurate`, in which case it equals true view. On a fort with no bookkeeper this is all zeros, which is what the player sees. |
| 3.2 scope | Fort status: site and civilization names, rank with the thresholds for the next rank, the three progress ratings, the wealth breakdown, population and animal counts, artifacts, deaths, invaders repelled, excavated tiles, discovered features. Civ relations are not included. |
| Settings groups | Every namespace gets a `group`: General (time, settings), Units (units, units_write, nobles, nobles_write), Items (stocks, stocks_true), Commands (console, lua_eval). The settings window draws a header per group. |

### 9.3 Ops and tools

Namespace `stocks` (read, default on). Setting `stocks_true` (default on) is not an op namespace; the dispatcher does not check it, the stocks handlers do.

| Op | Args | Result | Tool |
|---|---|---|---|
| `stocks.bar` | `category` (optional: `food`, `drink`, `seed`, `meat`, `fish`, `plant`, `other`) | `mode` (`true` or `bookkeeper`), `bookkeeper` `{assigned, precision, goal, cooldown}`, `counts` keyed by category: `{value, display, estimated}`; with `category`, just that entry | `get_stock_bar(category=None)` |
| `stocks.list` | `category` (optional item type token or caption), `query` (optional substring on item or material), `limit` rows per category (default 50) | `mode`, `categories` keyed by token with `name`, `total`, `unavailable`, `rows` `{item, material, count, unavailable}`, `truncated`; empty categories omitted | `list_stocks(category=None, query=None, limit=50)` |
| `stocks.find` | `query`, `limit` (default 50) | Rows across every category with `category` added | `find_items(query, limit=50)` |
| `stocks.artifacts` | none | `artifacts` `{id, name, item, material, holder, pos}` | `list_artifacts()` |
| `stocks.status` | none | `site`, `civilization`, `rank` `{index, name, next: {name, population, created_wealth, exported_wealth}}`, `progress`, `wealth`, `population`, `counts` | `get_fort_status()` |

Bag handling: a `BOX` made of cloth, leather, or silk is listed under `bag`, as the game does. Rows sort by count descending.

### 9.4 Delivery

One branch, `mod/stocks`, in three commits matching 3.0, 3.1, and 3.2, each verified live before the next. 3.1's bookkeeper view is verified by appointing a bookkeeper at a low precision and comparing the op to the game's Stocks screen.

---

## 10. Phase 4 addendum: logistics and world (planned 2026-10-12)

Decisions agreed on 2026-10-12. DFHack already provides the hard parts of this phase: per-tile walkability groups, a building footprint checker, a one-call building placer that uses the game's own material filters, and a stockpile preset library.

### 10.1 What DFHack gives us (stable Lua API, checked 2026-10-12)

| Need | API |
|---|---|
| Work orders | `df.global.world.manager_orders.all` (vector of `manager_order`) and `manager_order_next_id`. Fields: `job_type`, `item_type`, `item_subtype`, `reaction_name`, `mat_type`, `mat_index`, `material_category`, `amount_left`, `amount_total` (0 is unlimited), `status` bitfield `{validated, active}`, `frequency` (`OneTime`, `Daily`, `Monthly`, `Seasonally`, `Yearly`), `workshop_id`, `max_workshops`, `item_conditions`, `order_conditions`. DFHack's own `workorder` script creates orders by allocating the id from the counter, filling these fields, and inserting into the vector; we do the same. |
| Job names | `df.job_type.attrs[t].caption` and `.item`; reactions in `world.raws.reactions.reactions` with `code` and `name`. |
| Workshops | `world.buildings.other.WORKSHOP_ANY` and `FURNACE_ANY`; `contained_items` (item, use_mode), `jobs`, `profile`, `name`, bounds and `z`. A strange mood claim is a job in `jobs` whose type is one of the `StrangeMood*` job types. |
| Tiles | `dfhack.maps.getTileSize()`, `isValidTilePos`, `getTileType(pos)` with `df.tiletype.attrs[t].shape` and `.material`, `getTileFlags(pos)` (designation: `hidden`, `outside`, `subterranean`, `flow_size`; occupancy: `building`, `unit`, `item`), `getWalkableGroup(pos)` (0 means not walkable; same group means connected), `getPlantAtTile`. |
| Footprints | `dfhack.buildings.checkFreeTiles(pos, size)` and `getCorrectSize`. |
| Placing | `dfhack.buildings.constructBuilding{type, subtype, pos, material}`: with no explicit items or filters it calls `getFiltersByType` for the game's default job item filters, queues the construction job, and returns the building or `nil, error`. Dwarves then fetch the closest matching material, which is the "use closest material" behaviour. |
| Stockpiles | `world.buildings.other.STOCKPILE`, `dfhack.buildings.getStockpileContents(sp)`, `constructBuilding{type=Stockpile, abstract=true, pos, width, height, fields={settings=...}}`, and `require('plugins.stockpiles').import_settings(name, {id=, mode=})` with the bundled `library/` presets. |
| Wagon | The embark wagon is a `building_wagonst` in `world.buildings.all` until deconstructed. |

### 10.2 Decisions

| Question | Decision |
|---|---|
| Map reading | Three reads: `get_tile(x,y,z)` for one tile; `get_area_map(x,y,z,w,h)` returning rows of one character per tile (legend in the response), capped at 64 by 64 per call; `find_build_space(w,h,z,near)` scanning walkable floor for a clear rectangle. Plus `get_map_bounds()` and `get_wagon()`. |
| Surface level | The wagon's z is the starting surface. Once the wagon is gone, the surface at a column is the highest tile whose shape is floor or ramp and whose designation is `outside`. |
| Placement with no materials | Count suitable items for the default filters first; if none, refuse with `no_materials` and place nothing. Invalid footprint refuses with `invalid_space` and the first blocking tile. Only blueprints are placed; nothing is completed instantly. |
| Stockpile config | Top-level category toggles directly on `settings.flags`, plus an optional DFHack preset name applied through the stockpiles plugin. Painting takes two corners and makes the rectangle. |
| Order edits | Create (job, optional item subtype, material or material category, reaction, amount, frequency), edit amount, frequency, max workshops, or workshop restriction; delete. Conditions are read-only. The `status` field is never written: only the manager validates an order. |
| List caps | 25 by default everywhere in this phase (CLAUDE.md rule 12), raised per call with `limit`. Workshop inventories included. |
| Namespaces | `orders` (on) / `orders_write` (off), `workshops` (on) / `build_write` (off), `map` (on), `stockpiles` (on) / `stockpiles_write` (off). Settings groups gain `Logistics` (orders, workshops, build, stockpiles) and `World` (map). |

### 10.3 Ops by item

| Item | Ops | Tools |
|---|---|---|
| 4.0 | `orders.list`, `orders.get`, `orders.jobs` (search job types and reactions by name), `orders.create`, `orders.edit`, `orders.delete` | `list_work_orders`, `get_work_order`, `find_job_types`, `create_work_order`, `edit_work_order`, `delete_work_order` |
| 4.1 | `workshops.list` (with `type` filter), `workshops.get` (location, mood claim, inventory capped, jobs, profile) | `list_workshops`, `get_workshop` |
| 4.2 | `map.bounds`, `map.wagon`, `map.tile`, `map.area`, `map.find_space` | `get_map_bounds`, `get_wagon`, `get_tile`, `get_area_map`, `find_build_space` |
| 4.3 | `build.workshop` (type, position, material category) | `place_workshop` |
| 4.4 | `stockpiles.list` (with category filter), `stockpiles.get` (bounds, settings, contents capped) | `list_stockpiles`, `get_stockpile` |
| 4.5 | `stockpiles.create` (two corners, name, categories, preset), `stockpiles.configure`, `stockpiles.rename`, `stockpiles.delete` | `create_stockpile`, `configure_stockpile`, `rename_stockpile`, `delete_stockpile` |

Order rows: `id`, `job` (token and caption), `item`, `material`, `reaction`, `amount` `{left, total, unlimited}`, `frequency`, `status` `{validated, active}`, `approved` (same as validated, the manager's doing), `workshop_id`, `max_workshops`, `conditions` `{items: [...], orders: [...]}` as readable text, `conditions_met` where it can be computed from the conditions alone.

### 10.4 Delivery

One branch per item from `main`, each verified live: `mod/work-orders`, `mod/workshops`, `mod/map`, `mod/build-workshop`, `mod/stockpiles`, `mod/stockpiles-paint`.


---

## 11. Phases 5 and 6 addendum: work order fix and striking the earth (planned 2026-10-13)

Decisions agreed on 2026-10-13 after a live reproduction of the work order bug and a read of DFHack's quickfort dig module, dig plugin, MapCache, and the df-structures designation fields. Everything cited was checked on 2026-10-13 against the `stable` docs and the `develop` and `master` branches listed in the references.

### 11.1 Phase 5.0: the "unknown material" work order

What the live test showed (DFHack 53.16-r2, 2026-10-13):

| Order created through `orders.create` | Stored as | Work Orders screen label |
|---|---|---|
| `material = "INORGANIC"` | `mat_type` 0, `mat_index` -1 (the generic inorganic material, DFHack's `toString` says "rock") | "make rock blocks", as expected |
| no material, no category | `mat_type` -1, `mat_index` -1 | "make unknown material rock blocks", the bug |
| `material_category = ["stone"]` | refused: the bitfield has no `stone` flag; valid flags are bone, cloth, horn, leather, pearl, plant, shell, silk, soap, strand, tooth, wood, wood2, yarn | n/a |

So "any stone" is only expressible as the generic inorganic material, and DFHack's own order library (`data/orders/rockstock.json`) stores every rock order that way, with no order-level `item_type`. Our tool description pointed Claude at specific tokens and category flags, so it had no way to say "any stone" and left the material empty.

Decisions:

| Question | Decision |
|---|---|
| Material input | `material` accepts plain words as well as tokens. `"any stone"`, `"stone"`, `"rock"` become the generic inorganic material. `"any wood"` and `"wood"` set the `wood` category. Other words resolve against the inorganic raws by id or solid-state name (`"silver"`, `"granite"`, `"plump helmet"` stays a plant token). Tokens such as `INORGANIC:IRON` keep working. An unresolvable word is `BAD_REQUEST` with the closest raw names in the message. |
| Default | When Claude gives neither a material nor a category, the handler fills the order, asks `dfhack.job.getManagerOrderName` for the label the screen would show, and refuses with `BAD_REQUEST` if that label contains "unknown material", telling Claude to pass `"any stone"`, `"any wood"`, or a specific material. Jobs that genuinely take no material (custom reactions, meals, cheese) pass unchanged because their label has no material slot. |
| Guidance | The tool description says: order any material for bulk goods (blocks, doors, beds), a specific material when value or function matters (silver goblets, steel picks). |
| `item_type` | No longer copied from the job's default `item` attribute; vanilla orders leave it unset. It is written only when Claude passes it. Subtype lookup still uses the job's item attribute, as DFHack's orders plugin does. Verified live before merge with a `MakeWeapon` pick order. |
| Row shape | Every order row gains `label`, the string from `dfhack.job.getManagerOrderName`, so Claude and the player read the same text. `orders.get` also gains `raw` `{mat_type, mat_index, item_type, item_subtype}` for diagnosis. |

Protocol version bumps to 3. Branch `mod/orders-material`. Verified in-game on 2026-10-13: rock blocks, wooden door, silver goblet, copper pick (no `item_type`), and a brew reaction all labelled correctly on the Work Orders screen; the no-material order was refused quoting "Make unknown material blocks". Section 11.5 checks 5 and 6 are covered by this.

### 11.2 What DFHack gives us for Phase 6

| Need | Source (checked 2026-10-13) |
|---|---|
| Wall vs floor, natural vs smoothed vs constructed | `df.tiletype.attrs[tt]`: `shape` (basic shape `Wall`), `material` (`STONE`, `SOIL`, `MINERAL` for veins, `LAVA_STONE`, `FEATURE`, `FROZEN_LIQUID`, `CONSTRUCTION`), `special` (`SMOOTH`). Engraved tiles are smooth tiles with an entry in `world.engravings` at that position. |
| Stone name | No Lua helper exists; DFHack does it in C++ `MapCache::BlockInfo::getBaseMaterial`. We replicate it: `MINERAL` reads the block's `block_square_event_mineralst` events and takes the last one whose `tile_bitmask` covers the tile; `STONE` and `SOIL` read `designation.geolayer_index` and look up `df.world_geo_biome.find(region.geo_index).layers[index].mat_index`, where the region comes from `dfhack.maps.getTileBiomeRgn(pos)` and `getRegionBiome`; a stone tile on a soil layer takes the biome's first stone layer and a soil tile on a stone layer its last soil layer; `LAVA_STONE` reads the region details' `lava_stone`, falling back to obsidian; `CONSTRUCTION` reads `dfhack.constructions.findAtTile(pos).mat_type/mat_index`; `FROZEN_LIQUID` is ice. Names come from `dfhack.matinfo.decode(0, index):toString()`. |
| Verification oracle | DFHack's `probe` command prints the same lookup for the tile under the cursor; allowlisting it for the test session gives a ground truth per tile. |
| Designations | `tile_designation.dig` (`No`, `Default`, `UpDownStair`, `Channel`, `Ramp`, `DownStair`, `UpStair`), `tile_designation.smooth` (0 none, 1 smooth, 2 engrave), `tile_occupancy.dig_marked` (blueprint marker), priority in the block's `block_square_event_designation_priorityst` (value times 1000, game default 4). df-structures `df.d_basics.xml`. |
| Waking the miners | Set `dfhack.maps.getTileBlock(pos).flags.designated = true` on every touched block, then `dfhack.job.checkDesignationsNow()`. This is exactly what quickfort's dig module does. |
| Who is on it | Designation jobs live in `df.global.world.jobs.list` (iterate with `utils.listpairs`), have `is_designation` set on their `job_type` attribute (`Dig`, `CarveUpwardStaircase`, `CarveDownwardStaircase`, `CarveUpDownStaircase`, `DigChannel`, `CarveRamp`, `RemoveStairs`, `SmoothWall`, `SmoothFloor`, `DetailWall`, `DetailFloor`, `CarveFortification`), carry `pos`, and `dfhack.job.getWorker(job)` returns the dwarf. `dfhack.job.removeJob(job)` cancels one. |
| Eligibility rules | From quickfort `internal/quickfort/dig.lua`: mine, up stair, and ramp need a wall or fortification that is not a construction; channel and down stair also accept floors, ramps, and stairs; up/down stair accepts walls, floors, and up stairs; smooth needs a hard natural material (`STONE`, `MINERAL`, `LAVA_STONE`, `FEATURE`, `FROZEN_LIQUID`) that is a wall or floor and not already smooth; engrave needs a smooth tile with no engraving. Hidden tiles may receive dig designations, which is how exploratory mining works, but never smoothing. Map-edge tiles and tiles under buildings are skipped. |
| Stair levels | DFHack's `gui/design` convention, matching the game: bottom level up stair, top level down stair (up/down if the tile is already an up stair), every level between up/down. |
| Circular stockpiles | quickfort `internal/quickfort/place.lua` builds a `room.extents` byte array and passes it in `fields` to `dfhack.buildings.constructBuilding`; we do the same. |

### 11.3 Decisions

| Question | Decision |
|---|---|
| Exposed-walls output | Straight segments, not tiles: `{x1, y1, x2, y2, z, length, material, kind, open_sides, floor_group}`, sorted by length, 25 by default. A segment is a run of wall tiles along x or y with the same material and kind, each bordering walkable floor on the same side. Technique note in 11.6 in case natural caves make this too noisy. |
| Area map | `map.area` gains `view`: `shape` (today's map), `material` (one letter per material with a per-call legend), `designations` (dig and smooth marks over the shape map). |
| Order kinds | `mine`, `stairs`, `channel`, `ramp`, `remove_stairs`, and in 6.3 `smooth`, `engrave`. Fortifications later. |
| Overlap | A tile that already carries any designation is skipped and counted; nothing is ever overwritten. The response lists the first 25 skipped positions with the reason. |
| Priority | Not exposed. Designations take the game's default. Verified live that a tile designated without a priority event is dug at priority 4. |
| Stairs | The box must span at least two z-levels; a single-level stair request is `BAD_REQUEST` with the reason. A 1 by 1 column is fine. |
| Circles | Filled only. A tile is inside when `dx*dx + dy*dy <= r*r + r`, radius 1 to 31. Stairs refuse the circle form. |
| Bounds | Every corner must be inside the map; nothing is clamped. A box is at most 64 by 64 tiles per level and 32 levels. |
| Erase | Clears dig and smooth designations in the box, optionally only one `kind`, and removes the pending job for each cleared tile with `dfhack.job.removeJob`. Reports counts. |
| Permissions | One new namespace `dig_write` (group World, off by default, label "Designate digging and smoothing") for everything in 6.2 to 6.4 except circular stockpiles, which stay under `stockpiles_write`. |
| Hidden tiles | Still reported as hidden and nothing else. Exposed walls are never hidden by construction, so the scan reveals nothing the player cannot see. |

### 11.4 Ops by item

| Item | Ops | Tools |
|---|---|---|
| 6.0 | `map.tile` gains `material_name`, `material_class` (`natural_stone`, `mineral_vein`, `soil`, `lava_stone`, `feature_stone`, `ice`, `construction`, `other`), `wall_kind` (`natural`, `smoothed`, `engraved`, `constructed`; only for walls), `construction` `{item_type, material}`, `engraved`. `map.area` gains `view`. New `map.exposed_walls` with `z`, optional `near_x`, `near_y`, `radius`, `material`, `limit`. | `get_tile`, `get_area_map(view=...)`, `find_exposed_walls` |
| 6.1 | `map.designations` with a box (`x1, y1, z1, x2, y2, z2`), optional `kind`, `assigned_only`, `limit`. Rows `{pos, kind, marker, job: {id, worker: {id, name}}}` plus counts per kind. | `list_designations` |
| 6.2 | `dig.designate` with `kind` (`mine`, `stairs`, `channel`, `ramp`, `remove_stairs`), a box, optional `dry_run`. `dig.erase` with a box and optional `kind`. | `designate_dig`, `erase_designations` |
| 6.3 | `dig.designate` accepts `smooth` and `engrave`. | same tools |
| 6.4 | `dig.designate` and `stockpiles.create` accept `circle` `{x, y, z, radius}` instead of corners. | `designate_dig(circle=...)`, `create_stockpile(circle=...)` |

Every designate response: `{designated, skipped_existing, skipped_unsuitable, skipped_building, skipped_edge, by_level: [...], skipped: [{pos, reason}] (capped), dry_run}`.

### 11.5 In-game checks before implementation

Recorded in `docs/decisions/0004-dig-fields.md` as they are done.

1. `probe` output against our material lookup on a layer stone wall, a vein, a soil wall, a constructed wall, a smoothed wall, an ice wall. Done 2026-10-13 without `probe` (it needs an in-game keyboard cursor): the owner confirmed soil by eye, and the 6.2 dig exposed sandstone (layer), kaolinite, bituminous coal, and turquoise (veins) that read back by name. Smoothed walls and floors checked 2026-10-13 after the 6.3 test (`StoneWallSmoothRD`, `MineralFloorSmooth` read back as smoothed). Constructed walls checked 2026-10-14 during the 7.1 test (`WALL`, material `plum wood`, `wall_kind` `constructed`, `construction {item_type WOOD}`). Ice walls remain unchecked.
2. A three-level staircase carved through the game's own UI: the `dig` value on each level. Superseded 2026-10-13: our own six-level column (up/down on an existing up stair, up/down between, up stair at the bottom) was carved by the miner into a working staircase.
3. A tile designated with no priority block event is picked up and dug. Done 2026-10-13: all 102 tiles were taken and dug with no priority written.
4. A designation job in `world.jobs.list` has `pos` set and `getWorker` returns the miner once assigned. Done 2026-10-13, with a twist: creating the job clears the tile's dig flag, so pending and taken orders are two sources that `map.designations` merges; the game queues jobs ahead of the miners, so taken does not imply assigned.
5. Vanilla "rock throne" and "wooden throne" orders made in the UI: `mat_type`, `mat_index`, `material_category`, `item_type` (through the new `raw` field).
6. `MakeWeapon` pick order with `item_type` left unset still labels as "forge copper pick".
7. A stockpile with circular extents accepts items and shows as one stockpile in the game. Done 2026-10-13: "Round Pile" (radius 2, 21 tiles) placed in the west chamber with the four corners left as floor; one building id, `tiles` counts the extents. Whether it accepts items is untested (no categories were enabled).

### 11.6 Delivery and technique notes

One branch per item from `main`, each verified live and updating `docs/protocol.md`, the README progress table, and the smoke test: `mod/orders-material` (5.0), `mod/map-materials` (6.0), `mod/map-designations` (6.1), `mod/dig` (6.2), `mod/dig-smooth` (6.3), `mod/dig-circles` (6.4). Protocol version bumps on each.

Room layout rule (owner's note, 2026-10-13): dwarves move diagonally, so a mined room needs a fully solid border including its corners. Leave at least one wall tile between rooms and between a room and a corridor, and join them only through deliberate doorways; rooms whose corners touch are one room. The first 6.2 test placed three chambers whose corners met the hall, which the owner flagged. This rule is in the `designate_dig` tool description so Claude applies it when planning.

Exposed-walls technique, kept for reference in case it needs replacing: scan one z-level by block (`map_block.tiletype` and `map_block.walkable` are 16 by 16 arrays, so a 3 by 3 embark level is about 20,000 tiles and well under a frame of Lua), keep wall tiles that are not hidden and have an orthogonal neighbour with a non-zero walkable group, then merge neighbours into runs along x and along y when material, kind, and open side match, preferring the longer axis. Expected failure mode: natural caverns and irregular dug-outs produce many one- and two-tile segments and hit the cap. Fallbacks, in order: a `segments=false` switch that returns tiles grouped by material with counts; the `material` view of `map.area` over the region of interest; `dfhack.maps.forEachTile` with a `shape_basic = Wall` filter as a native prefilter if the Lua scan is ever too slow.

---

## 12. Phases 7 to 9 addendum: building, zoning, pause (planned 2026-10-14)

Decisions agreed on 2026-10-14 after reading DFHack's `Buildings.cpp`, the `dfhack.buildings` Lua helper (the building input filter tables and `constructBuilding`), the quickfort build and zone modules, the buildingplan plugin and its placement overlay, the zone plugin, and the df-structures building, job, and basics definitions, all on the `master` branches listed in the references, plus the DF wiki pages for constructions, bridges, stairs, doors, activity zones, pastures, and archery ranges.

### 12.1 What DFHack gives us

| Need | Source (checked 2026-10-14) |
|---|---|
| Material filters | A building's construction job carries one `job_item` per input (`dfhack.buildings.getFiltersByType`). A filter can name a specific material (`mat_type`, `mat_index`), a material class through `flags3` (`stone`, `wood`, `metal`, `gem`; the v50 build menu's type toggles), or an item form through `item_type` (`BLOCKS`, `BOULDER`, `WOOD`, `BAR`). `flags2.building_material` marks the generic "building material" slot; `fire_safe` and `magma_safe` sit beside it. `isSuitableItem` and `isSuitableMaterial` judge an item against a filter, which `build.workshop` already uses to count stock. An explicit `items` list is the other route: `constructWithItems` attaches the items to the job (reserving them with `in_job`), which is what the vanilla UI and buildingplan's "choose items" do. |
| buildingplan | Keeps material filters per building type, not per placement, and attaches items in a background cycle; `addPlannedBuilding` suspends a building until its items exist. Its global `reconstruct` setting allows building on existing constructions. Not used in this phase: per-placement material choice is the requirement. |
| Constructions | `constructBuilding{type=Construction, subtype=df.construction_type.X, pos, filters}` places one tile; the subtypes are `Wall`, `Floor`, `Ramp`, `UpStair`, `DownStair`, `UpDownStair`, `Fortification`, `ReinforcedWall` (two materials plus a metal bar), and the `Track*` and `TrackRamp*` family. Each tile is its own building with its own `ConstructBuilding` job and one building material. `setSize` skips `setMaterialAmount` for constructions. |
| Valid construction tiles | quickfort `is_valid_tile_has_space_or_is_ramp`: tiletype shape `EMPTY`, `FLOOR`, `BOULDER`, `PEBBLES`, `RAMP_TOP`, `BROOK_TOP`, `TWIG`, `SAPLING`, `SHRUB`, or `RAMP`; not hidden; no building occupancy; `flow_size` at most 1 and no magma. `checkFreeTiles` only checks occupancy, passability, and flow. Vanilla allows building on a constructed floor; quickfort refuses a construction of the same shape on top of an existing one (floor on floor, ramp on ramp) for idempotency. Neither DFHack nor quickfort checks support or reachability; quickfort says so in its header. |
| Stairs across levels | buildingplan `get_stairs_subtype`: bottom level `UpStair` unless the tile is already a down or up/down stair (then `UpDownStair`), top level `DownStair` unless the tile is already an up or up/down stair, every level between `UpDownStair`. The same convention our `dig.designate` uses. The wiki adds that a stairwell through existing floors is built top down or needs access to each level. |
| Bridges | One building, flexible size up to 31 by 31, `direction` from `df.building_bridgest.T_direction` (`Retracting` -1, `Left`, `Right`, `Up`, `Down`; the arrow is the side that becomes a wall when raised), fixed at placement. Filter quantity -1 makes DFHack compute the material count (floor(tiles/4)+1 per the wiki). `setSize` records `gate_flags.has_support` from `hasSupport`. quickfort: the anchor edge may not sit on ramps; other tiles may. The wiki: a bridge needs a walkable perimeter tile and no tile under it deeper than 1/7 water. |
| Roads and supports | `RoadPaved` takes building material with computed quantity and supports extents; `RoadDirt` takes nothing and must sit on soil or grass; `Support` is 1 by 1 and takes one building material. |
| Furniture inputs | `building_inputs` in `dfhack/buildings.lua`: `Bed` takes a `BED`, `Door` a `DOOR`, `Chair` a `CHAIR`, `Table` a `TABLE`, `Cabinet` a `CABINET`, `Box` an empty `BOX`, `Armorstand`, `Weaponrack`, `Statue`, `Coffin`, `Slab`, `Cage`, `Chain`, `Floodgate`, `Hatch` a `HATCH_COVER`, `GrateWall` and `GrateFloor` a `GRATE`, `BarsVertical` and `BarsFloor` a `BAR`, `WindowGlass` a `WINDOW`, `WindowGem` three `SMALLGEM`, `TractionBench`, `AnimalTrap`, `Instrument`, `NestBox`, `Hive`, `Bookcase`, `DisplayFurniture`, and `OfferingPlace` a `TOOL` with the matching tool use, `Well` blocks plus a bucket, a chain, and a mechanism, `ArcheryTarget` one building material. |
| Furniture tile rules | quickfort: beds need an indoor floor (`not outside`); doors need a cardinally adjacent `WALL` or `FORTIFICATION` tile shape; wells need an empty tile (open air or ramp top) with an adjacent floor; hatches, floor grates, and floor bars go on floor, open air, ramp tops, or stairs; everything else needs a floor-like tile (floor, boulders, pebbles, twigs, saplings, shrubs). The wiki confirms a door needs one adjacent wall at designation and may be chained from constructed walls. |
| Cancel and dismantle | `dfhack.buildings.deconstruct(b)`: an unbuilt blueprint is removed at once (returns true), a built building gets a `DestroyBuilding` job (returns false); already verified in `build.remove`. A finished construction is a map tile, not a building: `dfhack.constructions.designateRemove(pos)` designates it for removal by a miner, or cancels a planned one, returning `true, was_only_planned`. `dfhack.constructions.findAtTile(pos)` finds the construction record. Suspension is `building.jobs[0].flags.suspend`. |
| Zone list and fields | `world.buildings.other.ACTIVITY_ZONE` (every fortress zone; `ANY_ZONE` includes site zones). `building_civzonest`: `type` (`civzone_type`), `zone_num` (the game's "Zone #n"), `name`, `spec_sub_flag.active`, `room` with `extents`, `assigned_unit_id` (the owner; `dfhack.buildings.getOwner`), `assigned_units` (pen, pit, pond), `assigned_items` (vermin), `squad_room_info` (barracks, archery), `location_id` and `site_id` (the location an area is attached to), `contained_buildings`, and `zone_settings`, a union: `pen.flags.check_occupants`; `pond.flag.keep_filled` (a pit is a pond zone without `keep_filled`); `gather.flags.pick_trees`, `pick_shrubs`, `gather_fallen`; `archery.dir_x`, `dir_y` (quickfort: shoot from west is `dir_x=1, dir_y=0`, from east `-1, 0`, from north `0, 1`, from south `0, -1`); `tomb.flags.no_pets`, `no_citizens`. `dfhack.buildings.getRoomDescription(zone)` gives the quality label. |
| Zone types in the UI | `civzone_type`: `MeetingHall`, `Bedroom`, `DiningHall`, `Dormitory`, `Barracks`, `ArcheryRange`, `Office`, `Tomb`, `Pen`, `Pond`, `Dump`, `WaterSource`, `FishingArea`, `SandCollection`, `ClayCollection`, `PlantGathering`, `AnimalTraining`, `Dungeon` (18, matching the wiki). `Shrine` exists in the enum but not in the fortress UI; the rest of the enum is site-realization zones. |
| Zone placement | quickfort zone module: `constructBuilding{type=Civzone, subtype=<civzone_type>, abstract=true, pos, width, height, fields={assigned_unit_id=-1, room={x, y, width, height, extents}}}`, then assign `spec_sub_flag.active`, `name`, and `zone_settings`. The only tile rule is "not hidden": zones go over walls, open space, water, buildings, and stockpiles. `checkFreeTiles` takes `allow_wall` and `allow_flow` for this. `constructAbstract` assigns `zone_num`. |
| Zone edits | Extents are edited in place, then `dfhack.buildings.notifyCivzoneModified(zone)` rebuilds the building-to-zone map. `dfhack.buildings.setOwner(zone, unit)` sets or clears the owner (nil clears). The zone plugin assigns an animal by pushing its id onto `assigned_units` and adding a `general_ref_building_civzone_assignedst` to the unit, after detaching it from any previous zone, cage, or chain; unassigning erases both. `dfhack.buildings.deconstruct` removes a zone at once and clears its squad and unit links. |
| Locations | A tavern, temple, library, guildhall, or hospital is an `abstract_building_*st` in `site.buildings` with flags, a name, and `contents.building_ids` listing the zones; the zone points back with `location_id`. quickfort creates them by hand. Read in 8.0, written in 8.2. |
| Pause | `dfhack.world.ReadPauseState()` (true while paused or single-stepping) and `dfhack.world.SetPauseState(bool)`, which writes `df.global.pause_state`. The RPC call suspends the core only for its own duration, so the new state holds after the call returns. |

### 12.2 Decisions

| Question | Decision |
|---|---|
| Material input (7.0) | `material` accepts the Phase 5 plain words plus forms: a material ("granite", "silver", "any stone", "wood", "any metal"), a form ("blocks", "boulders", "logs", "bars"), or both ("granite blocks", "wooden logs"). Tokens such as `INORGANIC:GRANITE` keep working. The resolver lives in a shared `materials` module that `orders.create`, `build.workshop`, `build.construct`, and `build.place` all use. A material class sets the `flags3` bit; a form sets `item_type`; a specific material sets `mat_type` and `mat_index`. Omitted means the game's default filter: closest suitable material. |
| Shortage | Count usable items per filter as `build.workshop` does. If any filter is short, refuse with `no_materials` and `available` broken down by material and form, so Claude can pick again. Nothing is placed suspended. For a shape, the count covers the whole shape: the response says `needed` and `available`, and nothing is placed when `available < needed`. |
| Material list read | New `build.materials` under `stocks`: usable building materials in play (not forbidden, dumped, melting, in a job, built, trader, or hostile) grouped by material and form with counts, optional `form`, `material`, `fire_safe`, `magma_safe`, `limit`. |
| Construction kinds (7.1) | `wall`, `floor`, `ramp`, `stairs`, `fortification`, `bridge`, `paved_road`, `dirt_road`, `support`. Tracks, track stops, rollers, and reinforced walls wait. |
| Shapes | Walls, floors, ramps, fortifications: a box (`x1..z2`, filled or `hollow`), a circle (`circle={x,y,z,radius}`, filled or `hollow` ring), or a line (`line={x1,y1,x2,y2,z}`, any angle). A hollow box is its perimeter; a hollow circle is the ring of inside tiles that touch an outside tile. Lines are drawn with Bresenham; `thick` (default true) adds the orthogonal step at every diagonal move so the line has no diagonal gaps, because dwarves walk diagonally. A z range stacks the shape on every level (a tower in one call). Stairs take a box of at least two levels with the dig convention, and refuse circles and lines. Bridges, roads, and supports are single buildings: a bridge takes a box up to 31 by 31 on one level plus `direction` (`retracting`, `raise_north`, `raise_south`, `raise_east`, `raise_west`); roads take a box up to 31 by 31 with unsuitable tiles cut out of the extents; a support takes one tile. Boxes for per-tile kinds are at most 64 by 64 by 32, as for digging. |
| Per-tile rules | quickfort's list above. An existing construction of the same shape on the tile is skipped as `existing`; other constructions are built over as vanilla allows. A tile with a building, a planned construction (occupancy `Planned`), a unit-blocked tile, liquid deeper than 1, magma, a tree, or hidden rock is skipped with a reason. Map-edge tiles are skipped. |
| Support | Not enforced. A tile with no floor, wall, ramp, stair, or construction among its eight neighbours on the same level and no solid tile below is counted and listed as `unsupported` (first 25) so Claude can order supports or reorder its plan; it is still placed, as quickfort does. The game refuses the job at build time if a dwarf cannot reach it, which `build.list` then shows. |
| Furniture types (7.2) | Plain names mapped to `building_type`: `door`, `floodgate`, `hatch`, `wall_grate`, `floor_grate`, `vertical_bars`, `floor_bars`, `glass_window`, `gem_window`, `bed`, `table`, `chair`, `cabinet`, `chest`, `armor_stand`, `weapon_rack`, `statue`, `slab`, `coffin`, `cage`, `restraint`, `well`, `archery_target`, `traction_bench`, `nest_box`, `hive`, `bookcase`, `display_case`, `offering_place`, `instrument`, `animal_trap`. Traps, levers, pressure plates, siege engines, machines, and the trade depot wait. |
| Furniture placement | One tile `x, y, z`, or a box that places one per valid tile (beds in a dormitory), capped at 25 per call. Tile rules per type from quickfort (beds indoors; wells on an empty tile beside a floor; hatches, floor grates, and floor bars on floor, air, ramp tops, or stairs; doors beside a wall). `material` restricts the item the same way as constructions (a "granite door", "any wood"). Missing items refuse with `no_materials` and `make_with`, the work order job and item that produces it (from buildingplan's item-to-job table: `ConstructDoor`, `ConstructBed`, `ConstructThrone` for chairs, `ConstructChest` for boxes, and so on), so Claude can queue an order itself. |
| Door rule | The game's rule: at least one cardinally adjacent wall or fortification, else `skipped_unsuitable`. When the door is not between two opposite walls the response carries a `warning` naming the open sides. Door and hatch toggles are deferred. |
| Cancel and dismantle (7.3) | `build.remove` accepts every building type (the strange-mood guard stays; a zone or stockpile is refused and pointed at its own op). New `build.remove_construction` takes a box or circle with `dry_run`: planned constructions are cancelled at once, finished ones are designated for removal through `designateRemove`; tiles without a construction are skipped and counted. New `build.suspend` with `id` and `suspended` flips `jobs[0].flags.suspend`. |
| Building list | New `build.list` under `workshops`: every building in play with `id`, `kind`, `type` (workshop, furnace, construction, or civzone subtype), `name`, `pos`, `bounds`, `stage` and `max_stage`, `planned` (stage 0), `suspended`, `marked_for_removal`, `job` `{type, worker}`, `materials` (attached item count vs. needed). Filters `kind`, `planned_only`, `z`, box, `limit`, `offset`. Stockpiles and zones are listed by their own ops and excluded here. |
| Permissions (7.x) | One `build_write`, relabelled "Place and remove buildings and constructions". `workshops` relabelled "Read workshops and buildings". |
| Zone reads (8.0) | `zones.list` with `type`, `query` (name substring), `active`, `limit`, `offset`; rows `{id, number, name, label, type, active, bounds, pos, tiles, owner, assigned_count, location}`. `zones.get` with `id` and `limit`: the row plus `extents` as the first 25 tiles (and a count), `owner` `{id, name}`, `assigned_units` `[{id, name}]`, `squads` (ids and names, read only), `location` `{id, type, name}`, `settings` (the type's union fields by name, with `pit_or_pond` spelled out), `contained_buildings`, `room_description`. `map.tile` keeps its `zones` field. |
| Zone types (8.1) | The 18 UI types by plain name: `meeting_area`, `bedroom`, `dining_hall`, `dormitory`, `barracks`, `archery_range`, `office`, `tomb`, `pen`, `pit`, `pond`, `dump`, `water_source`, `fishing`, `sand`, `clay`, `gather`, `animal_training`, `dungeon`. `pit` and `pond` both map to `Pond`, differing in `keep_filled`. |
| Zone painting | A box (`x1, y1, x2, y2, z`, at most 64 by 64) or a circle (radius 1 to 31), built with room extents as stockpiles are. Every revealed tile counts, walls and water included; hidden tiles are cut from the extents and counted. Args `name`, `active` (default true), and the type's settings (`keep_filled` is implied by `pit`/`pond`; `pick_trees`, `pick_shrubs`, `gather_fallen`; `shoot_from`; `allow_pets`, `allow_citizens`). An overlapping zone of the same type is reported as a `warning`, not refused, because the game allows it. |
| Zone edits | `zones.edit` with `id` and any of `name`, `active`, settings, `add` (box or circle) and `remove` (box or circle) that grow or shrink the extents (the bounding box is re-fitted and `notifyCivzoneModified` called), and `type` is immutable. `zones.assign` with `id` and `unit_id`: for owner types (`bedroom`, `office`, `dining_hall`, `tomb`) it calls `setOwner` and replaces the previous owner; for `pen`, `pit`, and `pond` it appends to `assigned_units` with the unit general ref, detaching the unit from its previous zone first; pens accept tame animals only; pits and ponds accept any unit that is not a citizen or a pet, so Claude cannot pit a dwarf; other types are refused. `zones.unassign` reverses either. `zones.delete` calls `deconstruct`. Squads, locations, and `assigned_items` (vermin) are read only. |
| Pause (9.0) | `time.set_pause` with `paused` under new `pause_write` (group General, off by default, label "Pause and unpause the game"). Returns the state before and after. `time.now` keeps `paused`. |
| List caps | 25 by default everywhere, raised per call with `limit` (rule 12). Placement responses list the first 25 placed building ids and the first 25 skipped tiles with reasons. |

### 12.3 Ops by item

| Item | Ops | Tools |
|---|---|---|
| 9.0 | `time.set_pause` | `set_paused` |
| 7.0 | `materials` module; `build.materials`; `build.workshop` and `orders.create` take the shared words | `list_building_materials`, `place_workshop(material=...)` |
| 7.1 | `build.plan_construction` (read, `workshops`), `build.construct` (`build_write`) with `kind`, a box, circle, or line, `hollow`, `thick`, `material`, `direction`, `dry_run` | `plan_construction`, `place_construction` |
| 7.2 | `build.place` with `type`, a tile or box, `material` | `place_furniture` |
| 7.3 | `build.list`, `build.remove` (all types), `build.remove_construction`, `build.suspend` | `list_buildings`, `remove_building`, `remove_constructions`, `suspend_building` |
| 8.0 | `zones.list`, `zones.get` | `list_zones`, `get_zone` |
| 8.1 | `zones.create`, `zones.edit`, `zones.assign`, `zones.unassign`, `zones.delete` | `create_zone`, `edit_zone`, `assign_zone`, `unassign_zone`, `delete_zone` |

Every placement response: `{placed, skipped_existing, skipped_unsuitable, skipped_building, skipped_edge, unsupported, buildings: [ids] (capped), skipped: [{pos, reason}] (capped), materials: {needed, available, filter}, dry_run, warnings}`.

### 12.4 In-game checks before implementation

Recorded in `docs/decisions/0005-building-fields.md` as they are done.

1. A wall placed with a `flags3.stone` filter and one with `item_type=BLOCKS` are both built from matching items; a `mat_index` filter still works for constructions. Fallback if the class flags are ignored: pick the items and pass `items`. Partly done 2026-10-14 on workshops: a `mat_index` filter (plum wood) was honoured, the builder fetched a plum log; the `wood` class bit placed and built fine but with only wood in stock it proves nothing yet. The construction test in 7.1 settles the class bits.
2. Whether the game refuses an unsupported construction at placement or only at build time, by placing one floor tile over open air through the UI. Partly answered 2026-10-14: the down stair placed in open air above a planned up stair was accepted and built once the stair below existed.
3. A door placed through the UI next to one wall; a door with no adjacent wall (expected: refused by the UI). Done 2026-10-14 through the bridge instead: a door between two built walls was installed; a door on open grass was refused by our rule before placement. Lesson from the same test: a roof over walls needs a ramp or stair for access, and a tree canopy above a ramp blocks it (the owner's note), so place the ramp where the level above is open.
4. A pit and a pond placed through the UI: `keep_filled` on each; an archery range with each shooting direction: `dir_x`, `dir_y`. Not yet checked live; the bridge follows quickfort's values.
5. A pasture with an animal assigned through the UI: the unit's general refs and `assigned_units`.
6. A bedroom with an owner assigned through the UI: `assigned_unit_id` and `getOwner`. Done 2026-10-14 the other way round: an office assigned through the bridge with `setOwner` showed its owner in `getOwner` and on the owner's rooms tab.
7. The stair subtype written by the UI on each level of a three-level constructed stairwell. Superseded 2026-10-14: our own two-level stairwell (up stair at the bottom, down stair on top) was built by the dwarves and reads back as `STAIR_UP` under `STAIR_DOWN`, both walkable.
8. A bridge placed through the UI with a raise direction: `direction` and `material_amount`.
9. `SetPauseState(false)` from the RPC call leaves the game running after the call returns. Done 2026-10-14: the frame counter advanced 202 frames in two seconds and stopped on the pause call.

### 12.5 Delivery

One branch per item from `main`, in this order, each verified live and updating `docs/protocol.md`, the README progress table, and the smoke test: `mod/pause` (9.0), `mod/build-materials` (7.0), `mod/constructions` (7.1), `mod/furniture` (7.2), `mod/build-remove` (7.3), `mod/zones` (8.0), `mod/zones-paint` (8.1). Protocol version bumps on each, starting at 4.

Delivered 2026-10-14 in that order as PRs #29 to #35, protocol versions 4 to 10. Notes from the live tests: a reload of the mod now drops cached helper modules (7.0); a roof over walls needs a ramp or stair for access and a tree canopy above a ramp blocks it (7.2); `map.tile` buildings carry `built` because a planned building occupies its tiles (7.2); construction removal skips the top-of-wall records above constructed walls (7.3); `getRoomDescription` is empty for zones on 53.16-r2 (8.1). Still unverified live: the material class bits on construction jobs with mixed stock, pit and pond flags and archery directions written by the UI, animal assignment and zone deletion through the bridge.

---

## References (checked 2026-10-12)

- DFHack releases: https://github.com/DFHack/dfhack/releases (latest 53.16-r2)
- DFHack modding guide: https://docs.dfhack.org/en/stable/docs/guides/modding-guide.html
- DFHack Lua API: https://docs.dfhack.org/en/stable/docs/dev/Lua%20API.html
- DFHack remote interface: https://docs.dfhack.org/en/stable/docs/dev/Remote.html
- DFHack CoreProtocol.proto: https://github.com/DFHack/dfhack/blob/develop/library/proto/CoreProtocol.proto
- DFHack overlay dev guide: https://docs.dfhack.org/en/stable/docs/dev/overlay-dev-guide.html
- DF wiki unit profile (tabs and sub-tabs, 53.16): https://dwarffortresswiki.org/index.php/Profile
- df-structures: https://github.com/DFHack/df-structures (`df.unit.xml`, `df.soul.xml`, `df.personality.xml`, `df.skill_enum.xml`)
- DFHack unit viewer mood names: https://github.com/DFHack/scripts/blob/master/internal/unit-info-viewer/overall-mood.lua
- DFHack quickfort dig rules (checked 2026-10-13): https://github.com/DFHack/scripts/blob/master/internal/quickfort/dig.lua
- DFHack quickfort stockpile extents (checked 2026-10-13): https://github.com/DFHack/scripts/blob/master/internal/quickfort/place.lua
- DFHack gui/design stair convention (checked 2026-10-13): https://github.com/DFHack/scripts/blob/master/gui/design.lua
- DFHack MapCache base material lookup (checked 2026-10-13): https://github.com/DFHack/dfhack/blob/develop/library/modules/MapCache.cpp
- DFHack orders plugin and rock order library (checked 2026-10-13): https://github.com/DFHack/dfhack/blob/develop/plugins/orders.cpp and https://github.com/DFHack/dfhack/blob/develop/data/orders/rockstock.json
- df-structures tile designation and dig enums (checked 2026-10-13): https://github.com/DFHack/df-structures/blob/master/df.d_basics.xml
- DFHack buildings Lua helper, input filter tables and constructBuilding (checked 2026-10-14): https://github.com/DFHack/dfhack/blob/master/library/lua/dfhack/buildings.lua
- DFHack Buildings module, sizes, free-tile check, deconstruct (checked 2026-10-14): https://github.com/DFHack/dfhack/blob/master/library/modules/Buildings.cpp
- DFHack quickfort build and zone modules (checked 2026-10-14): https://github.com/DFHack/scripts/blob/master/internal/quickfort/build.lua and https://github.com/DFHack/scripts/blob/master/internal/quickfort/zone.lua
- DFHack buildingplan plugin and placement overlay (checked 2026-10-14): https://docs.dfhack.org/en/stable/docs/plugins/buildingplan.html and https://github.com/DFHack/dfhack/blob/master/plugins/lua/buildingplan/planneroverlay.lua
- DFHack zone plugin assignment logic (checked 2026-10-14): https://github.com/DFHack/dfhack/blob/master/plugins/lua/zone.lua
- df-structures buildings, zone settings, construction types, job item flags, civzone_type (checked 2026-10-14): https://github.com/DFHack/df-structures/blob/master/df.building.xml, https://github.com/DFHack/df-structures/blob/master/df.d_basics.xml
- DF wiki construction, bridge, stairs, door, activity zone, pasture, archery range pages (checked 2026-10-14): https://dwarffortresswiki.org/index.php/Construction and siblings
- MCP Python SDK: https://github.com/modelcontextprotocol/python-sdk (mcp 2.3.0, 2026-10-02)
- Dwarf Fortress wiki: https://dwarffortresswiki.org/
