# CLAUDE.md

DFHack Claude Integration Mod: a DFHack Lua mod (`mod/`) plus a Python MCP server (`server/`) that lets Claude observe and play a Dwarf Fortress fort through Claude Code. Full plan and rationale: `docs/ProjectPlan.md`. Wire protocol: `docs/protocol.md`.

## Layout

- `mod/` the DFHack mod, ID `claude-bridge`. Control script in `scripts_modinstalled/claude-bridge.lua`, modules in `scripts_modinstalled/internal/claude-bridge/`.
- `server/` uv project, package `df_mcp`, entry point `df-mcp`. Speaks DFHack's remote RPC on localhost:5000 and exposes MCP tools over stdio.
- `docs/` plan, protocol, decisions. `tools/` dev scripts.

## Commands

- Server tests: `uv run --project server pytest`
- Lint: `uv run --project server ruff check server`
- Link the mod into a local DFHack for development: `tools/link-mod.sh <DF dir>`
- Smoke test against a running game: `uv run --project server python tools/smoke-test.py`

## Rules

1. Read `docs/ProjectPlan.md` before structural work and `docs/protocol.md` before touching any RPC op.
2. A protocol change edits the Lua handler, the Python tool, `docs/protocol.md`, and the protocol version together, in one branch.
3. Permission checks live in Lua at dispatch. Every game call goes through `rpc.claude_bridge.dispatch`. The client's raw `RunCommand` is for dev tooling only, never for an MCP tool.
4. No tool that evaluates arbitrary Lua ships unless it is behind its own permission and off by default.
5. Lua: DFHack script conventions. `--@ module = true` header, module-level functions are the exports and everything else is `local`, internal modules load with `reqscript('internal/claude-bridge/<name>')`, 4-space indent, snake_case, control script returns early on `dfhack_flags.module`. Prefer `dfhack.*` helpers over raw `df.global` walks and wrap uncertain struct access in `pcall`.
6. Python: uv, ruff, pytest, type hints, Python 3.11. The MCP server logs to stderr only; stdout is the transport.
7. Cite DFHack docs by the `stable` URL and the version checked. Do not trust memory for `df.*` struct fields; look them up or verify in-game with `:lua`.
8. Never read, write, or commit DF save folders or `dfhack-config` beyond the mod's own state file and the mod's own `claude-df/` working folder inside the current save (`goals.md`, `plan.md`), which the mod creates and owns. No ports, absolute paths, or credentials in committed files.
9. Branch per change (`<scope>/<topic>`), Conventional Commits with scopes `mod`, `server`, `docs`, `tools`, `repo`, PR via `gh`. Do not commit to `main`. Every branch starts from `main`; stacking a branch on another branch needs the owner's explicit permission. Once the owner has approved a feature branch's functions, Claude may merge its PR with `gh pr merge`, but only after asking the owner first and getting a yes for that specific merge.
10. When a feature lands, update the README progress section in the same PR.
11. Confirm before anything that affects a running game beyond reads during a test session.
12. Any list that can grow large (items, thoughts, memories, orders, tiles, inventory) is capped at 25 entries by default. Every such op takes a `limit` argument that raises the cap for that call, and the response says when the cap was hit. Never return an uncapped large list.
13. Never write to texture or render cache fields on game structs (`*_texpos`, `texture_*`, anything the structures call transient or cached): resetting a squad's badge textures crashed the game on 2026-10-15. Change the data fields only and let the game redraw.
