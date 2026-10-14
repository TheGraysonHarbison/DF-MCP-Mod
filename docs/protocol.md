# Bridge protocol

Protocol version: **3**. Bump `PROTOCOL_VERSION` in `mod/.../state.lua` and `server/src/df_mcp/__init__.py` together whenever an op's shape changes.

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
| `dig_write` | off | `dig.designate`, `dig.erase` (`dig.plan` is under `map`) |
| `map` | on | `map.bounds`, `map.wagon`, `map.tile`, `map.area`, `map.find_space` |
| `build_write` | off | `build.workshop`, `build.remove` |
| `stockpiles` | on | `stockpiles.list`, `stockpiles.get`, `stockpiles.presets` |
| `stockpiles_write` | off | `stockpiles.create`, `stockpiles.configure`, `stockpiles.rename`, `stockpiles.delete` |
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

Order row: `id`, `label` (the description the Work Orders screen shows, from `dfhack.job.getManagerOrderName`; absent on DFHack builds without it), `job` (token), `job_name` (caption), `item_type` (only when the order sets one; vanilla orders leave it unset and the job's own item attribute says what is made), `item_subtype` `{index, id, name}`, `material`, `material_category` (flag names), `reaction` `{code, name}`, `amount` `{left, total, unlimited}` (`total` 0 is unlimited), `frequency` (`OneTime`, `Daily`, `Monthly`, `Seasonally`, `Yearly`), `status` `{validated, active}`, `approved` (same as `validated`: the manager's decision, never written by the bridge), `workshop_id` (when pinned), `max_workshops` (0 unlimited), `conditions` `{items: [{compare, value, item_type, item_subtype, material, flags, text}], orders: [{order_id, condition, text}]}`, `next_check` `{year, year_tick}` for repeating orders.

### `orders.list`

Args: `query` (optional substring over job, item, material, reaction names), `approved` (optional bool), `limit` (default 25), `offset` (0). Needs a map.

Result: `total`, `count`, `offset`, `limit`, `truncated`, `orders`.

### `orders.get`

Args: `id`. Needs a map. Unknown id is `NOT_FOUND`.

Result: the row plus `raw` `{mat_type, mat_index, item_type, item_subtype}` as stored, for diagnosis.

### `orders.jobs`

Args: `query` (non-empty), `limit` (default 25, applied to each list). Needs a world.

Searches orderable job types (manufacture and similar classes, never designations or strange moods) by token or caption, and custom reactions by code or name.

Result: `query`, `jobs` `[{job, caption, class, item, possible_items, skill}]`, `jobs_total`, `reactions` `[{reaction, name, buildings}]`, `reactions_total`, `truncated`.

### `orders.create`

Args: exactly one of `job` (token or caption) or `reaction` (code or name, implies the `CustomReaction` job); `amount` (whole number, default 1, 0 unlimited); `item_type` (token; written only when given, otherwise the job's item attribute applies as in vanilla orders); `item_subtype` (raw id such as `ITEM_WEAPON_PICK` or name such as `pick`; resolved against `item_type` or, when that is absent, the job's item attribute); `material`; `material_category` (string or array of `job_material_category` flag names; the words in the table below are accepted too); `frequency` (default `OneTime`); `max_workshops` (default 0); `workshop_id`. Needs a map and `orders_write`.

`material` accepts, case-insensitively and with an optional `any ` prefix:

| Input | Stored as |
|---|---|
| `stone`, `rock`, `inorganic` | `mat_type` 0, `mat_index` -1: the generic inorganic material, which the game labels "rock" and uses for every stone order (verified 2026-10-13). There is no stone category flag. |
| `wood`, `wooden`, `bone`, `shell`, `leather`, `cloth`, `silk`, `yarn`, `wool`, `horn`, `pearl`, `tooth`, `ivory`, `plant`, `soap`, `strand` | the matching `material_category` flag, `mat_type` -1 |
| a `dfhack.matinfo.find` token (`INORGANIC:IRON`, `GRANITE`, `PLANT:PLUMP_HELMET:DRINK`), tried as given and upper-cased | that material |
| a plain inorganic name (`granite`, `silver`, `native gold`), matched against the raw id and the solid-state name and adjective | `mat_type` 0 and that raw's index |
| `any`, `none`, or absent | no material |

Anything else is `BAD_REQUEST` with up to five close inorganic names in the message.

The order is appended to `world.manager_orders.all` with the next id, the way DFHack's `workorder` script does it. `status` is left clear: the manager validates and activates it. Before insertion the handler asks `dfhack.job.getManagerOrderName` for the screen label; if it contains "unknown material" (an order that needs a material and got none), the order is discarded and the call is `BAD_REQUEST` quoting that label. Jobs that take no material, such as custom reactions and meals, pass.

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

