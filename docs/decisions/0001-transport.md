# 0001: Use DFHack's remote RPC and RunLua as the bridge transport

Date: 2026-10-12. Status: accepted, pending in-game verification of the `package.loaded` route.

## Context

The Python MCP server needs to call into Lua running inside Dwarf Fortress. Options were DFHack's built-in remote server (protobuf over TCP, port 5000), our own socket via the `luasocket` plugin, or file-based polling.

## Decision

Use the built-in remote server. Requests go through `RunLua` to a single dispatcher function with a JSON string in and a JSON string out. Console commands run inside that dispatcher via `dfhack.run_command_silent`, so one permission check covers everything.

`RunLua` only accepts modules named `rpc.*` and loads them with `require`. Mod scripts load with `reqscript`, so the control script assigns the dispatcher into `package.loaded["rpc.claude_bridge"]` when enabled and removes it when disabled. Fallback if that fails in-game: a `claude-bridge rpc <json>` console subcommand driven through `RunCommand`.

## Consequences

- No plugin to enable, no extra port, core suspension is handled by DFHack.
- Events are polled, not pushed. Acceptable because MCP cannot start a Claude turn anyway.
- The dispatcher is transport-agnostic (`rpc.handle(table)`), so a luasocket transport can be added later without touching ops.
