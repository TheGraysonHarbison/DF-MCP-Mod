# Bridge protocol

Protocol version: **2**. Bump `PROTOCOL_VERSION` in `mod/.../state.lua` and `server/src/df_mcp/__init__.py` together whenever an op's shape changes.

## Transport

The Python server calls DFHack's remote RPC method `RunLua` with module `rpc.claude_bridge`, function `dispatch`, and exactly one string argument. The function returns exactly one string. Both strings are JSON. The DF core is suspended for the duration of the call.

The mod publishes `rpc.claude_bridge` into `package.loaded` when enabled. If the mod is not enabled, `RunLua` fails with `CR_NOT_FOUND` and the server reports `MOD_NOT_ENABLED`.

## Envelope

Request:

```json
{"op": "units.list", "args": {"bucket": "citizen"}, "id": 7, "v": 2}
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
| `units` | on | `units.list`, `units.find`, `units.get`, `units.sheet`, `units.full_sheet` |
| `units_write` | off | `units.set_nickname` |
| `nobles` | on | `nobles.list` |
| `nobles_write` | off | `nobles.assign` |
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

### Units

Every unit is in exactly one bucket, with a finer `kind`. Design and the tests behind each label: `docs/ProjectPlan.md` section 8.

| Bucket | Kinds |
|---|---|
| `citizen` | `citizen`, `resident` |
| `domesticated` | `pet`, `war_animal`, `hunting_animal`, `livestock`, `stray` |
| `other` | `visitor`, `merchant`, `diplomat`, `invader`, `undead`, `wildlife`, `agitated`, `hostile`, `other` |

Row: `id`, `name`, `unit` (bucket), `kind`, `gender` (`female`, `male`, `none`), `creature`, and either `mood` (`miserable`, `unhappy`, `displeased`, `content`, `pleased`, `happy`, `ecstatic`, or `none` when the unit has no soul) or, for `domesticated`, `owner` (the pet owner's readable name or `None`).

```json
{"id": 1234, "name": "Urist McMason", "unit": "citizen", "kind": "citizen", "gender": "female", "creature": "dwarf", "mood": "content"}
{"id": 1301, "name": "Stray Cat (Tame)", "unit": "domesticated", "kind": "stray", "gender": "male", "creature": "cat", "owner": "None"}
```

### `units.list`

Args: `bucket` (string or null), `kind` (string or null), `include_dead` (bool, default false), `limit` (default 200), `offset` (default 0). Needs a map. An unknown `bucket` is `BAD_REQUEST`; an unknown `kind` simply matches nothing.

Result: `total` (matching units), `count` (rows returned), `offset`, `units` (array of rows), `counts_by_bucket` and `counts_by_kind` (whole map, ignore the filter).

### `units.find`

Args: `query` (non-empty string), `bucket` (string or null), `limit` (default 20), `include_dead` (bool, default false). Needs a map.

Case-insensitive substring match against the readable name, creature name, nickname, native name, and English name.

Result: `query`, `total`, `count`, `units` (array of rows).

### `units.get`

Args: `id` (unit id). Needs a map. Unknown id is `NOT_FOUND`.

Result: the row plus `nickname`, `caste`, `profession`, `custom_profession`, `age` (years, fractional), `pos` `{x,y,z}`, `job`, `hist_figure_id` (-1 when none), `civ_id`, `squad` (`{id, name, position}` or absent), `flags` (object of true flags: `caged`, `chained`, `marauder`, `ghost`, `crazed`, `insane`, `baby`, `child`, `adult`, `opposed_to_life`, `marked_for_slaughter`), `dead`. Domesticated animals get `mood` as well as `owner`.

Field availability is defensive: anything DFHack cannot provide for a unit is omitted.

### `units.sheet`

Args: `id` (unit id), `category` (string), `subcategory` (string or null), `limit` (positive int, default 50). Needs a map.

Categories and sub-categories follow the in-game profile tabs:

| Category | Sub-categories |
|---|---|
| `overview` | none |
| `relations` | none |
| `groups` | none |
| `military` | `squads`, `uniform`, `kills` |
| `thoughts` | `recent`, `memories` |
| `personality` | `traits`, `values`, `preferences`, `needs` |
| `items` | none |
| `health` | `status`, `wounds`, `treatment`, `history`, `description` |
| `skills` | `labor`, `combat`, `social`, `other`, `knowledge` |
| `rooms` | none |
| `labor` | `work_details`, `workshops`, `locations`, `work_animals` |

An unknown category or sub-category, or a sub-category on a category without any, is `BAD_REQUEST` with the valid names in the message. Omitting `subcategory` on a category that has them returns every sub-category keyed by name.

Result: `id`, `name`, `category`, `subcategory`, `limit`, `data`, `truncated` (array of section paths such as `skills.labor` that were cut at `limit`), `best_effort` (array of section paths that are incomplete reconstructions).

Every list-valued section in `data` is an object `{entries, total, truncated}`. A section that is not implemented yet is `{best_effort: true, note}`. Enum values are DF tokens (`MINING`, `SWORD`) with a `caption` where DF has one.

Every category is implemented. The one remaining `best_effort` section is `health.description.appearance`, which is not reconstructed from the appearance genes.

Section contents, briefly (every list is a `{entries, total, truncated}` object):

- `overview`: the `units.get` row plus `stress`, `long_term_mood`, `focus`, `dream`, `kills`, `kin`, `positions`, `top_skills`, `hauling`, `recent_thoughts`.
- `relations`: `kin` (on-map ids from the unit record), `family` and `deities` (historical figure links, with `relation`, `hist_figure_id`, `name`, `id` when the figure is on the map), `pets`, `others` (known figures with `meet_count`, `first_year`, `last_meet_year`, `feelings` `{love, trust, loyalty, fear, respect}`, `attitudes`, `flags`). The game derives labels such as friend or grudge from `feelings`; the raw scores are returned.
- `groups`: `memberships` (entity links with `link`, `entity`, `entity_type`, `strength`, and `start_year`/`end_year`/`assignment_id` when present) and `positions`.
- `military.squads`: `squad` `{id, name, alias, position, leader, entity_id, orders}` or empty. `military.uniform`: specs with `category`, `item_type`, `item`, `material`, `material_class`, `indiv_choice`, `assigned`. `military.kills`: `count`, `notable` (history events with `victim`, `cause`, `year`), `other` (per-creature counts).
- `thoughts.recent`: emotions newest first with `emotion`, `thought`, `caption`, `strength`, `severity`, `year`, `year_tick`. `thoughts.memories`: `short_term`, `long_term`, `core` (each memory plus any `changed_facet`/`changed_value` shift).
- `personality`: `traits` (`facets` 0-100 and `mental_attributes`), `values` (`value`, `strength`), `preferences` (`kind`, `target`, and `item`/`material` for food and items), `needs` (`need`, `focus_level`, `need_level`, `deity` when relevant).
- `items`: `inventory` (`id`, `description`, `mode`, `body_part`) and `owned`.
- `health`: `status` (health flags), `wounds` (per wound `flags`, `parts` with body part names and damage flags), `treatment` (flags, per-body-part flags, countdowns), `history` (`operations`, `diagnoses`), `description` (caste, size, blood, `physical_attributes`).
- `skills`: `labor`, `combat`, `social`, `other` (each `skill`, `caption`, `rating`, `level`, `experience`, plus `effective_rating` and `rusty` when they differ), `knowledge` (known poetic, musical, and dance forms and instruments).
- `rooms`: owned zones with `type`, `zone_type`, `description`, `pos`.
- `labor`: `work_details` (`details` the unit is assigned to with `labors`, `mode`, `icon`; and `enabled_labors`), `workshops` (where the unit is a permitted worker), `locations` (occupations with `location`), `work_animals`.

### `units.full_sheet`

Args: `id`, `limit` (positive int, default 50). Needs a map.

Result: `id`, `name`, `limit`, `sheet` (object keyed by category, each shaped as the `units.sheet` `data` with no sub-category filter), `truncated`, `best_effort`. A category whose builder raises is returned as `{best_effort: true, error}` rather than failing the call.

### `units.set_nickname`

Args: `id` (unit id), `nickname` (string, up to 64 characters after trimming; empty clears). Needs a map and the `units_write` permission.

The nickname is converted from UTF-8 to code page 437 before it is stored; characters that code page lacks (for example capital Ó) become `?`. Unknown id is `NOT_FOUND`.

Result: `id`, `name` (readable name after the change), `nickname` (absent when cleared).

### `nobles.list`

Args: none. Needs a map.

Result: `entity` `{id, name}` (the site government), `count`, `positions` sorted by precedence. Each position: `id`, `code` (the token used by `nobles.assign`, e.g. `MANAGER`), `name` (gendered for the first holder), `precedence`, `number` (seats), `holders` (array of `{id, name, hist_figure_id, on_map}`; `id` absent when the holder is not a unit on this map), `slots` (array of `{slot, assignment_id, holder, squad_id}`), `vacant`, `military`, `land_holder`, `flags`, `responsibilities`, `required` `{office, bedroom, dining, tomb, boxes, cabinets, racks, stands}`, `mandate_max`, `demand_max`, `replaced_by`.

### `nobles.assign`

Args: `position` (code or numeric id), `id` (unit id, or null to vacate), `slot` (1-based seat, optional). Needs a map and the `nobles_write` permission.

Refused with `BAD_REQUEST` when the position is military (`squad_size` above zero or a seat tied to a squad), when the unit is not a living citizen, or when `slot` is out of range. Unknown position or unit is `NOT_FOUND`. Appointing a unit that already holds the seat, or vacating an empty seat, is a no-op with `changed: false`.

The change mirrors what DFHack's `make-monarch` does: the assignment's `histfig` is swapped, the previous holder's position link is removed from their historical figure, and a new position link is added to the appointee. `histfig2` records the previous holder. No former-position record is written for the previous holder.

Result: `changed`, `previous` (holder object or absent), `position` (as in `nobles.list`, after the change).

### `console.run`

Args: `command` (full console line).

The first word must be on the console allowlist. `lua` additionally needs `lua_eval`. Runs through `dfhack.run_command_silent`.

Result: `command`, `ok` (result was `CR_OK`), `result` (numeric `CR_*`), `output` (captured text).