Result: `pos`, `hidden`; for a revealed tile also `tiletype`, `caption`, `shape`, `basic_shape` (`Wall`, `Floor`, `Ramp`, `Stair`, `Open`, ...), `material` (tiletype material class), `special`, `material_name` (the stone, soil, plant, or construction material: "granite", "yellow sand", "date palm trunk"), `material_class` (`natural_stone`, `mineral_vein`, `soil`, `lava_stone`, `feature_stone`, `ice`, `construction`, `tree`, `other`), `wall_kind` (walls only: `natural`, `smoothed`, `engraved`, `constructed`, `tree`), `construction` `{item_type, material}` for constructed tiles, `engraved`, `smooth` (`smooth` or `engrave` when designated), `walkable`, `walkable_group` (0 is not walkable; equal groups are connected), `passable_low`, `passable_high`, `outside`, `subterranean`, `light`, `liquid` `{type, depth}`, `designation` (`smooth`, `pile`), `dig` (`Default`, `UpStair`, `DownStair`, `UpDownStair`, `Channel`, `Ramp` when designated), `traffic`, `occupancy` `{building, unit, item}`, `building` `{id, type, name}`, `zones`, `plant` `{id, tree, name}`, `buildable` (flat walkable floor with no building, liquid, or plant), `items` `{entries, total, truncated}`, `units`.

Material lookup (plan 11.2, a Lua copy of DFHack's `MapExtras::BlockInfo::getBaseMaterial`): veins from the block's `block_square_event_mineralst` events (last one covering the tile wins), layer stone and soil from `designation.geolayer_index` into the biome's `world_geo_biome.layers` (a stone tile on a soil layer takes the biome's first stone layer, a soil tile on a stone layer its last soil layer), lava stone from the region details, feature stone from the local or global feature's material, constructions from `dfhack.constructions.findAtTile`, trees and roots from the plant raw. Tree trunk tiletypes carry the `SMOOTH` special, so trees are classed before the special is read.

### `map.area`

Args: `x`, `y`, `z` (top-left origin), `width`, `height` (1-64, default 32), `view` (`shape` default, `material`, `designations`).

Result: `origin`, `width`, `height` (clipped at the map edge), `view`, `rows` (strings, one character per tile), `legend` (characters used), `counts`, `walkable_groups` (walkable tiles per group). Shape legend: `?` hidden, `B` building, `~` water, `%` magma, `T` tree, `#` wall, `^` ramp, `<` `>` `X` stairs, `.` floor, space open air, `*` other. The `material` view replaces `#` with one letter per distinct wall material and kind (`a` through `z`, `A` through `Z`, digits, then `#`), with the legend naming each ("granite wall", "granite wall (smoothed)", "yellow sand wall"); tree trunks show as `T`. The `designations` view draws existing orders over the shape map: `d` mine, `u` up stair, `j` down stair, `i` up/down stair, `h` channel, `r` ramp, `s` smooth, `e` engrave.

### `map.find_space`

Args: `width`, `height` (1-31, default 3), `z` (default: wagon level, else the surface at the search point), `near_x`, `near_y` (default: the wagon, else the map centre), `max_radius` (default 30).

Searches outward in square rings for a rectangle where every tile is revealed, flat floor, in one walkable group, with no building, liquid, or plant, and that passes `dfhack.buildings.checkFreeTiles`.

Result: `found`; when true `origin`, `center`, `width`, `height`, `walkable_group`, `distance`, `searched_from`, `checked`; when false `searched_from`, `max_radius`, `checked`, `note`.

### `map.exposed_walls`

Args: `z`; optional `near_x`, `near_y` (together) and `radius` (default 20) to limit the scan to a square, otherwise the whole level; `material` (substring filter on the material name); `limit` (segments, default 25).

Scans the level for revealed wall tiles with no building that have at least one orthogonal neighbour with a non-zero walkable group. Trees, roots, and tiles of class `other` are left out. Tiles are merged into straight runs along x or y (each tile joins the axis on which its run is longer) when material, kind, and open sides match.

Result: `z`, `scanned` `{x1, y1, x2, y2}`, `total_tiles`, `total_segments`, `count`, `truncated`, `segments` `[{x1, y1, x2, y2, z, length, material, material_class, kind, open_sides, floor_group}]` longest first, `tiles_by_material`, `note`.

### `map.designations`

Args: `x1`, `y1`, `z1`, `x2`, `y2`, `z2` (two corners in any order; every corner must be inside the map; at most 64 by 64 tiles per level and 32 levels), `kind` (optional: `mine`, `up_stair`, `down_stair`, `up_down_stair`, `channel`, `ramp`, `smooth`, `engrave`), `assigned_only` (default false), `limit` (default 25).

