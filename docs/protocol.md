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
| `stocks` | on | `stocks.bar`, `stocks.list`, `stocks.find`, `stocks.artifacts`, `stocks.status` |
| `stocks_true` | on | no ops; a toggle. Off puts the stocks ops in bookkeeper view. |
| `orders` | on | `orders.list`, `orders.get`, `orders.jobs` |
| `orders_write` | off | `orders.create`, `orders.edit`, `orders.delete` |
| `workshops` | on | `workshops.list`, `workshops.get` |
| `map` | on | `map.bounds`, `map.wagon`, `map.tile`, `map.area`, `map.find_space` |
| `console` | off | `console.run` (plus a per-command allowlist) |
| `lua_eval` | off | no ops; gates `lua` through `console.run` |

## Ops

### `core.ping`

Args: none. Works without a world.

Result: `mod_version`, `protocol_version`, `dfhack_version`, `df_version`, `world_loaded`, `map_loaded`, `fortress_mode`, `paused` (only with a map), `frame`.

### `settings.get`

Args: none.

Result: `groups` (display order: General, Units, Items, Commands), `permissions` (object of `{allowed, label, group, toggle}` keyed by namespace; `toggle` marks plain settings such as `stocks_true` that gate behaviour inside a handler rather than an op namespace), `console_allow` (array of command names), `ops` (array of `{op, namespace}`).

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

Args: `id` (unit id), `category` (string), `subcategory` (string or null), `limit` (positive int, default 25). Needs a map.

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

Args: `id`, `limit` (positive int, default 25). Needs a map.

Result: `id`, `name`, `limit`, `sheet` (object keyed by category, each shaped as the `units.sheet` `data` with no sub-category filter), `truncated`, `best_effort`. A category whose builder raises is returned as `{best_effort: true, error}` rather than failing the call.

### `units.set_nickname`

Args: `id` (unit id), `nickname` (string, up to 64 characters after trimming; empty clears). Needs a map and the `units_write` permission.

The nickname is converted from UTF-8 to code page 437 before it is stored; characters that code page lacks (for example capital Ó) become `?`. Unknown id is `NOT_FOUND`.

Result: `id`, `name` (readable name after the change), `nickname` (absent when cleared).

### `nobles.list`

Args: none. Needs a map.

Result: `entity` `{id, name}` (the site government), `count`, `positions` sorted by precedence. Each position: `id`, `code` (the token used by `nobles.assign`, e.g. `MANAGER`), `name` (gendered for the first holder), `precedence`, `number` (seats), `holders` (array of `{id, name, hist_figure_id, on_map}`; `id` absent when the holder is not a unit on this map), `slots` (array of `{slot, assignment_id, holder, squad_id}`), `vacant`, `military`, `available` (the game currently offers it on the Nobles screen), `elected`, `appointable` (available, not military, not elected, has a seat), `land_holder`, `flags`, `responsibilities`, `required` `{office, bedroom, dining, tomb, boxes, cabinets, racks, stands}`, `mandate_max`, `demand_max`, `replaced_by`.

### `nobles.assign`

Args: `position` (code or numeric id), `id` (unit id, or null to vacate), `slot` (1-based seat, optional). Needs a map and the `nobles_write` permission.

Refused with `BAD_REQUEST` when the position is military (`squad_size` above zero, `MILITARY_SCREEN_ONLY`, or a seat tied to a squad), elected (`ELECTED` flag, e.g. mayor), not yet available (no `ACTIVE` flag), when the unit is not a living citizen, or when `slot` is out of range. Unknown position or unit is `NOT_FOUND`. Appointing a unit that already holds the seat, or vacating an empty seat, is a no-op with `changed: false`.

The change mirrors what DFHack's `make-monarch` does: the assignment's `histfig` is swapped, the previous holder's position link is removed from their historical figure, and a new position link is added to the appointee. `histfig2` records the previous holder. No former-position record is written for the previous holder.

Result: `changed`, `previous` (holder object or absent), `position` (as in `nobles.list`, after the change).

### `stocks.bar`

Args: `category` (optional: `food`, `drink`, `seed`, `meat`, `fish`, `plant`, `other`). Needs a map.

The counts are `plotinfo.tasks.food`; `food` is meat + fish + plant + other. When the bookkeeper's achieved precision is below `all_accurate` the player's view is an estimate: rounded **up** to the next multiple of the precision step (10 for `NONE` and `nearest_10`, 100 for `nearest_100`, and so on) and prefixed with `~`.

Result: `mode` (`true` or `bookkeeper`), `bookkeeper` `{assigned, bookkeeper, precision, goal, cooldown, step}`, `counts` keyed by category, each `{display, estimated, shown, value}` where `value` is the true count and is present only in true mode. In bookkeeper view only the estimate is returned. With `category`, the single entry plus `category`, `mode`, and `bookkeeper`.

### `stocks.list`

Args: `category` (optional item type token such as `weapon`, `helm`, `bag`, or the game caption), `query` (optional substring matched against item kind, material, and caption), `limit` (rows per category, default 25). Needs a map.

