# Project Plan: DFHack Claude Integration Mod

Status: Phase 0 and Phase 1 implemented on branch `repo/scaffold` and verified in-game on 2026-10-12 against DFHack 53.16-r2. Phase 2 (unit analysis) planned, see section 8. Last updated 2026-10-12.

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

Why: no second runtime, uses the Team seat, and the whole system is observable from one terminal. A Python conductor using the Agent SDK remains a possible Phase 5 if running without a terminal matters.

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

### Phase 3: Events, chat, autonomy

- Event queue (2.3) with `events.poll` and `wait_for_event`.
- Chat overlay: text input in-game, history pane, messages appear as `chat.message` events; Claude replies with `chat.say`, shown in the pane and as a DF announcement.
- Autonomy timer with pause awareness, configured in the settings panel.
- Event-kind filters in settings.
- A documented "play loop" prompt in `docs/playing.md` describing how to start a session.

### Phase 4: Act

Each action is its own op, its own permission, and its own PR.

- Petitions: `petitions.list`, `petitions.respond(id, accept)`.
- Quickfort: `build.quickfort(blueprint_text, cursor)` with `--dry-run` first, run through the quickfort command.
- Manager orders: `orders.list`, `orders.create`, `orders.cancel`.
- Military: squads, alerts, stations.
- Labors and unit assignment.
- Zones and stockpiles.

### Phase 5: Candidates, not committed

- Luasocket push transport if poll latency is a problem.
- Python conductor using the Claude Agent SDK for headless play.
- Steam Workshop packaging of `mod/`.
- Legends and adventure mode.

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
    playing.md              how to run a play session (Phase 3)
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
        ui/chat.lua         chat overlay window (Phase 3)
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
9. Branch per change, conventional commit messages, PR via `gh`. Do not commit to `main`. Every branch starts from `main`; stacking on another branch needs the owner's explicit permission. Reason: stacked branches make PR diffs and merge order depend on each other.
10. When a feature lands, update the README progress section in the same PR. The README is for readers; this file is for builders.
11. Confirm before anything that affects a running game beyond reads: pausing, running console commands, or changing settings during a test session.

---

## 7. Open items

- License choice before the first public push.
- The `package.loaded` route for `RunLua` is confirmed working in-game (2026-10-12).
- `gh` is not installed on the dev machine; PRs are opened from the GitHub compare URL until it is.
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
- MCP Python SDK: https://github.com/modelcontextprotocol/python-sdk (mcp 2.3.0, 2026-10-02)
- Dwarf Fortress wiki: https://dwarffortresswiki.org/