Two sources are merged (verified live 2026-10-13). Pending orders are tiles whose `tile_designation.dig` (`Default` is `mine`) or `tile_designation.smooth` (1 smooth, 2 engrave) is set. Taken orders are the entries of `world.jobs.list` whose job type has the `is_designation` attribute (`Dig`, `CarveUpwardStaircase`, `CarveDownwardStaircase`, `CarveUpDownStaircase`, `DigChannel`, `CarveRamp`, `RemoveStairs`, `SmoothWall`, `SmoothFloor`, `DetailWall`, `DetailFloor`, `CarveFortification`), keyed by their `pos`: when the game creates such a job it clears the tile's flag, so a taken order is only visible in the job list, and it reappears as a tile flag if the job is cancelled. The game queues jobs ahead of the miners, so a taken order may have no worker yet; `assigned` means `dfhack.job.getWorker` returned a dwarf.

Result: `box`, `total`, `count`, `truncated`, `counts` (per kind), `taken` (rows with a job), `assigned` (rows with a worker), `designations` `[{pos, kind, state (pending or taken), marker (blueprint mode), hidden, assigned, job {id, type, name, kind, pos, worker {id, name}}}]`, `note`.

### Digging

Namespace `dig_write` (off by default) for the writes; `dig.plan` is a read under `map`. Rules follow DFHack's quickfort dig module (checked 2026-10-13). A box is two corners in any order (`x1, y1, z1, x2, y2, z2`), every corner inside the map, at most 64 by 64 tiles per level and 32 levels.

### `dig.plan`

Args: `kind` (`mine`, `stairs`, `channel`, `ramp`, `remove_stairs`, `smooth`, `engrave`), the box. Needs a map and `map`.

Computes what `dig.designate` would do and changes nothing. Per tile, in order: no map block, map edge, an existing order or designation job (never overwritten), a building, then the kind's rule. `mine` and `ramp` need a wall or fortification that is not a construction or tree. `channel` takes walls, floors, boulders, pebbles, ramps, stairs, shrubs, and saplings. `remove_stairs` takes carved stairs and ramps. `stairs` needs a box of at least two levels: the top level gets a down stair (up/down if the tile is already an up stair), the bottom an up stair (solid rock only), the levels between up/down stairs. Hidden tiles are designated without a shape check, as the game allows. `smooth` and `engrave` write `tile_designation.smooth` (1 and 2) instead of `dig`: the tile must be revealed, a wall or floor of natural hard rock (tiletype material `STONE`, `MINERAL`, `LAVA_STONE`, `FEATURE`, or `FROZEN_LIQUID`; soil and constructions are refused), not already smooth for `smooth`, and already smooth with no entry in `world.engravings` for `engrave`.

Result: `kind`, `box`, `dry_run`, `applied`, `designated`, `skipped_existing`, `skipped_unsuitable`, `skipped_building`, `skipped_edge`, `by_level` `[{z, designated, skipped, dig}]`, `skipped` `[{pos, reason}]` (first 25), `skipped_truncated`, `blocks_marked`, `note`.

### `dig.designate`

Args and result as `dig.plan`. Needs a map and `dig_write`. Sets `tile_designation.dig` on each accepted tile, sets `designated` on every touched map block, then calls `dfhack.job.checkDesignationsNow()`. No priority is written; the game's default (4) applies.

### `dig.erase`

Args: the box, `kind` (optional: `mine`, `up_stair`, `down_stair`, `up_down_stair`, `channel`, `ramp`, `smooth`, `engrave`). Needs a map and `dig_write`.

Clears the dig and smooth flags and the blueprint marker on matching tiles, and removes the queued designation job for each with `dfhack.job.removeJob`. Dug tiles stay dug.

Result: `box`, `kind`, `cleared`, `jobs_removed`, `counts` (per kind), `note`.

### `build.workshop`

Args: `type` (a `workshop_type` or `furnace_type` token such as `Masons` or `Smelter`, or a custom building code or name), `x`, `y`, `z` (top-left corner of the footprint, as `map.find_space` returns in `origin`), `material` (optional `dfhack.matinfo.find` token). Needs a map and `build_write`.

Steps, in order: resolve the type and its size with `getCorrectSize`; scan the footprint with the same rules as `map.find_space` and then `checkFreeTiles`; build the game's default job item filters with `getFiltersByType` (restricted to `material` when given) and count usable items in play that satisfy each (`isSuitableItem` and `isSuitableMaterial`, skipping forbidden, dumped, melting, in-job, built, trader, and hostile items); then `constructBuilding` with those filters, which queues the construction job. The building is never completed by the bridge.