Walks `world.items.other.IN_PLAY`, skipping items flagged `trader`, `hostile`, `garbage_collect`, `removed`, `murder`, or `construction`. Items flagged `forbid`, `dump`, `melt`, `in_building`, or `in_job` are counted but reported as unavailable. A `BOX` made of leather, silk, plant thread, or yarn is listed as `bag`. Items whose material is a creature (fish, raw fish, eggs, live vermin) report the creature's caste name as `material`.

Bookkeeper view (`stocks_true` off) while the bookkeeper's achieved precision is below `all_accurate`: the categories come from the bookkeeper's own records (`plotinfo.tasks.item_counts`), each `{name, total, display, estimated}` rounded like the top bar, with no rows; `query` is refused with `NOT_ALLOWED`, and a fort with no bookkeeper gets no categories and a `note`. Once the records are fully accurate the view equals true view.

Result: `mode`, `count` (categories), `truncated` (category keys that hit `limit`), `categories` keyed by item type token: `{name, total, unavailable, row_count, truncated, rows}` with rows `{item, material, count, quantity, unavailable}` sorted by quantity. `quantity` sums stack sizes; `count` is the number of item objects. Empty categories are omitted; an unknown or empty `category` returns `count: 0` and a `note`.

### `stocks.find`

Args: `query` (non-empty string), `limit` (default 25). Needs a map.

Result: `query`, `total`, `count`, `truncated`, `rows` (as `stocks.list` rows plus `category` and `category_name`), highest quantity first. Refused with `NOT_ALLOWED` in bookkeeper view below full accuracy.

### `stocks.artifacts`

Args: none. Needs a map.

Only artifacts on this map are listed: ones with a position, a holder unit, or a holder building. The rest of the world's artifacts are counted in `elsewhere` and never described.

Result: `count`, `elsewhere`, `artifacts` `{id, name, name_english, item_id, description, material, pos, holder {id, name}, building {id, type}}`.

### `stocks.status`

Args: none. Needs a map. Not affected by `stocks_true`.

Result: `site` `{id, name, name_english}`, `civilization` `{id, name}`, `government` `{id, name}` (the site government), `rank` `{index, name, next {name, population, created_wealth, exported_wealth}, thresholds_note}` (0 outpost to 5 metropolis; `next` absent at metropolis; thresholds are the wiki defaults, the next rank needs the population or either wealth figure), `progress` `{population, trade, production}` (the game's three ratings), `wealth` `{total, weapons, armor, furniture, other, architecture, displayed, held, imported, exported, offered}` (`total` is created wealth), `population` `{citizens, recorded, potential_soldiers, trained_animals, other_animals, carnivores, omnivores, migrant_waves}` (`citizens` is a live count, `recorded` the game's last tally), `counts` `{num_artifacts, total_deaths, total_executions, total_insanities, invaders_repelled, excavated_tiles, combat_aptitude, discovered_*_features}`.

### Work orders

