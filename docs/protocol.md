# Bridge protocol

Protocol version: **1**. Bump `PROTOCOL_VERSION` in `mod/.../state.lua` and `server/src/df_mcp/__init__.py` together whenever an op's shape changes.

## Transport

The Python server calls DFHack's remote RPC method `RunLua` with module `rpc.claude_bridge`, function `dispatch`, and exactly one string argument. The function returns exactly one string. Both strings are JSON. The DF core is suspended for the duration of the call.

The mod publishes `rpc.claude_bridge` into `package.loaded` when enabled. If the mod is not enabled, `RunLua` fails with `CR_NOT_FOUND` and the server reports `MOD_NOT_ENABLED`.

## Envelope

Request:

```json
{"op": "units.list", "args": {"category": "citizen"}, "id": 7, "v": 1}
```

- `op` is `namespace.verb`. The namespace is what permissions are checked against.
- `args` is an object; omit it or pass `{}` when the op takes none.
- `id` is echoed back when present. `v` is the protocol version the client speaks and is informational for now.

Response:

```json
{"ok": true, "result": {...}, "id": 7}
{"ok": false, "error": {"code": "NOT_ALLOWED", "message": "..."}, "id": 7}
```

Notes on JSON from Lua: an empty table encodes as `[]`, so an empty object-valued field may arrive as an empty array. Absent values are omitted, not `null`.

## Error codes

| Code | Meaning |
|---|---|
| `BAD_REQUEST` | Malformed envelope or bad `args`. |
| `NOT_ALLOWED` | The player has not granted the op's namespace, or the console command is not allowlisted. |
| `NO_WORLD` | The op needs a loaded world. |
| `NO_MAP` | The op needs a loaded fortress map. |
| `NOT_FOUND` | Unknown op, or the requested object does not exist. |
| `INTERNAL` | The handler raised. The message holds the Lua error. |

Transport-level codes the server adds: `MOD_NOT_ENABLED`, `DISCONNECTED`, `RPC_FAILED`.

## Namespaces and permissions

| Namespace | Default | Ops |
|---|---|---|
| `core` | always allowed | `core.ping` |
| `settings` | on | `settings.get` |
| `time` | on | `time.now` |
| `units` | on | `units.list`, `units.get` |
| `console` | off | `console.run` (plus a per-command allowlist) |
| `lua_eval` | off | no ops; gates `lua` through `console.run` |

## Ops

### `core.ping`

Args: none. Works without a world.

Result: `mod_version`, `protocol_version`, `dfhack_version`, `df_version`, `world_loaded`, `map_loaded`, `fortress_mode`, `paused` (only with a map), `frame`.

### `settings.get`

Args: none.

Result: `permissions` (object of `{allowed, label}` keyed by namespace), `console_allow` (array of command names), `ops` (array of `{op, namespace}`).

### `time.now`

Args: none. Needs a map.

Result: `year`, `month` (1-12), `month_name`, `day` (1-28), `day_of_year`, `season` (spring, summer, autumn, winter), `season_day` (1-84), `hour`, `minute`, `year_tick`, `frame`, `paused`, `weather` (`None`, `Rain`, `Snow`, or null), `fort_name`, `unsaved_seconds`, `date_string`.

### `units.list`

Args: `category` (string or null), `include_dead` (bool, default false), `limit` (default 200), `offset` (default 0). Needs a map.

Categories: `citizen`, `resident`, `visitor`, `merchant`, `diplomat`, `animal`, `wildlife`, `invader`, `undead`, `hostile`, `other`.

Result: `total` (matching units), `count` (rows returned), `offset`, `units` (array of summary rows), `counts_by_category` (whole map, ignores the filter).

Summary row: `id`, `name`, `category`, `race`, `profession`, `age` (years, fractional), `sex`, `pos` `{x,y,z}`, `job`, `dead`.

### `units.get`

Args: `id` (unit id). Needs a map.

Result: summary row plus `mood`, `stress`, `stress_category`, `skills` (array of `{skill, rating, level, experience}`, sorted by rating), `labors` (array of enabled labor names), `wounds`, `blood`, `squad` (`{id, name, position}` or null), `flags` (object of true flags: `caged`, `chained`, `marauder`, `crazed`, `baby`, `child`, `adult`, `opposed_to_life`), `civ_id`.

Field availability is defensive: anything DFHack cannot provide for a unit is omitted. The detail fields still need a pass against the 53.x `df.unit` struct in-game.

### `console.run`

Args: `command` (full console line).

The first word must be on the console allowlist. `lua` additionally needs `lua_eval`. Runs through `dfhack.run_command_silent`.

Result: `command`, `ok` (result was `CR_OK`), `result` (numeric `CR_*`), `output` (captured text).