Result: `status` of `placed` (with `building` `{id, kind, pos, bounds}`, `requirements`), `invalid_space` (with `footprint`, `blocked_at`, `reason`), or `no_materials` (with `requirements` `[{item_type, quantity, material, flags, available}]` and `missing`). An unknown type is `NOT_FOUND` with the known types listed.

### `build.remove`

Args: `id` (building id). Needs a map and `build_write`. Only workshops and furnaces; anything else is `BAD_REQUEST`, as is a building claimed by a strange mood.

Calls `dfhack.buildings.deconstruct`: a finished building gets a deconstruction job for the dwarves, an unfinished blueprint is removed at once.

Result: `status` (`removal_queued`, `blueprint_cancelled`, `removed`, or `already_queued`), `building` `{id, kind, type, name, pos}`, `note`.

### `stockpiles.list`

Args: `category` (optional, one of `animals`, `food`, `furniture`, `corpses`, `refuse`, `stone`, `ore`, `ammo`, `coins`, `bars_blocks`, `gems`, `finished_goods`, `leather`, `cloth`, `wood`, `weapons`, `armor`, `sheet`), `limit` (default 25), `offset`. Needs a map.

Row: `id`, `number` (the game's "Stockpile #n"), `name`, `label` (name or number), `bounds`, `pos`, `tiles` (counting extents), `categories` (enabled top-level categories), `items`.

Result: `total`, `count`, `offset`, `limit`, `truncated`, `stockpiles` (by id), `counts_by_category` (whole map).

### `stockpiles.get`

Args: `id`, `limit` (contents rows, default 25). Needs a map. A building that is not a stockpile is `BAD_REQUEST`.

Result: the row plus `settings` `{categories, allow_organic, allow_inorganic, max_barrels, max_bins, max_wheelbarrows, use_links_only, details}` where `details` holds, per enabled category, its booleans and `{enabled, total}` counts for each list of sub-options; `links` `{give_to_pile, take_from_pile, give_to_workshop, take_from_workshop}` as building references; `contents` `{entries [{id, type, description, quantity}], total, truncated, by_type}` from `dfhack.buildings.getStockpileContents`.

### `stockpiles.presets`

Args: `query` (optional substring), `limit` (default 25). Lists the DFHack stockpiles plugin's bundled presets as `library/<name>` from `data/stockpiles`. Result: `total`, `count`, `truncated`, `presets`, `note`.

### `stockpiles.create`

Args: `x1`, `y1`, `x2`, `y2`, `z` (any two opposite corners, at most 31 by 31), and optionally the configuration fields of `stockpiles.configure` (`categories` as the enable list, `preset`, `preset_mode`, `name`, container limits). Needs a map and `stockpiles_write`.

The configuration arguments are validated first, so a bad category paints nothing. Every tile is checked with the map rules (revealed, flat floor, no building, liquid, or plant); then `constructBuilding{type=Stockpile, abstract=true, pos, width, height}` paints it, and the configuration is applied.

Result: `status` of `placed` (with `stockpile` row plus `settings`, and `changed`), `placed_unconfigured` (the pile exists but a configuration step failed; `error` says why), or `invalid_space` (`footprint`, `blocked_at`, `reason`).

### `stockpiles.configure`

Args: `id`, and at least one of `enable` / `disable` (category name or list; applied through DFHack's `library/cat_<name>` preset so the material lists are sized and filled as the game's own toggle does, with a manual pass as fallback; `ore` has no preset and is manual), `preset` with `preset_mode` (`set` replaces all settings, `enable` adds, `disable` removes; applied through the DFHack stockpiles plugin), `name` (up to 64 characters, converted to code page 437), `max_barrels`, `max_bins`, `max_wheelbarrows`. Needs a map and `stockpiles_write`.

Result: `changed` (list of what was applied), `stockpile` (row plus deep `settings`).

### `stockpiles.rename`

Args: `id`, `name` (empty clears). Result: `changed`, `stockpile`.

### `stockpiles.delete`

Args: `id`. Calls `dfhack.buildings.deconstruct`; an abstract building is removed at once and its items stay on the ground. Result: `status` (`deleted` or `removal_queued`), `stockpile`, `note`.

### `console.run`

Args: `command` (full console line).

The first word must be on the console allowlist. `lua` additionally needs `lua_eval`. A `claude-bridge` line only runs for the `status`, `help`, `reload`, and `test` subcommands; `perm`, `allow`, `deny`, and `enable`/`disable` style changes are refused with `NOT_ALLOWED` regardless of the allowlist, as is any line containing `;`. Runs through `dfhack.run_command_silent`.

Result: `command`, `ok` (result was `CR_OK`), `result` (numeric `CR_*`), `output` (captured text).
