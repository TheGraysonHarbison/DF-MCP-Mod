# Project Plan: DFHack Claude Integration Mod

Status: planning, pre-initial-commit. Last updated 2026-10-12.

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
     |    RunLua    -> rpc.claude_bridge.dispatch(json) -> json
     |    RunCommand -> DFHack console, output captured
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
- `RunCommand` gives feature 3 (console access) for free, with output returned as text fragments.
- The Python side is a small protobuf framing client (handshake, `BindMethod`, request, reply, quit). No maintained Python client exists, so we write our own and keep it under 300 lines.

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

The module name must satisfy DFHack's `RunLua` filter (`rpc.*`). Mod scripts are loaded with `reqscript`, not `require`, so the control script publishes the dispatcher by assigning it into `package.loaded["rpc.claude_bridge"]` on enable. This is to be verified in Phase 0 before anything else is built; the fallback is `RunCommand` with a `claude-bridge rpc <json>` subcommand.

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

Why: no second runtime, uses the Team seat, and the whole system is observable from one terminal. A Python conductor using the Agent SDK remains a possible Phase 4 if running without a terminal matters.

### 2.5 Permissions

The settings panel (a DFHack overlay window) owns a permission table stored under `scriptmanager.getModStatePath("claude-bridge")`:

- Per-namespace toggles: `time`, `units`, `console`, `events`, `petitions`, `build`, `orders`, `military`.
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
| 3. Console | `console.run` | `run_console_command` | Routed through DFHack `RunCommand`; allowlist checked in Lua first |
| 4. Units | `units.list`, `units.get` | `list_units`, `get_unit` | Categories: citizens, residents, visitors, merchants, diplomats, animals, wildlife, invaders, undead. Summary rows plus a detail op with health, mood, labors, skills, relationships |

Also in Phase 1: `docs/protocol.md` for every op above, and a `tools/smoke-test.py` that exercises each op against a running game.

### Phase 2: Events, chat, autonomy

- Event queue (2.3) with `events.poll` and `wait_for_event`.
- Chat overlay: text input in-game, history pane, messages appear as `chat.message` events; Claude replies with `chat.say`, shown in the pane and as a DF announcement.
- Autonomy timer with pause awareness, configured in the settings panel.
- Event-kind filters in settings.
- A documented "play loop" prompt in `docs/playing.md` describing how to start a session.

### Phase 3: Act

Each action is its own op, its own permission, and its own PR.

- Petitions: `petitions.list`, `petitions.respond(id, accept)`.
- Quickfort: `build.quickfort(blueprint_text, cursor)` with `--dry-run` first, run through the quickfort command.
- Manager orders: `orders.list`, `orders.create`, `orders.cancel`.
- Military: squads, alerts, stations.
- Labors and unit assignment.
- Zones and stockpiles.

### Phase 4: Candidates, not committed

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
    playing.md              how to run a play session (Phase 2)
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
        ui/chat.lua         chat overlay window (Phase 2)
  server/                   the Python MCP server
    pyproject.toml          uv project, package df_mcp, entry point df-mcp
    src/df_mcp/
      __init__.py
      dfhack_rpc.py         protobuf framing client for the DFHack remote server
      proto/                generated CoreProtocol pb2 plus the .proto it came from
      bridge.py             call(op, args) -> result, error mapping, reconnect
      server.py             MCPServer construction and transport
      tools/                one module per namespace, registers tools
    tests/
      test_dfhack_rpc.py    framing tests against recorded bytes
      test_bridge.py        envelope and error mapping with a fake transport
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
3. Permission checks live in Lua at dispatch. Never add a Python-side shortcut that calls DFHack without going through `rpc.claude_bridge.dispatch`, except `console.run`, which goes through `RunCommand` only after a Lua allowlist check. Reason: the player's settings panel is the only trust boundary.
4. No tool that evaluates arbitrary Lua ships unless it is behind its own permission and off by default. Reason: that is full code execution in the player's game.
5. Lua follows DFHack conventions: `--@ module = true` header, `local _ENV = mkmodule(...)` for internal modules, no globals except `OVERLAY_WIDGETS`, 4-space indent, snake_case, early return on `dfhack_flags.module`. Use `dfhack.*` helpers over raw `df.global` walks when one exists.
6. Python uses uv, ruff, pytest, type hints, Python 3.11. The MCP server logs to stderr only. Reason: stdout is the MCP transport.
7. DFHack docs are cited by the `stable` URL and the version they were checked against. Do not rely on memory for `df.*` struct fields; look them up or check in-game with `:lua`.
8. Never read, write, or commit DF save folders or `dfhack-config` beyond the mod's own state file. Never put ports, paths, or credentials in committed files; `.mcp.json` uses relative paths only.
9. Branch per change, conventional commit messages, PR via `gh`. Do not commit to `main`.
10. When a feature lands, update the README progress section in the same PR. The README is for readers; this file is for builders.
11. Confirm before anything that affects a running game beyond reads: pausing, running console commands, or changing settings during a test session.

---

## 7. Open items

- License choice before the first public push.
- Verify the `package.loaded` route for `RunLua` in Phase 0; the fallback is a `claude-bridge rpc` console subcommand over `RunCommand`.
- Decide whether `.mcp.json` is committed or templated as `.mcp.json.example` once the uv entry point exists.
- Unit detail fields for `units.get` need a pass against the 53.x `df.unit` struct before the op is documented.

---

## References (checked 2026-10-12)

- DFHack releases: https://github.com/DFHack/dfhack/releases (latest 53.16-r2)
- DFHack modding guide: https://docs.dfhack.org/en/stable/docs/guides/modding-guide.html
- DFHack Lua API: https://docs.dfhack.org/en/stable/docs/dev/Lua%20API.html
- DFHack remote interface: https://docs.dfhack.org/en/stable/docs/dev/Remote.html
- DFHack CoreProtocol.proto: https://github.com/DFHack/dfhack/blob/develop/library/proto/CoreProtocol.proto
- DFHack overlay dev guide: https://docs.dfhack.org/en/stable/docs/dev/overlay-dev-guide.html
- MCP Python SDK: https://github.com/modelcontextprotocol/python-sdk (mcp 2.3.0, 2026-10-02)
- Dwarf Fortress wiki: https://dwarffortresswiki.org/