Order row: `id`, `job` (token), `job_name` (caption), `item_type`, `item_subtype` `{index, id, name}`, `material`, `material_category` (flag names), `reaction` `{code, name}`, `amount` `{left, total, unlimited}` (`total` 0 is unlimited), `frequency` (`OneTime`, `Daily`, `Monthly`, `Seasonally`, `Yearly`), `status` `{validated, active}`, `approved` (same as `validated`: the manager's decision, never written by the bridge), `workshop_id` (when pinned), `max_workshops` (0 unlimited), `conditions` `{items: [{compare, value, item_type, item_subtype, material, flags, text}], orders: [{order_id, condition, text}]}`, `next_check` `{year, year_tick}` for repeating orders.

### `orders.list`

Args: `query` (optional substring over job, item, material, reaction names), `approved` (optional bool), `limit` (default 25), `offset` (0). Needs a map.

Result: `total`, `count`, `offset`, `limit`, `truncated`, `orders`.

### `orders.get`

Args: `id`. Needs a map. Unknown id is `NOT_FOUND`.

### `orders.jobs`

Args: `query` (non-empty), `limit` (default 25, applied to each list). Needs a world.

Searches orderable job types (manufacture and similar classes, never designations or strange moods) by token or caption, and custom reactions by code or name.

Result: `query`, `jobs` `[{job, caption, class, item, possible_items, skill}]`, `jobs_total`, `reactions` `[{reaction, name, buildings}]`, `reactions_total`, `truncated`.

### `orders.create`

Args: exactly one of `job` (token or caption) or `reaction` (code or name, implies the `CustomReaction` job); `amount` (whole number, default 1, 0 unlimited); `item_type` (token, defaults to the job's item); `item_subtype` (raw id such as `ITEM_WEAPON_PICK` or name such as `pick`, needs `item_type`); `material` (a `dfhack.matinfo.find` token); `material_category` (string or array of `job_material_category` flag names); `frequency` (default `OneTime`); `max_workshops` (default 0); `workshop_id`. Needs a map and `orders_write`.

The order is appended to `world.manager_orders.all` with the next id, the way DFHack's `workorder` script does it. `status` is left clear: the manager validates and activates it.

Result: `created`, `order` (row).

### `orders.edit`

Args: `id`, and at least one of `amount` (keeps completed progress: left = new total minus done), `frequency`, `max_workshops`, `workshop_id` (-1 clears). Needs a map and `orders_write`.

Result: `changed` (field names), `order`.

### `orders.delete`

Args: `id`. Needs a map and `orders_write`.

Result: `deleted`, `order` (as it was).

### `workshops.list`

Args: `type` (optional: a `workshop_type` or `furnace_type` token such as `Kitchen` or `Smelter`, a custom building code or name, or `workshop`/`furnace`), `limit` (default 25), `offset` (0). Needs a map.

Walks `world.buildings.other.WORKSHOP_ANY` and `FURNACE_ANY`.

Row: `id`, `kind` (`workshop` or `furnace`), `type`, `name`, `custom_name`, `pos` `{x,y,z}` (centre), `bounds` `{x1,y1,x2,y2,z}`, `built` (build stage complete), `jobs` (count), `strange_mood` (a job of the strange mood class is queued there), `items` (count).

Result: `total`, `count`, `offset`, `limit`, `truncated`, `workshops` (sorted by type then id), `counts_by_type` (whole map), and a `note` listing the types present and all known types when a filter matched nothing.

### `workshops.get`

Args: `id` (building id), `limit` (default 25). Needs a map. A building that is not a workshop or furnace is `BAD_REQUEST`.

Result: the row plus `jobs` `[{id, name, job, order_id, flags, worker {id, name}, strange_mood}]`, `inventory` `{entries, total, truncated}` of items in the workshop (`{id, description, quantity, flags}`), `materials` (the same shape, the items it was built from), `profile` `{permitted_workers, min_level, max_level, flags}`, `truncated` (section names that hit `limit`).

### Map

Coordinates are tile coordinates: `x` west to east, `y` north to south, `z` upward. Every op needs a map. Out-of-range coordinates are `BAD_REQUEST` with the valid ranges. Hidden tiles (not yet revealed to the player) are reported as hidden only.

### `map.bounds`

Args: none. Result: `x`, `y`, `z` `{min, max}`, `width`, `height`, `depth`, `center`, `surface_z_at_center` (highest outdoor floor or ramp in that column), `wagon_z`.

### `map.wagon`

Args: none. Result: `present`, and when present `id`, `pos` (centre), `bounds`; otherwise `center` (map centre at surface level) and a `note`.

### `map.tile`

Args: `x`, `y`, `z`, `limit` (items on the tile, default 25).

Result: `pos`, `hidden`; for a revealed tile also `tiletype`, `caption`, `shape`, `basic_shape` (`Wall`, `Floor`, `Ramp`, `Stair`, `Open`, ...), `material` (tiletype material class), `special`, `walkable`, `walkable_group` (0 is not walkable; equal groups are connected), `passable_low`, `passable_high`, `outside`, `subterranean`, `light`, `liquid` `{type, depth}`, `designation` (`smooth`, `pile`), `dig`, `traffic`, `occupancy` `{building, unit, item}`, `building` `{id, type, name}`, `zones`, `plant` `{id, tree, name}`, `buildable` (flat walkable floor with no building, liquid, or plant), `items` `{entries, total, truncated}`, `units`.

### `map.area`

Args: `x`, `y`, `z` (top-left origin), `width`, `height` (1-64, default 32).

Result: `origin`, `width`, `height` (clipped at the map edge), `rows` (strings, one character per tile), `legend` (characters used), `counts`, `walkable_groups` (walkable tiles per group). Legend: `?` hidden, `B` building, `~` water, `%` magma, `T` tree, `#` wall, `^` ramp, `<` `>` `X` stairs, `.` floor, space open air, `*` other.

### `map.find_space`

Args: `width`, `height` (1-31, default 3), `z` (default: wagon level, else the surface at the search point), `near_x`, `near_y` (default: the wagon, else the map centre), `max_radius` (default 30).

Searches outward in square rings for a rectangle where every tile is revealed, flat floor, in one walkable group, with no building, liquid, or plant, and that passes `dfhack.buildings.checkFreeTiles`.

Result: `found`; when true `origin`, `center`, `width`, `height`, `walkable_group`, `distance`, `searched_from`, `checked`; when false `searched_from`, `max_radius`, `checked`, `note`.

### `console.run`

Args: `command` (full console line).

The first word must be on the console allowlist. `lua` additionally needs `lua_eval`. A `claude-bridge` line only runs for the `status`, `help`, `reload`, and `test` subcommands; `perm`, `allow`, `deny`, and `enable`/`disable` style changes are refused with `NOT_ALLOWED` regardless of the allowlist, as is any line containing `;`. Runs through `dfhack.run_command_silent`.

Result: `command`, `ok` (result was `CR_OK`), `result` (numeric `CR_*`), `output` (captured text).
