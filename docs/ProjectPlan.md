# Project Plan: DFHack Claude Integration Mod

Status: Phases 0 through 21 are built and released as Alpha 1.0.0 (tag `v1.0.0-alpha`, PRs #38 to #58, 13.1 petitions deferred to a README open issue). Patch 1 (Alpha 1.0.1: labor, seeds, migrant events, trade screen, diplomacy dialog, popups, hotkeys) was planned on 2026-10-16, design in section 15; none of it is built yet. Last updated 2026-10-16.

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

DFHack has no petition event, and `eventful` covers only some of what we need. Lua keeps a bounded event queue (200 entries, oldest dropped) fed by:

- `eventful` hooks: `onReport` filtered to the announcement types of the enabled kinds, `onUnitDeath`, `onInvasion`, `onUnitAttack` for fights.
- Pollers for what the game never announces: pending petitions, ghosts, moody dwarves that cannot find an item, artifacts dug up.
- The goals window's Send button, which appends a `goals` batch.
- The autonomy timer, which appends a `timer` batch.

Each event: `{"seq": n, "kind": "petition", "tick": ..., "text": ..., "pos": ..., "unit_ids": [...]}`. The server drains with `events.poll(after_seq)`, which returns only events older than the two-second quiet window or everything once 50 are queued. Nothing is removed on poll; the queue is a ring, so a client that falls behind loses old events rather than blocking the game. Event kinds are enabled per kind in the settings window (section 13).

### 2.4 Driver loop

Chosen (2026-10-15): Claude Code channels. The MCP server declares the channel capability, polls `events.poll` every two seconds from a background task, and pushes each batch to Claude Code as a `notifications/claude/channel` notification. Claude Code starts a turn on it when Claude is idle and queues batches until the current turn ends when it is busy, so the server keeps no buffer of its own. Petitions, goal updates, and the autonomy timer are just batch kinds, so one channel handles event response, goals, and autonomy. Claude talks back through the ordinary tools, including `send_message` for in-game announcements.

Why: no second runtime, uses the Team seat, and the whole system is observable from one terminal. The session must be started with the development-channels flag while channels are in research preview, and the org must allow channels; the README and `docs/playing.md` say how. The earlier design (a blocking `wait_for_event` tool driven by `/loop`) and a Stop hook that re-prompts Claude when the queue is non-empty remain documented fallbacks in section 13.1 if channels are unavailable.

### 2.5 Permissions

The settings panel (a DFHack overlay window) owns a permission table stored under `scriptmanager.getModStatePath("claude-bridge")`:

- Per-namespace toggles, one per read namespace and one per write namespace (the full list is in `docs/protocol.md`).
- Console allowlist: explicit command names allowed via `console.run`, with a deny-all default. Wildcard only by explicit player choice.
- Autonomy timer: off, or every N in-game days, every month change, or every N real minutes, with the prompt text. Paused when DF is paused (section 13).
- Event kinds: per-kind enable (section 13).
- Goals and the goal prompt, on their own tab (section 13).

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

### Phase 10: Kitchen, farms, chop and gather

Design in section 13. Reads under `stocks` and `map`; writes under a new `kitchen_write` toggle for the kitchen and the existing `build_write` and `dig_write` toggles for the rest.

- 10.0 Kitchen: see every ingredient the fort has in stock (plants, seeds, drinks, other) with whether cooking and brewing are allowed, and allow or ban each; tokens for ingredients not yet in stock.
- 10.1 Farm plots: read a plot's soil report (soil type, mud, above or below ground, cavern, biome) and its crop per season; place and remove plots; set the crop for each season and the fertilize flag. Crop availability follows DFHack autofarm's rule, documented as an approximation of the game's.
- 10.2 Chop and gather: `chop` and `gather` as designation kinds in boxes and circles, plus a read listing trees and shrubs in a box with species and marked state.

### Phase 11: Military

Namespaces `military` (read, on) and `military_write` (off). Where DFHack has no API (squad leader, disband, orders) the mod ships its own, written from the df-structures definitions and DFHack's inverse code paths, and verified live before merge.

- 11.0 Squads: list and inspect squads; create one with a kind (`melee`, `crossbow`) that applies a uniform template, or a named game preset; nickname it; add and remove members; set the leader; disband.
- 11.1 Orders: station, kill, patrol a route (with route creation from waypoints), cancel, and training through the squad's routine (off duty, staggered training, constant training, ready).
- 11.2 Equipment: read each slot's uniform spec, what each soldier actually wears, and ammunition; set uniform slots by item type and material class with the exact-match and replace-clothing flags, and ammunition counts.

### Phase 12: Dev tools

Three MCP tools (`dev_spawn_unit`, `dev_create_item`, `dev_exterminate`) that build a console line for `modtools/create-unit`, `modtools/create-item`, and `exterminate` and run it through the console op, so the allowlist still decides. `exterminate` keeps `--include-friendly` as an explicit argument.

### Phase 13: Events

Namespace `events` (read, on) with a per-kind toggle for each event the player allows. The mod collects announcements and polled state changes into a queue and batches them (two-second quiet window, at most 50 per batch); the server polls every two seconds and pushes each batch to Claude Code as a channel notification, which Claude Code queues until Claude is idle. Defaults on: mineral discovered, units fighting, petition.

- 13.1 Petitions: read pending petitions with the applicant, kind, and obligation; accept or reject through a mod-side API behind `petitions_write`.

### Phase 14: Plans, goals, messages

- 14.0 The mod creates `claude-df/goals.md` and `claude-df/plan.md` inside the current save when it enables. Claude reads, replaces, and appends to its plan; the player edits goals and the goal prompt in a `claude-bridge goals` window whose Send button (and only that button) delivers the goals to Claude.
- 14.1 No server-side buffer: Claude Code's channel queue is the only buffer, and the server forwards every batch as soon as its poll sees it.
- 14.2 `send_message`: Claude posts a message of up to 200 characters as an in-game announcement in the left-side alert stack, in light red (the closest palette colour to orange), with an optional position for click-to-zoom. No permission needed.

### Phase 15: Prompt timer

A timer in settings: every N in-game days, every month change, or every N real minutes, with an editable prompt. It fires through the channel, resets whenever the mod hands Claude an event batch, pauses with the game, and never stacks two pending prompts. Off by default; 7 in-game days when turned on.

### Phase 16: Traps and military buildings

Placement only, through `place_furniture`: lever, pressure plate with its trigger settings, cage trap, stone-fall trap, weapon trap, upright spike, catapult, ballista, trade depot. Lever linking is skipped (see the README open issues).

### Phase 17: Trade

Namespaces `trade` (read, on) and `trade_write` (off).

- 17.0 See caravans and their state, the depot, and whether the broker is at the depot; request the broker; bring goods to the depot; perform the trade through a mod-side API (headless drive of the game's trade screen first, the mod's own exchange as the fallback).
- 17.1 Diplomats: see the pending meeting, the trade agreement and price list; set next year's import requests; drive the meeting and the land-holder choice through a mod-side API where the game allows it.

### Phase 18: Mods

List the active Dwarf Fortress mods (id, name, version, source) and loaded DFHack plugins with their enabled state, under `settings`.

### Phase 19: Skills

A Claude Code plugin in `df-skills/` that teaches a release session, which has no `CLAUDE.md`, how to run a fort. Design in section 14.

- Fortress-Planner: read the goals and the plan from the save, take stock of the whole fort, plan seasons ahead in phases and tasks, keep `plan.md` in a fixed template, pause while planning, report to the player in-game.
- Work-Subdivision: the manager on the session model (Opus or better) plans, reads events and messages, and keeps the plan; a Sonnet steward does medium judgment; a Haiku scout sorts lists, surveys the map, and places orders in bulk from exact specs.
- Fortress-Quirks: what the game and the bridge have taught us, from diagonal movement and room borders to caps, pauses, encodings, the texture rule, and troubleshooting.

### Phase 20: Final touches

MIT license. README reordered for players: description, requirements, a seven-step installation, playing, settings, skills, open issues, then the feature list and progress table.

- 20.1 Release config: a GitHub Actions workflow that tests, zips the player-facing files (license, README, `server/`, `mod/`, `tools/`, `df-skills/`) without `CLAUDE.md`, `docs/`, or `.mcp.json`, and attaches the zip to a draft release on a `v*` tag.

### Phase 21: Release

Owner's phase: version bumps to Alpha 1.0.0, the tag, extra tests, a clean-folder walk through the install steps, and publishing.

### Patch 1: Alpha 1.0.1 (planned 2026-10-16)

Design in section 15. New toggles `labor_write`, `hotkeys_write`, `screens_write`, all off by default.

- P1.0 Labor: see the work details and put citizens on or off the existing ones; set a detail's mode. No new details, no labor edits.
- P1.1 Seeds: a sustainable-farming section in the fortress-quirks skill so a fort never runs out of seeds for the next season.
- P1.2 Migrants: a `migrants_arrived` event kind that names the newcomers.
- P2.0 Trade screen: open the depot's trade screen, press Trade, Offer, or Seize and answer counter-offers through the game's own handlers, read the merchant's reply and mood, close.
- P3.0 Diplomacy dialog: see when the meeting is available, open it, read the text and choices, step through it, finish it.
- P4.0 Popups: hear about the pausing box popups as events with their text, and close them.
- P5.0 Hotkeys: list the 16 zoom hotkeys and name, place, and clear them as points of interest.
- P6.0 Release: owner's version bumps, tag `v1.0.1-alpha`, tests, publishing.

### Future (after Patch 1, not scheduled)

- Burrows and defend-burrow orders, per-month squad schedule editing, lever linking and pulling, multi-weapon traps, siege engine aiming.
- Quickfort blueprints, custom work details and workshop worker lists, locations (8.2), tracks and minecarts, door and hatch toggles, the left-side alert buttons.
- Luasocket push transport, a headless Python conductor using the Agent SDK, Steam Workshop packaging, legends and adventure mode.

---

## 4. Repository structure

```
DF-MCP-Mod/
  README.md                 idea and progress, for readers
  CLAUDE.md                 rules for Claude Code in this repo
  LICENSE                   MIT, TheGraysonHarbison (Phase 20)
  .gitignore
  .mcp.json                 stdio entry: uv run --project server df-mcp
  .github/workflows/release.yml   tests, zips the player files, drafts a release on a v* tag (20.1)
  df-skills/                Claude Code plugin "claude-df" for release sessions (Phase 19)
    .claude-plugin/         plugin.json and marketplace.json
    skills/                 fortress-planner, work-subdivision, fortress-quirks, each a folder with SKILL.md
    agents/                 df-scout.md (haiku), df-steward.md (sonnet)
    README.md               what each skill and agent does
  docs/
    ProjectPlan.md          this file
    protocol.md             every RPC op, request and response shapes, error codes
    playing.md              development notes on channel sessions; the player-facing parts move to the README in Phase 20
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
        kitchen.lua, farms.lua, military.lua, petitions.lua, plan.lua, messages.lua, trade.lua, mods.lua
                            op modules added by Phases 10 to 18 (plus plants in map/dig)
        events.lua          event queue, eventful hooks, pollers, batching
        timer.lua           autonomy timer
        ui/settings.lua     settings window (tabs: Permissions, Events, Timer, Goals)
        ui/goals.lua        goals and goal-prompt editor with the Send button
    assets/icon.png         the owner's 32 by 32 icon, kept for a later overlay
  server/                   the Python MCP server
    pyproject.toml          uv project, package df_mcp, entry point df-mcp
    src/df_mcp/
      __init__.py
      wire.py               hand-rolled protobuf codec for the CoreProtocol messages we use
      dfhack_rpc.py         framing client for the DFHack remote server
      bridge.py             call(op, args) -> result, error mapping, reconnect
      server.py             MCPServer construction and transport
      tools/                one module per namespace, registers tools
      channel.py            event poller and channel notifications (Phase 13)
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
- Releases: tag `v<version>` (prerelease tags carry a hyphen, `v1.0.0-alpha`), `pyproject.toml` in PEP 440 form (`1.0.0a1`), `info.txt` `DISPLAYED_VERSION` matching the tag without the `v`. The tag push runs the release workflow (section 14).

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
8. Never read, write, or commit DF save folders or `dfhack-config` beyond the mod's own state file and the mod's own `claude-df/` working folder inside the current save (`goals.md` and `plan.md`, Phase 14), which the mod creates and owns. Never put ports, paths, or credentials in committed files; `.mcp.json` uses relative paths only. (Amended 2026-10-15.)
9. Branch per change, conventional commit messages, PR via `gh`. Do not commit to `main`. Every branch starts from `main`; stacking on another branch needs the owner's explicit permission. Once the owner has approved a branch's functions, Claude may merge its PR, but only after asking and getting a yes for that specific merge (agreed 2026-10-13). Reason: stacked branches make PR diffs and merge order depend on each other; the merge question keeps the owner in control of what lands on `main`.
10. When a feature lands, update the README progress section in the same PR. The README is for readers; this file is for builders.
11. Confirm before anything that affects a running game beyond reads: pausing, running console commands, or changing settings during a test session.
12. Any list that can grow large is capped at 25 entries by default, with a per-call `limit` to raise it and a `truncated` marker in the response. Reason: one call pauses the game and lands in Claude's context; an uncapped inventory or memory list can be thousands of rows.
13. Never write to texture or render cache fields on game structs (`*_texpos`, `texture_*`, anything df-structures marks transient or cached). Reason: resetting `squad.solid_texpos` and `blended_texpos` to make a new badge redraw crashed the game on 2026-10-15 (owner's rule). Change the data fields and let the game redraw.
14. `plan.md` in the save follows the template the Fortress-Planner skill defines (Status, Goals, Phases with numbered tasks and a state word, Standing rules, Log; rewrite near 48 KB). Development sessions that write the plan use the same template, and a change to the template edits the skill and this rule together. Reason: the release session has no CLAUDE.md and learns the shape from the skill alone; two shapes would make plans unreadable across sessions (owner's request, 2026-10-15).

---

## 7. Open items

- License chosen 2026-10-15: MIT, TheGraysonHarbison; written in Phase 20.
- The `package.loaded` route for `RunLua` is confirmed working in-game (2026-10-12).
- `gh` installed and authenticated on the dev machine on 2026-10-13; PRs and approved merges go through it.
- `.mcp.json` stays committed for development and is left out of the release zip; the player recreates it with `claude mcp add` (decided 2026-10-15, section 14).
- Channels (section 13) need the org Owner to enable Channels under Organization settings > Claude Code, and each session started with the development-channels flag until custom channels leave research preview.
- 13.1 petitions is not built; it ships as a README open issue (decided 2026-10-15).
- `MOD_VERSION` in `state.lua` (what `ping` reports) stayed at 0.3.0 through the Alpha 1.0.0 release while `info.txt` says 1.0.0-alpha; fixed in the first Patch 1 branch (section 15.2).
- The console allowlist and permissions are per machine; the release tests on 2026-10-16 left the allowlist empty, so a development session starts with `claude-bridge allow claude-bridge`.
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

## 13. Phases 10 to 18 addendum: farming, military, events, autonomy, trade (planned 2026-10-15)

Decisions agreed on 2026-10-15 after reading the DFHack 53.16-r2 install on the dev machine (the shipped Lua API text, `dfhack/buildings.lua`, the quickfort, caravan, notify, journal, petitions, ban-cooking, archery-practice, lever, and advfort scripts, the eventful and overlay plugin Lua), the df-structures `master` XML as of 2026-10-10, DFHack `master` C++ for Military, Items, Gui, EventManager, Persistence, Designations, autofarm, and createitem, the Claude Code docs on channels, hooks, and scheduled tasks, and the DF wiki pages named in the references. Rule of thumb from the owner: where DFHack has no API, the mod ships its own; where that proves impossible, the feature is skipped and listed under README open issues.

### 13.1 What DFHack and Claude Code give us

| Need | Source (checked 2026-10-15) |
|---|---|
| Push to Claude | Claude Code channels: an MCP server declares `capabilities.experimental["claude/channel"] = {}` and emits `notifications/claude/channel` with `content` (string) and `meta` (string map; keys become attributes of the `<channel source="dfhack" ...>` tag Claude sees). Events start a turn when Claude is idle and are queued and delivered together on the next turn when it is busy. Prerequisites: claude.ai or Console auth (not Bedrock or Vertex); a Team or Enterprise Owner enables Channels under Organization settings > Claude Code; the session is started with `claude --dangerously-load-development-channels server:dfhack` during the research preview (custom servers are not on the `--channels` allowlist) and confirms a warning dialog; the flag is ignored under `-p`. Events are dropped silently when the server is not loaded as a channel, and only arrive while the session is open. No acknowledgement, no documented queue limit. The Python `mcp` SDK 2.3.0 in `server/` negotiates the handshake versions Claude Code sends and exposes `outbound.notify(method, params)` on the connection; the server emits the notification as a JSON-RPC message on the stdio write stream from a background poll task. |
| Fallbacks (documented, not built) | A Stop hook can block the end of a turn with a reason when a queue is non-empty (eight consecutive blocks cap); `/loop` self-paces wakeups; `claude -p --resume <id> "<prompt>"` sends a prompt to a running session. |
| Kitchen | `dfhack.kitchen.findExclusion`, `addExclusion`, `removeExclusion(type, item_type, item_subtype, mat_type, mat_index)`, `type` one of `{Cook=true}` or `{Brew=true}` (Lua API 2645-2662), over `plotinfo.kitchen`'s parallel vectors (`df.plotinfo.xml:874-884`). Everything is allowed unless a row exists. Keys as `ban-cooking` uses them: seeds `(SEEDS, -1, seed material)`, plants `(PLANT, -1, basic material)`, growths with the growth index as subtype, drinks `(DRINK, -1, material)`. The vanilla screen lists only ingredients in stock. Cookable: material flag `EDIBLE_COOKED`; brewable: a `DRINK_MAT` reaction product on the material. |
| Farm plots | `building_farmplotst`: `plant_id[season]` (plant raw index, -1 fallow), `farm_flags.seasonal_fertilize`, `current_fertilization`, `max_fertilization`; no stored fertility. Placement (quickfort `build.lua:65-104`): tiletype material `SOIL` or any `GRASS_*` or `PLANT` with a floor-like shape, or any floor whose block has a solid `MUD` spatter event; sand, clay, loam, silt, peat are all `SOIL`. Above or below ground is the tile designation `subterranean` bit. Crop rule (autofarm.cpp 84-156): plant has the `SEED` flag and not `TREE`, carries the season flag for the current season and every season the crop spans, and a `BIOME_*` flag matching `dfhack.maps.getTileBiomeRgn` plus `getBiomeType` for surface plots or `BIOME_SUBTERRANEAN_WATER` below ground; seeds in `world.items.other.SEEDS`. Setting the crop is a direct write of `plant_id[season]` on a built plot (autofarm.cpp 197-207). `constructBuilding{type=FarmPlot, pos, width, height}` takes no items, any size, and queues a build job for a planter; `fields={farm_flags={seasonal_fertilize=true}}`. |
| Chop and gather | One designation value: `tile_dig_designation.Default` means dig, gather, or fell depending on the tile (`df.d_basics.xml:11025`); jobs `FellTree` and `GatherPlants` are designation jobs with `pos`. quickfort: trees through `dfhack.maps.getPlantAtTile` and the undocumented `dfhack.designations.markPlant(plant)` (which marks the south-east trunk tile at the base and sets the block flag), shrubs by setting `dig = Default` on `SHRUB` tiles; `isPlantMarked`, `unmarkPlant` also exist. Plants in `world.plants.all` with `material` (plant raw), `pos`, `tree_info` (nil for saplings), `damage_flags`. Saplings are neither chopped nor gathered. |
| Squads | `dfhack.military.makeSquad(assignment_id)` (needs a fort position assignment with `squad_id == -1`; creates `squad_size` empty positions and one schedule per routine in `plotinfo.alerts.routines`, no leader, uniforms, or ammo), `addToSquad(unit_id, squad_id, pos)` (refuses position 0 and occupied slots; `-1` picks the first free non-leader slot; sets the equipment update flags), `removeFromSquad(unit_id)` (handles the leader's assignment and position links), `updateRoomAssignments(squad_id, civzone_id, flags)`, `getSquadName` (Lua API 1973-1993, Military.cpp). No API for the leader slot, disbanding, or orders. `df.squad`: `alias` (display nickname), `positions[].occupant` (historical figure id; the unit is `df.historical_figure.find(id).unit_id`), `positions[].equipment.uniform[category]` of `squad_uniform_spec` (`item_type`, `item_subtype`, `material_class`, `mattype`, `matindex`, `indiv_choice`), `equipment.flags.replace_clothing`, `exact_matches`, `orders[]`, `schedule.routine[]`, `cur_routine_idx`, `ammo.ammunition[]` (`squad_ammo_spec` with `amount`, `use_combat`, `use_training`), `entity_id`, `leader_position`, `leader_assignment`. Orders: `squad_order_movest{pos}`, `squad_order_kill_listst{units, histfigs}`, `squad_order_patrol_routest{route_id}` over `plotinfo.waypoints`, `squad_order_trainst`, base fields `issuer_hf`, `recipient_hf`, `year`, `year_tick`. Routines are the four names Military.cpp knows (Off duty, Staggered training, Constant training, Ready). Presets live in `fortress_entity.uniforms[]`. Crossbow: `itemdef_weaponst.ranged_ammo ~= ""`. Only `addToSquad` sets `plotinfo.equipment.update`; the mod sets it after every uniform or ammo write. |
| Dev commands | `exterminate [list | undead | all[:caste] | <race>[:caste]] [-m METHOD] [-o] [-f] [-l n]`; `this` needs a selected unit. `modtools/create-unit -race X -caste Y -location [ x y z ] [-nick N] [-domesticate] [-civId \\LOCAL]`; `spawnunit` is a thin wrapper that needs a cursor unless given coordinates, and both are tagged unavailable for 53.16 in the docs though shipped. `modtools/create-item -i WEAPON:ITEM_WEAPON_PICK -m INORGANIC:IRON -c N -q 0..5 -u <unit> -p x,y,z`; the `createitem` plugin has no position option and needs a selected unit or cursor. All print little on success. |
| Announcements | `announcement_type` (357 items, `df.g_src.basics.xml` on master) with an `alert_type` attribute naming the left-side badge category. Flags (`df.d_init.xml:169-178`): `DO_MEGA`, `PAUSE`, `RECENTER`, `A_DISPLAY`, `D_DISPLAY`, `UNIT_COMBAT_REPORT`, `UNIT_COMBAT_REPORT_ALL_ACTIVE`, `ALERT`. `dfhack.gui.makeAnnouncement(type, flags, pos, text, color, bright)` creates a `df.report` (`type`, `text`, `color`, `pos`, `zoom_type`, `id`, `year`, `time`, `repeat_count`, `flags.announcement`); with `D_DISPLAY` it lands in the log and the left-side alert of its category; `PAUSE` and `RECENTER` act at creation; identical repeated text bumps `repeat_count` and creates no report. Icons come from the vanilla tile sheet per alert category (`graphics_announcements.txt`); no per-report icon exists. Text colours are the 16-colour palette; Steam defaults: light red 255,113,17, brown 215,155,45, yellow 255,225,17. Click-to-zoom uses `report.pos`; whether it works without `zoom_type` is a live check. |
| Event capture | `eventful.onReport(report_id)` fires for every new report, combat lines included; enable with `eventful.enableEvent(eventful.eventType.REPORT, freq)`. EventManager polls every frame gated on `world.frame_counter`, so frequency 0 runs while paused and frequency 1 or more never fires while paused. Also `onUnitDeath(unit_id)`, `onInvasion(invasion_id)`, `onUnitAttack(attacker, defender, wound)` (one call per unit pair per pass). Mapping of the wanted kinds: `STRUCK_MINERAL`, `STRUCK_ECONOMIC_MINERAL`; `FEATURE_DISCOVERY`; `STRUCK_DEEP_METAL`; `STRANGE_MOOD`, `MOOD_BUILDING_CLAIMED`; `MADE_ARTIFACT`, `NAMED_ARTIFACT`; `CRIME_WITNESS_STOLEN`, `CRIME_WITNESS_ITEM_MISSING`, `CRIME_WITNESS_ITEM_MOVED`, `CREATURE_STEALS_OBJECT`; `CITIZEN_MISSING`, `PET_MISSING`; `CITIZEN_DEATH` plus `onUnitDeath`; `CARAVAN_ARRIVAL`, `FIRST_CARAVAN_ARRIVAL`, `MERCHANTS_UNLOADING`, `MERCHANTS_NEED_DEPOT`, `MERCHANT_WAGONS_BYPASSED`; `MERCHANTS_LEAVING_SOON`, `MERCHANTS_EMBARKED`; `DIPLOMAT_ARRIVAL`, `LIAISON_ARRIVAL`, `TRADE_DIPLOMAT_ARRIVAL`; `MEGABEAST_ARRIVAL`, `WEREBEAST_ARRIVAL`, `BEAST_AMBUSH`, `AMBUSH_DEFENDER`, `AMBUSH_RESIDENT`, `UNDEAD_ATTACK`, `NAMED_RESIDENT_CREATURE`; `AMBUSH_AMBUSHER`, `AMBUSH_AMBUSHER_NATURE`, `AMBUSH_THIEF`, `AMBUSH_SNATCHER` plus `onInvasion`; `SEASON_SPRING` to `SEASON_WINTER`. No announcement exists for a petition, a ghost rising or being put to rest, a moody dwarf that cannot find an item, or an artifact being dug up: these are polled. |
| Timers | `dfhack.timeout(n, mode, fn)` modes `frames` (advance while paused), `ticks`, `days`, `months`, `years` (frozen while paused, cancelled on unload); `repeat-util.scheduleEvery(name, n, mode, fn)`; `dfhack.getTickCount()` real milliseconds; 1200 ticks a day, 33600 a month, 403200 a year; `df.global.cur_season`, `cur_year_tick`; `dfhack.world.ReadPauseState()`; `SC_PAUSED` and `SC_UNPAUSED` state-change codes exist but are undocumented. |
| Petitions | `plotinfo.petitions` holds the ids of unapproved agreements; `continuing_agreement_id` sits beside it. `df.agreement`: `parties[]` (`histfig_ids`, `entity_ids`), `details[]` with `type` (`Residency`, `Citizenship`, `Location`, and plot types) and `data` (`Residency.reason` from `history_event_reason`, such as `eradicate_beasts`, `entertain_people`, `make_a_living_as_a_warrior`, `study`; `Location.type`, `deity_type`, `deity_data`, `profession`, `tier`), `flags.petition_not_accepted` ("unset by accepting"), `flags.convicted_accepted`. `list-agreements.lua` is the text reference (party names, deity, profession, tier, one-year expiry). The vanilla answer buttons are mouse only, `petitions_interfacest` has no decision field, and no DFHack code accepts or rejects. |
| Files and editor | `dfhack.getSavePath()` (current save directory; the live value during play is a check), `dfhack.filesystem.mkdir_recursive`, `exists`, `listdir`, `mtime`; `plotinfo.site_id`; `dfhack.world.ReadWorldFolder()`. `widgets.TextArea` (multi-line editor with wrap, mouse selection, undo, clipboard, scrollbar; `init_text`, `on_text_change`, `getText`, `setText`; no read-only attribute) inside a `gui.ZScreen` as `gui/journal` does (`pass_pause=false` so Space types). |
| Trade | `plotinfo.caravans[]` (`caravan_state`: `trade_state` None, Approaching, AtDepot, Leaving, Stuck; `time_remaining` in ticks divided by 120 for days; `entity`; `flags` casualty, hardship, seized, offended, greatly_offended, tribute; `mood`; `buy_prices`, `sell_prices`). `building_tradedepotst.trade_flags` has only `trader_requested` and `anyone_can_trade`; the broker is the `BROKER` position (`dfhack.units.getUnitByNobleRole('broker')`); a request is that flag plus a `TradeAtDepot` job on the depot (the caravan script's cancel path). `dfhack.items.markForTrade(item, depot)` creates the `BringItemToDepot` hauling job; unmarking removes that job; `canTrade`, `canTradeWithContents`, `getValue(item, caravan)` (agreement prices applied), `isRequestedTradeGood`. The vanilla trade screen is `main_interface.trade` (`open`, `bld`, `mer`, `good[2]`, `goodflag[2].selected`, `stillunloading`, `havetalker`, `fortress_trader`, `merchant_trader`, `talkline`, `counter_offer`); DFHack's overlay only toggles `goodflag`; Trade, Offer, and Seize are mouse buttons with no key binding and no DFHack code presses them. Diplomats: `plotinfo.meeting_requests`, `dip_meeting_info[]` (`meeting_diplomat_info` with `sell_requests`, `buy_requests`, `events[]`), `main_interface.diplomacy` (`taking_requests`, `environment.dipev.sell_requests.priority[category][i]` 0 to 4 as `tradeagreement.lua` writes it, `selecting_land_holder_position`, `land_holder_*`). Responsibilities `RECEIVE_DIPLOMATS` and `MEET_WORKERS`. |
| Traps and depot | `dfhack/buildings.lua` inputs: lever, pressure plate, cage trap, stone-fall trap one mechanism; weapon trap mechanism plus one weapon; upright spike one spike; catapult three catapult parts, ballista three ballista parts; trade depot three building materials (5 by 5); siege engines 3 by 3; the rest 1 by 1. `building_trapst.plate_info` (`unit_min`, `unit_max`, `water_min`, `water_max`, `magma_min`, `magma_max`, `track_min`, `track_max`, flags `units`, `water`, `magma`, `citizens`, `resets`, `track`). Linking is the `LinkBuildingToTrigger` job with two mechanisms and trigger refs; the only writer is adventure-mode code, so it is skipped. |
| Mods | `script-manager.get_active_mods()` returns `{id, name, version, numeric_version, path, vanilla}` from `world.object_loader`; source by path prefix (`mods/` Workshop, `data/installed_mods/`, `data/vanilla/`). `dfhack.internal.listPlugins()`; enabled state from the `enable` command output. |

### 13.2 Decisions

| Question | Decision |
|---|---|
| Delivery (13, 14.1, 15) | Channels. The server declares the channel capability and, from a background task, polls `events.poll` every two seconds and emits one `notifications/claude/channel` per ready batch with `meta` `{kind, count, first_seq, last_seq}` and a readable `content` listing each event's kind, text, position, and ids. Goal updates and timer prompts are their own batches (`kind` `goals` and `timer`). The server keeps no buffer beyond the last sequence it forwarded; Claude Code's queue is the only buffer. The `.mcp.json` entry stays as is; the session is started with the development-channels flag documented in the README and `docs/playing.md`. The driver-loop design in 2.4 is replaced by this. |
| Poll cost | One `events.poll` every two seconds (a few milliseconds of core suspension each). The poll returns only events whose capture timestamp is at least two seconds old, or everything once 50 are queued, so batching needs no Lua timer. |
| Settings window | Rebuilt with tabs (Permissions, Events, Timer, Goals) and Enter-to-toggle lists; per-row hotkey letters are dropped. |
| Order of work | Phase number order, 10 to 18, one branch per item. |
| Tests | Every event kind gets a server test that feeds a recorded Lua batch and checks the channel content Claude receives, plus Lua-side `claude-bridge test` fixtures for event formatting; live checks happen as events occur naturally. Allowlisting `force` is the owner's option for a test session. |
| Kitchen (10.0) | `kitchen.list` groups in-stock ingredients as the game does (plants, seeds, drinks, other) with `cook` and `brew` allowed flags; `kitchen.set` takes an ingredient row key or a token (`PLANT:MUSHROOM_HELMET_PLUMP`, `SEEDS:...`, `DRINK:...`) and `cook`, `brew` booleans. New `kitchen_write` toggle (Items group); the read is under `stocks`. |
| Farm plots (10.1) | `farms.list` and `farms.get` (soil report per plot: soil type from the 6.0 material lookup, mud, above or below ground, cavern, biome, and the note that underground soil outside a cavern yields less), crops per season with the plantable list and seed counts. `build.place` gains `farm_plot` with a box (up to 31 by 31); tiles failing the soil-or-mud rule are cut from the extents and reported. `farms.set_crops` writes `plant_id[season]` for a built plot and `seasonal_fertilize`; a crop not on the plantable list is `BAD_REQUEST` with the list. All writes under `build_write`. The autofarm approximation is stated in the tool description. |
| Chop and gather (10.2) | `dig.designate` kinds `chop` (every tree whose base is in the box or circle, through `markPlant`) and `gather` (every shrub tile). `map.plants` lists trees and shrubs in a box with species, kind, size, dead flag, marked state, capped at 25. `dig.erase` gains the same kinds through `unmarkPlant`. |
| Squads (11.0) | `military.list`, `military.get`; `military.create` with `name`, `kind` (`melee`: armor with individual melee weapon choice; `crossbow`: crossbow, quiver, leather armor, bolts with combat and training ammo) or `preset` (a `fortress_entity.uniforms` name), using the first vacant military position assignment; `military.rename` sets `alias`; `military.add` and `military.remove` wrap the API; `military.set_leader` is the mod's own (occupant and unit fields for slot 0, assignment `histfig`, position link, as the inverse of `removeFromSquad`'s leader path); `military.disband` removes every member including the leader, clears the assignment, rooms, and ammo links, and erases the squad from `fortress_entity.squads` and `world.squads.all`. Both are verified live against the game's own squad screen before merge. |
| Orders (11.1) | `military.order` with `kind` `station` (`pos`), `kill` (`unit_ids`), `patrol` (`route_id`), and `cancel`; `military.set_routine` with one of the four routine names; `military.routes` to list waypoint routes and `military.create_route` from a list of points. Orders are written into `squad.orders` with `issuer_hf`, `year`, `year_tick` filled from the fort; the first live test compares a station order to one issued in the game and the branch does not merge until the squad moves. Defend-burrow and per-month schedules are deferred. |
| Equipment (11.2) | `military.equipment` returns the uniform spec per category, each soldier's worn and assigned items, and ammunition. `military.set_uniform` takes `category`, `item_type` by plain name (`breastplate`, `helm`, `crossbow`), `material_class` (`any`, `metal`, `leather`, `cloth`, `wood`), `exact_matches`, `replace_clothing`, and an optional `position`; `military.set_ammo` takes `item`, `material_class`, `amount`, `combat`, `training`. Never a specific item id. Every write sets `squad.ammo.update` and `plotinfo.equipment.update`. |
| Dev tools (12) | Tools `dev_spawn_unit(race, caste, x, y, z, nickname, domesticate)`, `dev_create_item(item, material, count, quality, x, y, z)`, `dev_exterminate(target, method, include_friendly, only_visible, limit)` compose the command lines above and call `console.run`, so each needs its command on the allowlist and the `console` toggle. `include_friendly` defaults to false. Guidance in the tool descriptions and the server instructions. |
| Event kinds (13) | Kinds and sources: `mineral_discovered`, `cavern_discovered`, `adamantine_found`, `artifact_created`, `strange_mood`, `artifact_stolen_or_missing`, `citizen_missing`, `citizen_dead`, `caravan_arrived`, `caravan_leaving`, `diplomat_arrived`, `monster_arrived`, `invaders_arrived`, `season_changed` from announcements; `units_fighting` from `onUnitAttack` deduplicated per unit pair for the batch window; `sparring` the same when both units are fort-controlled, its own kind, off by default; `mood_item_missing` from polling strange-mood jobs the way `notify` does; `ghost_appeared` and `ghost_rested` from a polled ghost set; `artifact_found` from polling artifact items on the map whose tile turns from hidden to revealed; `petition` from polling `plotinfo.petitions`. Each event: `{seq, kind, tick, text, pos, unit_ids, building_id, item_id}`. Defaults on: `mineral_discovered`, `units_fighting`, `petition`. The Lua ring keeps 200 events. |
| Petitions (13.1) | `petitions.list` with applicant, kind, reason, location type and deity or profession, tier, age, and obligation text; `petitions.answer` with `accept` true or false. The mod's implementation clears `petition_not_accepted` and moves the id from `plotinfo.petitions` to `continuing_agreement_id` on accept, and sets the flag and drops the id on reject; what else the game writes is learned by watching one vanilla accept and one reject with `devel/datamine` before the branch is written. If the game does not honour the writes (the applicant never becomes a resident, or the location obligation never appears), the write ships disabled and goes to the README open issues. |
| Files (14.0) | `claude-df/` inside the current save (`dfhack.getSavePath()`), created on enable with empty `goals.md` and `plan.md`. `plan.read`, `plan.write` (whole file), `plan.append` (a section), 64 KB cap, under a `plan` toggle (on). `goals.read` under the same toggle. Rule 8 is amended to allow this folder. The live path during play (working folder versus region folder) is the first check of the branch. |
| Goals window (14.0) | `claude-bridge goals`: a TextArea for goals, a TextArea for the prompt template (default as given, with `{Put Goals Here}` as the placeholder), saved to `goals.md` and the settings file on every change, and a Send hotkey that queues a `goals` batch whose content is the template with the goals substituted. Nothing is sent on edit or close. |
| Messages (14.2) | `messages.say(text, x, y, z)` under no permission: at most 200 characters, `makeAnnouncement` with `D_DISPLAY` and a general-category type, colour light red, bright. With a position it sets `report.pos` so the alert zooms there on click; the first live test decides whether `zoom_type` must also be set. No pause, no immediate recenter. The icon is the vanilla badge of the chosen category; if the general badge does not stand out the branch picks another category's type whose badge does. The owner's `icon.png` is kept in `mod/assets/` for a later overlay. |
| Timer (15) | Settings: `mode` (`days`, `month`, `minutes`), `interval`, `prompt`; off by default, 7 days when enabled, default prompt as given. Days and month run on `ticks` repeats; minutes on a `frames` repeat that counts real milliseconds only while unpaused. Every event batch the mod hands out resets the timer. One pending timer prompt at a time. |
| Traps (16) | `build.place` types `lever`, `pressure_plate`, `cage_trap`, `stone_fall_trap`, `weapon_trap`, `upright_spike`, `catapult`, `ballista`, `trade_depot`, with the input tables above; `pressure_plate` takes the trigger settings as arguments. Lever linking, pulling, and multi-weapon traps are skipped and listed as open issues. Whether a cage trap gets its cage loaded after construction is a live check. |
| Trade (17.0) | `trade.caravans` (state, civ, days remaining, mood, flags), `trade.depot` (built, accessible, broker requested, anyone may trade, goods at depot and pending), `trade.broker` (who, where, at the depot or not). `trade.request_broker` sets `trader_requested` and, if the game does not queue it, creates the `TradeAtDepot` job the way `markForTrade` creates its job. `trade.bring` marks items by id or by the same filters as `stocks.find`, through `markForTrade`; `trade.unbring` removes the job. `trade.offer` is the mod's own: it validates that the caravan is at the depot and the broker present, computes both sides with `getValue(item, caravan)`, applies the merchant acceptance rule (no loss, the wiki's margin, the caravan's mood), and then first tries to drive the game's own screen (open `main_interface.trade` with the depot and caravan, set `goodflag` selections, press Trade by simulated mouse input) and, if the screen cannot be driven headlessly, performs the exchange itself (ownership and `trader` flags, depot placement, `import_value`, `export_value_total`, exported wealth, caravan mood). Elven and animal ethics are checked before offering. If neither route works live, the feature goes to open issues with the reads and hauling kept. |
| Diplomats (17.1) | `trade.diplomats` (who is waiting, for whom, the civ, the open meeting, the agreements from the meeting's `events` and later `meeting_events`), `trade.request_options` (every request category with item names from the civ's resources), `trade.set_requests` writes `sell_requests.priority` per category while the meeting's Requests step is open. Built 2026-10-15. `trade.meet` (headless meeting) and storing requests before the screen opens were deferred by the owner with the headless trade screen; the player clicks through the meeting. |
| Mods (18) | `settings.mods` lists DF mods with id, name, version, source, and DFHack plugins with enabled state; under `settings`. |
| Permissions | New toggles: `kitchen_write` (Items), `military` and `military_write` (Units), `events` (General), `petitions_write` (Units), `plan` (General), `trade` and `trade_write` (Logistics). No toggle for messages, dev tools (allowlist), or mods. Timer, event kinds, and the goal prompt live on their own tabs. |
| List caps | 25 by default everywhere, raised per call with `limit` (rule 12). |

### 13.3 Ops by item

| Item | Ops | Tools |
|---|---|---|
| 10.0 | `kitchen.list`, `kitchen.set` | `list_kitchen`, `set_kitchen` |
| 10.1 | `farms.list`, `farms.get`, `farms.set_crops`, `build.place(type=farm_plot)` | `list_farms`, `get_farm`, `set_farm_crops`, `place_furniture` |
| 10.2 | `map.plants`, `dig.designate` and `dig.erase` kinds `chop`, `gather` | `list_plants`, `designate_dig`, `erase_designations` |
| 11.0 | `military.list`, `military.get`, `military.create`, `military.rename`, `military.add`, `military.remove`, `military.set_leader`, `military.disband` | `list_squads`, `get_squad`, `create_squad`, `rename_squad`, `add_to_squad`, `remove_from_squad`, `set_squad_leader`, `disband_squad` |
| 11.1 | `military.order`, `military.set_routine`, `military.routes`, `military.create_route` | `order_squad`, `set_squad_routine`, `list_routes`, `create_route` |
| 11.2 | `military.equipment`, `military.set_uniform`, `military.set_ammo` | `get_squad_equipment`, `set_squad_uniform`, `set_squad_ammo` |
| 12 | `console.run` | `dev_spawn_unit`, `dev_create_item`, `dev_exterminate` |
| 13 | `events.poll`, `events.kinds` | channel notifications; `list_event_kinds` |
| 13.1 | `petitions.list`, `petitions.answer` | `list_petitions`, `answer_petition` |
| 14.0 | `plan.read`, `plan.write`, `plan.append`, `goals.read` | `read_plan`, `write_plan`, `append_plan`, `read_goals` |
| 14.2 | `messages.say` | `send_message` |
| 15 | `events.poll` carries `timer` batches; settings only | none |
| 16 | `build.place` new types | `place_furniture` |
| 17.0 | `trade.caravans`, `trade.depot`, `trade.broker`, `trade.request_broker`, `trade.bring`, `trade.unbring`, `trade.offer` | `list_caravans`, `get_trade_depot`, `get_broker`, `request_broker`, `bring_to_depot`, `cancel_bring`, `offer_trade` |
| 17.1 | `trade.diplomats`, `trade.request_options`, `trade.set_requests` | `list_diplomats`, `get_trade_request_options`, `set_trade_requests` (`hold_meeting` deferred) |
| 18 | `settings.mods` | `list_mods` |

Channel content for an event batch: a header line with the fort name, date, and count, then one line per event: `[kind] text (x,y,z) unit 123`. A goals batch is the template with the goals substituted. A timer batch is the prompt text.

### 13.4 In-game checks before or during implementation

Recorded in `docs/decisions/0006-phases-10-18.md` as they are done.

1. Channels: the org setting is on, the development flag loads the server, a notification sent before any tool call reaches Claude, and an idle session starts a turn on it.
2. `dfhack.getSavePath()` during play, and that files written there survive a save.
3. A vanilla squad creation, leader assignment, and disband watched with `devel/datamine` (assignment, links, routine index, symbol); a vanilla station order compared with the mod's.
4. A vanilla petition accept and reject watched the same way.
5. `markPlant` on a mushroom-cap tree; `GatherPlants` jobs carry `pos`.
6. `plant_id` writes on a plot take effect; the game's plantable list versus the autofarm rule on a surface plot and an underground plot.
7. `modtools/create-unit` and `create-item` work on 53.16 from the remote console.
8. `makeAnnouncement` with `D_DISPLAY`: the badge shown, click-to-zoom with and without `zoom_type`, text colour in the box.
9. Cage trap and stone-fall trap built through the bridge get their loading jobs.
10. `trader_requested` alone queues `TradeAtDepot`; the trade screen can be opened and its Trade button pressed headlessly; the diplomacy screen likewise.
11. The announcement types for a ghost rising, a ghost put to rest, a corpse found, and a siege, read from `world.status.reports` when they occur.

### 13.5 Delivery

One branch per item from `main`, in phase order, each verified live and updating `docs/protocol.md`, the README progress table, and the smoke test: `mod/kitchen` (10.0), `mod/farms` (10.1), `mod/plants` (10.2), `mod/squads` (11.0), `mod/squad-orders` (11.1), `mod/squad-equipment` (11.2), `server/dev-tools` (12), `mod/events` (13, with the server's channel support and `docs/playing.md`), `mod/petitions` (13.1), `mod/plan-goals` (14.0), `mod/messages` (14.2), `mod/timer` (15), `mod/traps` (16), `mod/trade` (17.0), `mod/diplomats` (17.1), `mod/mods` (18). 14.1 is satisfied by the 13 branch and gets a README row. Protocol version bumps on each, starting at 11.

---

## 14. Phases 19 to 21 addendum: skills, final touches, release (planned 2026-10-15)

Decisions agreed on 2026-10-15 after a retrospective of Phases 0 to 18 (124 commits, 54 PRs, protocol 24 with 106 ops, 105 server tests, every phase verified live except 13.1 petitions) and a read of the Claude Code docs on skills, plugins, sub-agents, MCP configuration, memory files, and channels. No game session is needed for these phases. The release is a zip the player extracts; the player installs the Python dependencies, links the mod, adds the MCP server and the skills by hand with the commands the README gives, and starts Claude Code with the channel flag. `CLAUDE.md` does not ship, so the skills carry everything Claude must know to run a fort.

### 14.1 What Claude Code gives us

| Need | Source (checked 2026-10-15) |
|---|---|
| Skill discovery | Skills load only from `<project>/.claude/skills/<name>/SKILL.md`, `~/.claude/skills/<name>/SKILL.md`, a directory added with `--add-dir` that holds the same `.claude/skills` layout, or a plugin's skills folders. A flat `<name>.md` is never a skill. Each skill is a folder with a `SKILL.md`; sibling files are referenced by relative links and `${CLAUDE_SKILL_DIR}`. Keep `SKILL.md` under 500 lines. The description (plus `when_to_use`) is always in context and drives auto-triggering, cut at 1,536 characters; the body loads on invocation. Frontmatter fields all optional: `name`, `description`, `when_to_use`, `allowed-tools`, `disallowed-tools`, `model`, `effort`, `context` (`fork`), `agent`, `disable-model-invocation`, `user-invocable`, `paths`, `metadata`. https://code.claude.com/docs/en/skills |
| Plugins | A plugin root holds `.claude-plugin/plugin.json`; `"skills": ["./<folder>/"]` adds a skills folder, `agents/` ships sub-agent files, and a plugin may carry its own `.mcp.json`. Load per session with `claude --plugin-dir <folder>`; install persistently with `claude plugin marketplace add <folder>` (the folder holds `.claude-plugin/marketplace.json`) then `claude plugin install <plugin>@<marketplace> --scope project`. Plugin skills appear as `/<plugin>:<skill>`. A `CLAUDE.md` at a plugin root is not loaded. https://code.claude.com/docs/en/plugins/create , https://code.claude.com/docs/en/plugins/manifest-reference , https://code.claude.com/docs/en/plugins/install |
| Model routing | Sub-agent files (`.claude/agents/*.md` or a plugin's `agents/`) take `name`, `description`, and optional `model` (`haiku`, `sonnet`, `opus`, `fable`, `inherit`), `tools`, `disallowedTools`, `mcpServers`, `skills`, `maxTurns`, `effort`. Sub-agents inherit the parent's MCP tools, so the dfhack tools are available to them. The Agent tool's per-call `model` beats the file's `model`, which beats `CLAUDE_CODE_SUBAGENT_MODEL`, which beats the session model. No documented "orchestrator plus cheap workers" pattern; it is built from these pieces. https://code.claude.com/docs/en/sub-agents |
| MCP enablement | `claude mcp add --transport stdio --scope project dfhack -- uv run --project server df-mcp` writes `.mcp.json` in the current folder; the next interactive session shows the approval prompt. `enabledMcpjsonServers` in `.claude/settings.local.json` records the approval. `claude mcp reset-project-choices` clears it. https://code.claude.com/docs/en/mcp |
| Channels | Still research preview. `claude --dangerously-load-development-channels server:dfhack` on every launch, with a confirmation screen each time; no settings key replaces it; ignored under `-p`. Team and Enterprise Owners turn on Channels under Organization settings > Claude Code (`channelsEnabled` managed setting); Pro and Max accounts without an organization skip that check; Bedrock, Vertex, and Foundry cannot use channels. https://code.claude.com/docs/en/channels , https://code.claude.com/docs/en/channels-reference |
| Memory files | `CLAUDE.md`, `.claude/CLAUDE.md`, `CLAUDE.local.md`, `.claude/rules/*.md` are read at launch; skills load on demand. The docs recommend skills for multi-step procedures and area-specific knowledge and `CLAUDE.md` for always-true rules. https://code.claude.com/docs/en/memory |
| Release packaging | A GitHub Actions workflow on a `v*` tag push can run the tests, zip an explicit list of paths, and attach the zip to a draft release with `gh release create --draft`; a tag with a hyphen (`v1.0.0-alpha`) is marked prerelease. GitHub's own "Source code" archives are not used, so nothing depends on `.gitattributes`. |

### 14.2 Decisions

| Question | Decision |
|---|---|
| Where the skills live | `df-skills/` at the repository root is a Claude Code plugin named `claude-df`: `df-skills/.claude-plugin/plugin.json` and `marketplace.json`, `df-skills/skills/<name>/SKILL.md` for each skill, `df-skills/agents/<name>.md` for the worker sub-agents. The player adds it with the commands in the README (`claude plugin marketplace add ./df-skills`, then `claude plugin install claude-df@claude-df --scope project`); `claude --plugin-dir df-skills` is the documented fallback if the marketplace route misbehaves on the player's Claude Code. The exact layout and commands are confirmed on the dev machine with DF off before the README is written. Nothing is copied into `.claude/skills/`, so the repo's own `.claude/` stays development-only. |
| Triggering | The three skills auto-trigger from their descriptions, which name the situations (a fort session starts, a goals or timer batch arrives, work can be split, a game rule is in question). Each is also user-invocable. The README describes every skill so the player knows what each does. |
| Autonomy | Claude acts freely within the permissions the player enabled and reports with `send_message` after each batch of changes and whenever a decision is the player's. No chat confirmation before writes. The skills say so; CLAUDE.md rule 11 stays a development-session rule and does not ship. |
| Worker models and tools | Three roles. Manager: the session model, Opus or better; if Claude finds itself on Sonnet or Haiku it recommends `/model opus` once and carries on. Steward (`df-skills/agents/df-steward.md`, `model: sonnet`): medium judgment such as weighing a trade, choosing crops and kitchen bans, reading unit sheets and summarising mood or health, composing a squad and its uniform. Scout (`df-skills/agents/df-scout.md`, `model: haiku`): sorting and filtering lists, map and wall surveys, tile walks, counting stock, and bulk placement of orders, designations, stockpiles, and constructions from exact specs the manager wrote. Both workers get every tool (owner's choice, 2026-10-15). The manager alone writes `plan.md`, reads channel batches, talks to the player in chat, and sends in-game messages, so the fort speaks with one voice. |
| Briefing workers | The Work-Subdivision skill fixes the brief shape: goal in one sentence, the ids and coordinates and permissions already known, the exact tool calls or shapes expected, the `limit` to use, the output format (a short table or list, never raw dumps), and the stop rule. Independent surveys run as parallel scouts. The manager never re-runs a delegated survey itself. |
| Plan file template | `plan.md` has a fixed shape the Fortress-Planner skill defines: a `Status` line (fort name, date, population, last updated); `Goals` (the player's goals restated, from `read_goals`); `Phases`, each with a one-line aim and numbered tasks carrying a state word (`todo`, `active`, `done`, `blocked`) and, where it matters, the coordinates and ids; `Standing rules` (what this fort has taught Claude, and player instructions that persist); `Log`, dated entries added with `append_plan`. Rewrite with `write_plan` when the file passes about 48 KB of the 64 KB cap, folding the log into the rules. The same template becomes CLAUDE.md rule 14 for development sessions (owner's request). |
| Planning cadence | At session start: `ping`, `get_permissions`, `get_time`, `read_goals`, `read_plan`, `get_fort_status`, `list_citizens`, `get_stock_bar`, then plan or re-plan. Re-plan on a goals batch, at a season change, and whenever the timer fires with no active task left. Pause the game with `set_paused` while planning when `pause_write` is on, and unpause when the plan is written. Long-term first: the plan runs seasons ahead and is divided into phases and tasks; the current phase is the only one with fine detail. |
| Fortress-Quirks content | One skill, sections kept short, with sibling files when a section outgrows it: every call pauses the game briefly, so batch reads and use `limit` rather than paging; the 25-row default cap and the `truncated` marker; dwarves move diagonally, so rooms need fully solid borders including corners and one wall between rooms and corridors; stairs and ramps as the only z-links, roof floors need a ramp or stair, tree canopies block them; soil versus stone layers, what counts as mud, underground farms outside caverns yield less, crops are set only after the plot is built; a designation job without a worker is normal and the tile flag clears when the job is created; constructed walls versus natural; furniture needs the item first and the refusal names the work order; work orders need a manager, trade needs a broker and a depot, the Trade button and the liaison meeting stay with the player; squads start with symbol 0, badges may lag, routines and ammo semantics; never touch texture or render cache fields, which crashed the game (owner: "just in case"); names in CP437 with the English surname in quotes; events and timer semantics, the two-second batches, the fallback `poll_events` loop; early-fort priorities (shelter, food and drink, stockpiles, a manager, a bookkeeper, a broker); the known open issues (petitions, headless trade, meetings, lever linking, unit spawning). Plus a troubleshooting section built from `docs/playing.md`: `MOD_NOT_ENABLED` means `enable claude-bridge`; `NOT_ALLOWED` names the toggle to ask for; events that never arrive mean the session lacks the channel flag or the organization switch, with the log path to check, and `poll_events` with `/loop` until it is fixed. |
| License | MIT, `Copyright (c) 2026 TheGraysonHarbison`, in `LICENSE` at the root; `pyproject.toml` already says MIT. |
| README shape | In order: title and description (copy-edited), Requirements (Dwarf Fortress 53.16 Steam, DFHack 53.16-r2, Python 3.11 or newer with uv, Claude Code with a claude.ai login; channels need a Team or Enterprise organization with Channels on, Pro and Max accounts without an organization skip that; Bedrock, Vertex, and Foundry cannot push events), Installation (the seven steps below), Playing (the per-session parts of `docs/playing.md`: load the fort, start the session with the flag, ping, the prompt timer, playing without the channel), Settings (the settings and goals windows, permissions, console allowlist, events, timer), Skills (what each of the three does and the two worker agents), Known bugs and open issues, then Resources, the Feature list, and the Progress table as the record for readers who want it. No tool script for the launch; the commands and what they do are written out. No Windows variant of `link-mod.sh`. `server/README.md` and `mod/README.md` are left alone. |
| Installation steps | 1. Download `claude-bridge-<version>.zip` from the Releases page, extract it, open a terminal in the folder, and keep the folder where it is afterwards (the link step writes its path). 2. `uv sync --project server` to install the Python dependencies. 3. `tools/link-mod.sh <Dwarf Fortress folder>`, which adds the mod's scripts folder to DFHack's `script-paths.txt`; the game is assumed installed. 4. Start Dwarf Fortress, load or create a fort, and in the DFHack console run `enable claude-bridge`, then `claude-bridge status`. 5. `claude-bridge settings` to turn on what Claude may do, the console allowlist, event kinds, and the timer; `claude-bridge goals` to write goals. 6. In the extracted folder: add the server with `claude mcp add --transport stdio --scope project dfhack -- uv run --project server df-mcp` (the server carries experimental Claude Code features and is added by hand); add the skills with the two plugin commands; start `claude --dangerously-load-development-channels server:dfhack`, approve the project server when asked, and confirm the channel warning; an Owner enables Channels in the organization settings first. 7. Ask Claude to `ping`, then play. |
| Release config | `.github/workflows/release.yml`, triggered by a pushed tag matching `v*` (and by hand through `workflow_dispatch` for a dry run). Steps: check out, install uv, `uv sync --project server`, `uv run --project server ruff check server`, `uv run --project server pytest`, then build `claude-bridge-<tag>.zip` from an explicit include list: `LICENSE`, `README.md`, `server/` (with `tests/` and `uv.lock`, without `.venv`, `__pycache__`, `.pytest_cache`, `.ruff_cache`), `mod/`, `tools/` (with `smoke-test.py`), `df-skills/`, and `.gitignore`. Never included: `CLAUDE.md`, `docs/`, `.mcp.json`, `.claude/`, `.github/`, caches. The workflow creates a draft release for the tag with the zip attached, prerelease when the tag has a hyphen; the owner edits and publishes it. The zip's top-level folder is `claude-bridge-<tag>/`. |
| Version and tag | First release is "Alpha 1.0.0": tag `v1.0.0-alpha`, release title `Alpha 1.0.0`, `server/pyproject.toml` version `1.0.0a1` (PEP 440), `mod/info.txt` `DISPLAYED_VERSION` `1.0.0-alpha`; `NUMERIC_VERSION` stays 3 because the protocol stays 24. The bumps and the tag are Phase 21, done by the owner. |
| 13.1 petitions | Not built for the release. Its README row moves to the open issues list (the reads and the mod-side answer remain future work) and the plan keeps section 13's design. |
| `.mcp.json` | Stays committed for development (section 7's open question closes) and is excluded from the zip; the player recreates it with `claude mcp add`. |
| Phase 21 | Owner's phase: version bumps, the tag push that runs the workflow, the extra tests, extraction of the zip into an empty folder and a walk through the seven install steps, and publishing the draft release. Claude's part is limited to answering questions and fixing what the walk-through finds, each fix on its own branch. |

### 14.3 Deliverables by item

| Item | Files | Notes |
|---|---|---|
| 19 | `df-skills/.claude-plugin/plugin.json`, `df-skills/.claude-plugin/marketplace.json`, `df-skills/skills/fortress-planner/SKILL.md`, `df-skills/skills/work-subdivision/SKILL.md`, `df-skills/skills/fortress-quirks/SKILL.md` (plus sibling reference files if a section outgrows 500 lines), `df-skills/agents/df-scout.md`, `df-skills/agents/df-steward.md`, `df-skills/README.md` (one paragraph per skill and agent, reused by the root README), `CLAUDE.md` rule 14, README progress row | Frontmatter: `name`, `description` with the trigger first, `when_to_use`; no `model` on the skills (the manager is the session model); the agents carry `model`, `description`, and a body that restates the brief shape and the one-voice rule. Skill text uses the MCP tool names as the server registers them. |
| 20 | `LICENSE`, `README.md` reordered and extended (Requirements, Installation, Playing, Settings, Skills), `docs/playing.md` trimmed to development notes or deleted once its content lives in the README and the quirks skill, README progress rows | Copy-edit the description paragraph (bridge, analysing, prompts, months) while there. Petitions row becomes an open issue. |
| 20.1 | `.github/workflows/release.yml`, README progress row | Include list as decided; tests and lint gate the zip; draft release. A `workflow_dispatch` run on the branch proves the zip contents before merge (the artifact is downloaded and listed in the PR). |
| 21 | version bumps, tag, published release | Owner. |

### 14.4 Checks before or during implementation

1. On the dev machine with DF off: `claude plugin marketplace add ./df-skills` and `claude plugin install claude-df@claude-df --scope project` succeed, the three skills show in the skills listing with their descriptions, `/claude-df:fortress-planner` invokes, and the two agents are offered to the Agent tool with their models. If the single-folder marketplace is refused, the plugin moves to `df-skills/claude-df/` under a marketplace at `df-skills/`, and the README commands follow.
2. A fresh folder with only the release contents: `uv sync --project server` works offline from `uv.lock` after the first run, `claude mcp add ...` writes a `.mcp.json` whose command is `uv run --project server df-mcp` with no absolute path, and the session's approval prompt names `dfhack`.
3. A `workflow_dispatch` run of the release workflow on the branch: the zip holds exactly the include list, no `CLAUDE.md`, `docs/`, `.mcp.json`, or caches, and the top-level folder is named after the tag.
4. The skills, read cold by a fresh session with no CLAUDE.md, lead Claude to ping, read goals and plan, and write a plan in the template; checked by the owner in Phase 21 with the game running.

### 14.5 Delivery

Three branches from `main`, in order, one PR each, merged after the owner's yes: `skills/release-skills` (19, scope `skills` is new and accepted), `docs/release-prep` (20: `LICENSE` as a `repo` commit and the README as a `docs` commit on the same branch), `repo/release-workflow` (20.1). Each PR updates the README progress section. Phase 21 is the owner's and ends the first release.

---

## 15. Patch 1 addendum: labor, migrants, screens, popups, hotkeys (planned 2026-10-16)

The first live patch after Alpha 1.0.0, planned on 2026-10-16 from the owner's list of seven items and a round of design questions. Items are numbered P1.0 to P5.0 to keep clear of the original Phases 1 to 5; P6.0 is the owner's release. Two of them (P2.0, P3.0) drive game screens that until now were "the player's" (section 13: headless trade and the liaison meeting were deferred). Research used df-structures master as of 2026-10-16, the Lua API text shipped with DFHack 53.16-r2, the DFHack scripts shipped with it, the game's own `data/init/announcements.txt`, and a read-only probe of the running game.

### 15.1 What DFHack and the game give us

| Need | Source (checked 2026-10-16) |
|---|---|
| Labor model (P1.0) | Since v50 the game drives labors from work details: `plotinfo.labor_info.work_details[]` (`work_detail`: `name`, `flags` with `no_modify`, `cannot_be_everybody`, and a two-bit `mode` enum `Default`, `EverybodyDoesThis`, `NobodyDoesThis`, `OnlySelectedDoesThis`; `assigned_units` sorted unit ids; `allowed_labors[94]` indexed by `unit_labor`; `icon`). DFHack's `gui/manipulator` toggles `assigned_units` and then calls `dfhack.units.setAutomaticProfessions(unit)`, documented as "set appropriate labors on a unit based on current work detail settings"; it is present in the 53.16-r2 Lua API. Writing `unit.status.labors` directly is overwritten by the game (which is why `autolabor` is unsupported on v50). `df.plotinfo.xml`, `hack/scripts/gui/manipulator.lua`, `hack/docs/docs/dev/Lua API.txt` (units section). |
| Default details (probe) | The running fort has eleven details, all `no_modify`: Miners, Woodcutters, Hunters, Fisherdwarves (each `cannot_be_everybody`, mode `OnlySelectedDoesThis`, one labor), Planters, Plant gatherers, Stonecutters, Engravers, Haulers (11 labors), Orderlies (4), Siege operators (each `EverybodyDoesThis`). 94 labors. `labor_info.flags.children_do_chores` was on. |
| Seeds (P1.1) | Game rules from the wiki and section 13: a planted tile consumes one seed; seeds return from eating raw plants and from brewing, never from cooking; the game bans cooking seeds by default; each seed type caps at 200 in the fort; caravans sell seeds and the liaison request list has a seeds category; `get_farm` already lists plantable crops with seed counts and `season_changed` is an existing event kind. |
| Migrant announcements (P1.2) | `announcement_type` has `MIGRANT_ARRIVAL` (50), `MIGRANT_ARRIVAL_NAMED` (49), `D_MIGRANTS_ARRIVAL` (69), `D_MIGRANT_ARRIVAL` (70), `D_MIGRANT_ARRIVAL_DISCOURAGED` (71), `D_NO_MIGRANT_ARRIVAL` (72); all six exist on 53.16-r2 (probe), all carry alert type `MIGRANT`, none is a box popup. The report carries text and position but no unit ids; new citizens are found by diffing `dfhack.units.getCitizens(true)` against the previous poll. `df.g_src.basics.xml`, `data/init/announcements.txt`. |
| Trade screen (P2.0) | `game.main_interface.trade` (`trade_interfacest`): `open`, `choosing_merchant`, `merlist`, `title`, `talker`, `fortname`, `place`, `st`, `bld` (depot), `mer` (caravan), `civ`, `stillunloading`, `havetalker`, `merchant_trader`, `fortress_trader`, `good[2]`, `goodflag[2]`, `good_amount[2]`, type lists, `talkline` (the reply), `buildlists`, `handle_appraisal`, `counter_offer`, `counter_offer_item`, `entering_amount`, `big_announce` (the merchant's words). The Trade, Offer, and Seize buttons have no key binding and no state flag: DFHack's `confirm` plugin intercepts them by interface frame (`trade-confirm-trade` `{l=0, r=23, b=4, w=11, h=3}`, `trade-offer` `{l=40, r=5, b=4, w=19, h=3}`, `trade-seize` `{l=0, r=73, b=4, w=11, h=3}`, context `dwarfmode/Trade/Default`), which proves they are click handlers. `gui.simulateInput(screen, keys)` is the documented way to feed keys and `_MOUSE_L` to a viewscreen, with `df.global.gps.mouse_x`/`mouse_y` set for interface clicks; `gui.get_interface_rect()` resolves frames against the interface area. `df.d_interface.xml`, `hack/scripts/internal/confirm/specs.lua`, `hack/scripts/internal/caravan/trade.lua`, Lua API `simulateInput`. |
| Diplomacy dialog (P3.0) | `game.main_interface.diplomacy` (`diplomacy_interfacest`): `open`, `mm` (`dipscript_popup`: actor and noble unit ids, activity, `close_screen` and `new_screen` flags, `moment_time_left`), `actor`, `target`, `flag.in_the_middle_of_stuff`, `text` (`markup_text_boxst`: `word[]` with `str`, colour, `px`, `py`, and `NEW_LINE`, `BLANK_LINE`, `INDENT` flags), `selecting_land_holder_position`, `taking_requests`, land-holder vectors (`land_holder_pos_id`, `land_holder_assigned_hfid`, `land_holder_avail_hfid`, `land_holder_selected_pos`), the request tabs, `dipev` (`meeting_diplomat_info`: `dipscript` with its `script.steps`, `cur_step`, `active_script_vars`, `sell_requests`, `events`, `flags` success and failure), `parley`, `environment`. The conversation is a dipscript (`script_stepst` subclasses: textviewer, discuss, conditional, dipevent, with virtual `execute` and `skip`). The owner reports the dialog becomes available as a left-side alert button. `df.d_interface.xml`, `df.diplomacy.xml`, `df.script.xml`, `df.markup_text_box.xml`, `df.meetingmoment.xml`. |
| Popups (P4.0) | Box popups are `world.status.popups` (`popup_message`: `text`, `color`, `bright`, `portrait_hfid`) with `world.status.mega_text` as the rendered box; they come from announcements flagged `BOX` (`d_init.announcements.flags[type].DO_MEGA`: `EMBARK_MESSAGE`, `FIRST_CARAVAN_ARRIVAL`, `MEGABEAST_ARRIVAL`, `WEREBEAST_ARRIVAL`, `UNDEAD_ATTACK`, `FEATURE_DISCOVERY`, `STRUCK_DEEP_METAL`, `MADE_ARTIFACT`, `NAMED_ARTIFACT`, mood and crime boxes, holdings and monarch boxes) and from the game's own siege and invasion code. The left-side alert buttons are separate: `world.status.announcement_alert[]` (`announcement_alertst`: `type`, `announcement_id[]`, `report_unid[]`) and `alert_button_announcement_id[]`, viewed through `main_interface.announcement_alert`. The game pauses while a box is up, and `repeat-util` `ticks` timers do not run while paused; `frames` timers do. Probe: no popup open, `mega_text` still held 107 words from the last one. `df.announcement.xml`, `df.d_init.xml`, `data/init/announcements.txt`, `hack/lua/repeat-util.lua`. |
| Hotkeys (P5.0) | `plotinfo.main.hotkeys` is a fixed array of 16 `ui_hotkey` (`name`, `cmd` enum `None`, `Zoom`, `FollowUnit`, `FollowItem`, `x`, `y`, `z`, unit or item id); `custom_hotkeys` is an empty vector on this build. DFHack's `hotkey-notes` script reads them and labels slot i with `dfhack.screen.getKeyDisplay(df.interface_key.D_HOTKEY1 + i)`. The window state is `main_interface.hotkey` (`open`, `entering_index`, `entering_name`, `confirming_slot`, overwrite and deletion confirmations). Probe: slot 0 is `Zoom` "Wagon arrival location" at the wagon, slots 1 to 15 are `None`. The owner's "12" is checked against the key labels the window shows. `df.plotinfo.xml`, `df.d_interface.xml`, `hack/scripts/hotkey-notes.lua`. |
| Screen focus | `dfhack.gui.getCurFocus(true)` returns the focus strings (`dwarfmode/Default` on the main map, `dwarfmode/Trade/Default` on the trade screen, `dwarfmode/ViewSheets/BUILDING` on a building sheet); `dfhack.gui.getDFViewscreen(true)` is the screen to feed. Lua API gui section. |
| Dev probe | `RunLua` only accepts modules named `rpc.*`, so the probe was a temporary module registered through `rpc.OP_MODULES`, reloaded with `claude-bridge reload`, and removed afterwards. The console allowlist had been reset by the release tests and needed `claude-bridge allow claude-bridge` again. |

### 15.2 Decisions

Agreed with the owner on 2026-10-16.

| Question | Decision |
|---|---|
| Numbering and version | Patch 1 is Alpha 1.0.1: items P1.0, P1.1, P1.2, P2.0, P3.0, P4.0, P5.0, then P6.0 the owner's release (tag `v1.0.1-alpha`, server `1.0.1a1`, mod `DISPLAYED_VERSION` `1.0.1-alpha`, `NUMERIC_VERSION` 4 because the protocol changes). `MOD_VERSION` in `state.lua`, which `ping` reports and which stayed at 0.3.0 through the release, is bumped in the first branch and matched to `info.txt` from then on. |
| Labor scope (P1.0) | Membership on the existing work details plus each detail's mode. No creating, renaming, or deleting details, no editing a detail's labor set, no workshop worker lists. `labor.details` lists the details with mode, labors, and members; `labor.assign` adds and removes citizens on a detail by name or index and calls `setAutomaticProfessions` on each touched unit; `labor.set_mode` sets `everybody`, `nobody`, or `only_selected`, refuses `everybody` on a `cannot_be_everybody` detail, and recomputes every citizen. Children, babies, and non-citizens are refused with a reason. New toggle `labor_write` (Units group, off); the read sits under `units`. The fortress-quirks skill gets a Labor section: Miners, Woodcutters, Hunters, and Fisherdwarves are only-selected details whose members need a pick, axe, or crossbow; a dwarf in both Miners and Woodcutters swaps tools and wastes time; Haulers and the other everybody details need no members. |
| Seeds (P1.1) | Skill text only, no new op. A "Sustainable farming" section in fortress-quirks: keep one planting cycle of seeds per crop in reserve (tiles in the plots that grow it), check seed counts with `get_farm` at every `season_changed` event and before setting crops, leave the last plants of a crop uneaten and unbrewed when the seed count is below the reserve, keep the default cooking ban on seeds and ban cooking of plants whose seeds are short with `set_kitchen`, do not plant a crop whose seed count is below the tiles it would need, ask for seeds from the caravan and in the liaison requests when a crop is short, prefer plump helmets as the backbone, and remember the 200-seed cap per type. The planner skill's session-start list gains "seed check" at season change. |
| Migrants (P1.2) | One new event kind `migrants_arrived` (default on) mapped to all six announcement types, including the discouraged and no-arrival texts, which Claude tells apart by the text and `extra.announcement`. The events poller keeps a citizen id set per poll; on a migrant report the event carries `unit_ids` and `extra.new_citizens` `[{id, name, profession}]` (capped at 25) as the citizens present now that were absent at the last poll, and the baseline is advanced. A birth in the same 100 ticks would appear in the list; the text says so. |
| Trade press (P2.0) | Synthesized click through DFHack's input path: `trade.press(action)` resolves the button's frame against `gui.get_interface_rect()` (the frames DFHack's confirm plugin uses for Trade, Offer, and Seize; the counter-offer buttons are measured on the caravan save), sets `gps.mouse_x`/`mouse_y`, and calls `gui.simulateInput(dfhack.gui.getDFViewscreen(true), {_MOUSE_L=true})`. The player's cursor does not move; the game's own handler runs, so the reply (`talkline`), the merchant's words (`big_announce`), mood change, counter-offers, ethics, and bookkeeping are the game's. Actions in scope: `trade`, `offer`, `seize`, `accept_counter`, `decline_counter`, `close`. `close` writes `open = false`. If the DFHack confirm plugin catches the click (its `trade-confirm-trade`, `trade-offer`, `trade-seize` dialogs intercept the same frames), the op detects the confirm focus and answers it with its confirm key; `confirm.json` is never edited (rule 8). The mod's own exchange is not built. |
| Trade open (P2.0) | State replay. On the caravan save the owner presses Trade once on the depot sheet while a recorder op captures `main_interface.trade` before and after; `trade.open_screen(depot_id)` then writes the same fields (`open`, `bld`, `mer`, `civ`, `st`, names, `buildlists`, `choosing_merchant` when more than one caravan waits) and the game builds the goods lists. It refuses when no caravan is at the depot or the merchants are still unloading, and reports `havetalker` when the broker is not there. If the replay half-opens or crashes the screen, the fallback is a synthesized click on the depot sheet's Trade button; if that fails too, the item moves to README open issues (owner's rule of thumb). |
| Diplomacy opener (P3.0) | The dialog arrives as a left-side alert button (owner). `trade.dialog` reports whether a meeting dialog is available (the alert whose report belongs to the meeting), whether it is open, the text, the step, the choices, and the request and land-holder state. `trade.open_dialog()` replays the alert click: the field diff is recorded on the liaison save the same way as the trade screen. A new event kind `meeting_ready` (default on) fires when the alert appears, from the frame poller that P4.0 adds. |
| Diplomacy steps (P3.0) | State replay. The dialog's text is rebuilt from `diplomacy.text.word[]` (line flags, CP437 to UTF-8); the choices are exposed as a numbered list; `trade.dialog_step(action)` takes `continue`, `choose` with an index, `done`, `land_holder` with a historical figure id, and `close`, each reproducing the field changes recorded when the owner clicks through once. Driving the dipscript engine's `execute` and `skip` methods directly is the fallback only if a replay proves impossible, and synthesized clicks are not used here because the button positions move with the text. `set_trade_requests` keeps working on the Requests step. |
| Popups (P4.0) | A frame-based poller (every 30 frames, so it runs while the game is paused) watches `world.status.popups`; each new front entry becomes a `popup` event (default on) with the text, colour, and the portrait figure's name. `popups.list` returns the open popups; `popups.close(unpause)` removes the front one the way the Close button does (verified by a field diff on the first live popup) and, when `unpause` is true and `pause_write` is on, unpauses; otherwise it says the game is still paused. No auto-close setting and no alert-button handling beyond what P3.0 needs for the meeting alert. |
| Hotkeys (P5.0) | `hotkeys.list` returns all 16 slots with the key label the game shows, name, kind, and position. `hotkeys.set(slot, name, x, y, z, overwrite)` writes a `Zoom` hotkey; `slot` may be omitted to take the first empty one; a slot that already carries a name is refused unless `overwrite` is true; names are CP437-encoded and clipped to the length the game's rename field accepts (checked live); positions must be inside the map. `hotkeys.clear(slot)` resets a slot to `None`. Follow-unit and follow-item hotkeys are read but not written. Slot 1 (F1) is reported as the wagon default. New toggle `hotkeys_write` (World group, off); the read sits under `map`. The planner skill uses hotkeys as named points of interest in `plan.md`. |
| Menu clash | Every screen-driving op (`trade.open_screen`, `trade.press`, `trade.open_dialog`, `trade.dialog_step`, `popups.close`) first checks `dfhack.gui.getCurFocus(true)`. If the focus is not the main map or the screen the op expects, it returns the new error code `SCREEN_BUSY` naming the open screen, and never closes the player's menu. Claude retries later or tells the player. |
| Unpause | The screen ops and `popups.close` take `unpause` (default false). It is honoured only when `pause_write` is on; otherwise the result carries a note and the game stays paused. The quirks skill tells Claude to unpause after reading a popup or finishing a trade unless it is still planning. |
| Permissions | Three new toggles, all off: `labor_write` (Units), `hotkeys_write` (World), `screens_write` (General), the last gating everything that drives a game screen: opening and pressing on the trade screen, opening and stepping the diplomacy dialog, closing popups. New read ops sit under the nearest existing read namespace (`units`, `map`, `trade`, `events`). |
| Protocol | Each branch that adds or changes an op bumps the protocol version (25 upwards), edits `docs/protocol.md`, and adds `SCREEN_BUSY` to the error codes in the first screen branch (rule 2). |
| Tests | Fixture tests on the server for every new tool and event kind (recorded Lua results fed through the channel formatter and the tool wrappers); Lua-side `claude-bridge test` fixtures for the event text. Live verification per item on the owner's saves: any fort for P1.x, P4.0, P5.0; the caravan save for P2.0; the liaison save for P3.0. |
| Order of work | P1.0, P1.1, P1.2, P5.0, P4.0, P2.0, P3.0, then P6.0. Save-free items first; the frame poller and the click technique are proven on popups before the trade and diplomacy sessions. |

### 15.3 Ops by item

| Item | Ops | Tools |
|---|---|---|
| P1.0 | `labor.details` (`units`), `labor.assign`, `labor.set_mode` (`labor_write`) | `list_work_details`, `assign_work_detail`, `set_work_detail_mode` |
| P1.1 | none | none; `df-skills/skills/fortress-quirks/SKILL.md` and the planner's season-change note |
| P1.2 | `events.kinds` gains `migrants_arrived`; `events.poll` entries carry `extra.new_citizens` | existing `list_event_kinds`, `poll_events`, channel batches |
| P2.0 | `trade.open_screen`, `trade.press` (`screens_write`); `trade.screen` extended with `merchant_message`, `counter_offer_items`, `mood` | `open_trade_screen`, `press_trade` (action), `get_trade_screen` |
| P3.0 | `trade.dialog` (`trade`), `trade.open_dialog`, `trade.dialog_step` (`screens_write`); `events.kinds` gains `meeting_ready` | `get_meeting_dialog`, `open_meeting_dialog`, `step_meeting_dialog` |
| P4.0 | `popups.list` (`events`), `popups.close` (`screens_write`); `events.kinds` gains `popup` | `list_popups`, `close_popup` |
| P5.0 | `hotkeys.list` (`map`), `hotkeys.set`, `hotkeys.clear` (`hotkeys_write`) | `list_hotkeys`, `set_hotkey`, `clear_hotkey` |
| P6.0 | version bumps, tag, release | owner |

Each branch also updates the server's tool descriptions, the MCP instructions text, the fortress-quirks skill, `docs/protocol.md`, and the README progress row.

### 15.4 In-game checks before or during implementation

1. P1.0: adding a dwarf to Woodcutters and calling `setAutomaticProfessions` flips `unit.status.labors.CUTWOOD` and the Labor screen shows the member; removing clears it; a mode change to `nobody` on Haulers clears hauling labors on every citizen and `everybody` restores them; a child is refused; `assigned_units` stays sorted (`utils.insert_sorted`).
2. P1.2: a migrant wave on any fort fires exactly one of the six types per wave (the `D_` or the plain one), the event carries the newcomers, and the no-arrival text arrives as the same kind.
3. P5.0: the key labels from `getKeyDisplay(D_HOTKEY1 + i)` for the 16 slots, the name length the rename field accepts, and whether the game redraws the hotkeys window after a write without touching any texture field (rule 13).
4. P4.0: on the first live box (the embark message of a new fort, or a dev-forced `MEGABEAST_ARRIVAL` through `makeAnnouncement` with the `DO_MEGA` flag if the owner allows), record what the Close button changes (`popups` erased and deleted, `mega_text` cleared or not, pause state), then replay it from `popups.close`; the frame poller detects it while paused.
5. P2.0 (caravan save): record `main_interface.trade` before and after the owner's Trade press on the depot sheet; replay it; select goods; `trade.press('trade')` through the simulated click, handling the DFHack confirm dialog if it appears; read the reply, mood, and the counter-offer path; `offer`; `seize` only if the owner wants the caravan spoiled; `close`. The depot sheet's Trade button frame is measured only if the replay fails.
6. P3.0 (liaison save): find the meeting alert in `world.status.announcement_alert` and `alert_button_announcement_id`; record the diff of `main_interface.diplomacy` when the owner clicks the alert, Continue, a choice, the Requests Done, and the land-holder choice if offered; replay each; confirm the agreement lands in `dip_meeting_info[i].events` as in 17.1.
7. Every screen op: a `SCREEN_BUSY` refusal while the owner has the stocks or a unit sheet open, and the unpause flag with `pause_write` on and off.

### 15.5 Delivery

Eight branches from `main`, in this order, one PR each, merged after the owner's yes: `mod/labor` (P1.0, with the `MOD_VERSION` fix), `skills/seeds` (P1.1), `mod/migrant-events` (P1.2), `mod/hotkeys` (P5.0), `mod/popups` (P4.0), `mod/trade-screen` (P2.0), `mod/diplomacy-dialog` (P3.0), `repo/alpha-1.0.1` (P6.0, the owner's). Each PR updates the README progress section; an item the game refuses headlessly moves to the README open issues with its design kept here.

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
- Claude Code channels (checked 2026-10-15): https://code.claude.com/docs/en/channels and https://code.claude.com/docs/en/channels-reference ; hooks: https://code.claude.com/docs/en/hooks ; scheduled tasks: https://code.claude.com/docs/en/scheduled-tasks
- DFHack Lua API as shipped with 53.16-r2 (`hack/docs/docs/dev/Lua API.txt`), the kitchen, military, designations, items, gui, textures, persistent, and widgets sections (checked 2026-10-15): https://docs.dfhack.org/en/stable/docs/dev/Lua%20API.html
- DFHack Military, Items, Gui, EventManager, Persistence, Designations modules and the autofarm and createitem plugins on master (checked 2026-10-15): https://github.com/DFHack/dfhack/tree/master/library/modules and https://github.com/DFHack/dfhack/tree/master/plugins
- DFHack scripts shipped with 53.16-r2 and on master (checked 2026-10-15): quickfort build and dig, caravan (movegoods, trade, tradeagreement, common), notify, gui/journal, gui/petitions, list-agreements, ban-cooking, fix/archery-practice, lever, gui/advfort, exterminate, spawnunit, modtools/create-unit, modtools/create-item: https://github.com/DFHack/scripts
- df-structures master as of 2026-10-10 (checked 2026-10-15): `df.plotinfo.xml`, `df.squad.xml`, `df.agreement.xml`, `df.announcement.xml`, `df.d_init.xml`, `df.d_interface.xml`, `df.building.xml`, `df.veg.xml`, `df.world.xml`, `df.g_src.basics.xml` (announcement types): https://github.com/DFHack/df-structures
- DF wiki Farming, Kitchen, Tree, Squad, Ammunition, Trap, Trade depot, Trading, Caravan, Broker, Outpost liaison, Baron, Petition, Resident, Guildhall, Announcement, Strange mood, Ghost pages (checked 2026-10-15): https://dwarffortresswiki.org/
- Dwarf Fortress wiki: https://dwarffortresswiki.org/
- Claude Code skills, plugins, sub-agents, MCP, memory (checked 2026-10-15): https://code.claude.com/docs/en/skills , https://code.claude.com/docs/en/plugins/create , https://code.claude.com/docs/en/plugins/manifest-reference , https://code.claude.com/docs/en/plugins/install , https://code.claude.com/docs/en/sub-agents , https://code.claude.com/docs/en/mcp , https://code.claude.com/docs/en/memory
- Patch 1 research (checked 2026-10-16): df-structures master `df.plotinfo.xml` (work details, hotkeys), `df.d_interface.xml` (trade, diplomacy, hotkeys, alert interfaces), `df.announcement.xml` (popups, alerts), `df.d_init.xml` (announcement flags), `df.g_src.basics.xml` (announcement and alert types), `df.diplomacy.xml`, `df.script.xml`, `df.markup_text_box.xml`, `df.meetingmoment.xml`: https://github.com/DFHack/df-structures ; DFHack 53.16-r2 `hack/docs/docs/dev/Lua API.txt` (`setAutomaticProfessions`, `simulateInput`, `getCurFocus`, `getDFViewscreen`), `hack/scripts/gui/manipulator.lua`, `hack/scripts/internal/confirm/specs.lua`, `hack/scripts/internal/caravan/trade.lua`, `hack/scripts/hotkey-notes.lua`, `hack/lua/repeat-util.lua`; Dwarf Fortress `data/init/announcements.txt`; DF wiki Farming, Seeds, Migrant, Hotkey pages: https://dwarffortresswiki.org/
