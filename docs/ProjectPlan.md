# Project Plan: DFHack Claude Integration Mod

Status: Phases 0 through 4 merged and verified in-game on 2026-10-12 against DFHack 53.16-r2. Phases 5 and 6 planned on 2026-10-13; see section 3 and section 11. Last updated 2026-10-13.

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

### Future (after 6.4, not scheduled)

- Event queue (2.3) with `events.poll` and `wait_for_event`; chat overlay with `chat.message` and `chat.say`; autonomy timer; event-kind filters; a documented play loop in `docs/playing.md`. The driver loop design in 2.4 stays as written.
- Petitions, quickfort blueprints through the quickfort command, military (squads, alerts, stations), labor assignment, zones.
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

1. `probe` output against our material lookup on a layer stone wall, a vein, a soil wall, a constructed wall, a smoothed wall, an ice wall.
2. A three-level staircase carved through the game's own UI: the `dig` value on each level.
3. A tile designated with no priority block event is picked up and dug.
4. A designation job in `world.jobs.list` has `pos` set and `getWorker` returns the miner once assigned. Done 2026-10-13, with a twist: creating the job clears the tile's dig flag, so pending and taken orders are two sources that `map.designations` merges; the game queues jobs ahead of the miners, so taken does not imply assigned.
5. Vanilla "rock throne" and "wooden throne" orders made in the UI: `mat_type`, `mat_index`, `material_category`, `item_type` (through the new `raw` field).
6. `MakeWeapon` pick order with `item_type` left unset still labels as "forge copper pick".
7. A stockpile with circular extents accepts items and shows as one stockpile in the game.

### 11.6 Delivery and technique notes

One branch per item from `main`, each verified live and updating `docs/protocol.md`, the README progress table, and the smoke test: `mod/orders-material` (5.0), `mod/map-materials` (6.0), `mod/map-designations` (6.1), `mod/dig` (6.2), `mod/dig-smooth` (6.3), `mod/dig-circles` (6.4). Protocol version bumps on each.

Exposed-walls technique, kept for reference in case it needs replacing: scan one z-level by block (`map_block.tiletype` and `map_block.walkable` are 16 by 16 arrays, so a 3 by 3 embark level is about 20,000 tiles and well under a frame of Lua), keep wall tiles that are not hidden and have an orthogonal neighbour with a non-zero walkable group, then merge neighbours into runs along x and along y when material, kind, and open side match, preferring the longer axis. Expected failure mode: natural caverns and irregular dug-outs produce many one- and two-tile segments and hit the cap. Fallbacks, in order: a `segments=false` switch that returns tiles grouped by material with counts; the `material` view of `map.area` over the region of interest; `dfhack.maps.forEachTile` with a `shape_basic = Wall` filter as a native prefilter if the Lua scan is ever too slow.

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
- MCP Python SDK: https://github.com/modelcontextprotocol/python-sdk (mcp 2.3.0, 2026-10-02)
- Dwarf Fortress wiki: https://dwarffortresswiki.org/
