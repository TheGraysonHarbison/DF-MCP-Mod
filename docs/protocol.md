# Bridge protocol

Protocol version: **22**. Bump `PROTOCOL_VERSION` in `mod/.../state.lua` and `server/src/df_mcp/__init__.py` together whenever an op's shape changes.

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
| `messages` | always allowed | `messages.say`, `messages.badges` |
| `settings` | on | `settings.get` |
| `time` | on | `time.now` |
| `pause_write` | off | `time.set_pause` |
| `events` | on | `events.kinds`, `events.poll`, `events.emit`, `timer.status` |
| `plan` | on | `plan.info`, `plan.read`, `plan.write`, `plan.append`, `goals.read` |
| `units` | on | `units.list`, `units.find`, `units.get`, `units.sheet`, `units.full_sheet` |
| `units_write` | off | `units.set_nickname` |
| `nobles` | on | `nobles.list` |
| `nobles_write` | off | `nobles.assign` |
| `military` | on | `military.list`, `military.get`, `military.routes`, `military.equipment` |
| `military_write` | off | `military.create`, `military.rename`, `military.set_symbol`, `military.add`, `military.remove`, `military.set_leader`, `military.disband`, `military.order`, `military.set_routine`, `military.create_route`, `military.set_uniform`, `military.set_ammo` |
| `stocks` | on | `stocks.bar`, `stocks.list`, `stocks.find`, `stocks.artifacts`, `stocks.status`, `build.materials`, `kitchen.list` |
| `kitchen_write` | off | `kitchen.set` |
| `stocks_true` | on | no ops; a toggle. Off puts the stocks ops in bookkeeper view. |
| `orders` | on | `orders.list`, `orders.get`, `orders.jobs` |
| `orders_write` | off | `orders.create`, `orders.edit`, `orders.delete` |
| `workshops` | on | `workshops.list`, `workshops.get`, `build.plan_construction`, `build.plan_furniture`, `build.list`, `farms.list`, `farms.get` |
| `zones` | on | `zones.list`, `zones.get` |
| `zones_write` | off | `zones.create`, `zones.edit`, `zones.assign`, `zones.unassign`, `zones.delete` |
| `dig_write` | off | `dig.designate`, `dig.erase` (`dig.plan` is under `map`) |
| `map` | on | `map.bounds`, `map.wagon`, `map.tile`, `map.area`, `map.find_space`, `map.exposed_walls`, `map.designations`, `map.plants` |
| `build_write` | off | `build.workshop`, `build.remove`, `build.construct`, `build.place`, `build.suspend`, `build.remove_constructions`, `farms.set_crops` |
| `trade` | on | `trade.caravans`, `trade.depot`, `trade.broker`, `trade.screen` |
| `trade_write` | off | `trade.request_broker`, `trade.bring`, `trade.unbring`, `trade.offer`, `trade.select` |
| `stockpiles` | on | `stockpiles.list`, `stockpiles.get`, `stockpiles.presets` |
| `stockpiles_write` | off | `stockpiles.create`, `stockpiles.configure`, `stockpiles.rename`, `stockpiles.delete` |
| `console` | off | `console.run` (plus a per-command allowlist) |
| `lua_eval` | off | no ops; gates `lua` through `console.run` |

## Ops

### Events

The mod queues in-game events (plan section 13, Phase 13) and the server pushes them to Claude Code as channel notifications (`notifications/claude/channel`, declared through the experimental `claude/channel` capability at the handshake). The queue is a ring of 200 entries; `events.poll` hands out a batch once the newest waiting event is two seconds old or 50 are waiting. Each kind has a player toggle (settings window, Events tab, or `claude-bridge event <kind> on|off`); defaults on: `mineral_discovered`, `units_fighting`, `petition`.

Sources: `eventful.onReport` (announcements mapped by `announcement_type` to kinds; continuation lines skipped; units standing on the report's position are attached), `onUnitDeath` (citizens, `citizen_dead`), `onInvasion` (`invaders_arrived`), `onUnitAttack` (`units_fighting`, or `sparring` when both units are fort-controlled; one event per unit pair per ten seconds), and a poller every 100 ticks for `petition` (new ids in `plotinfo.petitions`), `ghost_appeared` and `ghost_rested` (the set of ghost units), `mood_item_missing` (citizens whose strange-mood job stalled waiting for an item), `artifact_found` (artifact items on the map whose tile became revealed), and `season_changed` (`cur_season`). The poller's first run only records a baseline. Hooks are installed on enable and reload and removed on disable; the queue is cleared on map unload.

### `events.kinds`

Args: none. Namespace `events`.

Result: `kinds` `[{key, label, enabled, default, source (announcement, hook, attack hook, poll), announcement_types, missing_types (names this build lacks)}]`, `running`, `queued`, `next_seq`, `dropped`.

### `events.poll`

Args: `after_seq` (the last sequence the caller has; omit to learn `next_seq` without taking anything), `limit` (default 50), `force` (return what is waiting without the quiet window). Namespace `events`.

Result: `next_seq`, `dropped`, `now_ms`, `running`, `tick`, `waiting`, `events` `[{seq, kind, tick, text, pos, unit_ids, building_id, item_id, extra}]` (empty with `quiet_ms_left` while the window runs), `last_seq`, `remaining`. Verified in-game 2026-10-15.

### `events.emit`

Args: `kind` (an event kind, or `test`), `text`, `pos`. Namespace `events`. Queues one event by hand (disabled kinds are refused with `queued: false`); used by tests and by the goals and timer features. Result: `queued`, `seq`.

### Plan and goals

Two Markdown files in the current save, `<save>/claude-df/plan.md` (Claude's) and `goals.md` (the player's), created empty on enable (`dfhack.getSavePath()` is the region folder, `save/<name>/`, verified 2026-10-15). Files are UTF-8; the ops convert through CP437 on the way out so the dispatcher's UTF-8 conversion returns the file unchanged (characters outside CP437 are lost). Writes arrive as UTF-8 and are stored as given. The goal prompt lives in the mod's settings (`goal_prompt`, default in `plan.lua`), edited in the `claude-bridge goals` window, whose Ctrl+S queues a `goals` event (a special kind that ignores the per-kind toggles) carrying the prompt with `{Put Goals Here}` replaced by the goals; the server delivers that batch as the message itself. Nothing is sent on edit or close.

### `plan.info`

Args: none. Needs a world. Result: `folder`, `save_folder`, `plan {name, exists, bytes}`, `goals {...}`, `max_bytes` (65536), `goal_prompt`.

### `plan.read`, `goals.read`

Args: none. Needs a world. Result: `file`, `text`, `bytes`.

### `plan.write`

Args: `text` (at most 65536 bytes). Needs a world. Replaces the plan. Result: `file`, `bytes`, `replaced`.

### `plan.append`

Args: `text`. Needs a world. Appends with a newline before and after as needed; refused with `BAD_REQUEST` when the file would pass the cap. Result: `file`, `bytes`, `appended`. All verified in-game 2026-10-15.

### `messages.say`

Args: `text` (non-empty, at most 200 characters after whitespace is collapsed), `x`, `y`, `z` (optional, together), `badge` (`rumor` default, `general`, `research`, `guest`, `masterpiece`, `noble`, `era`, `holdings`, `deity`, `agreement`). Needs a map. Namespace `messages`, always allowed.

Calls `dfhack.gui.makeAnnouncement(type, {D_DISPLAY, A_DISPLAY}, pos, text, COLOR_RED, bright)` with an announcement type of the badge's alert category (`RUMOR_SPREAD` for `rumor`, `REACHED_PEAK` for `general`, and so on), which writes the report into the announcement log and the left-side alert stack with that category's icon. With a position the report's `zoom_type` is set to `Generic` so the alert's click zooms there. No pause, no immediate recenter, and the texture cache is never touched (rule 13). Light red (red, bright) is the Steam palette's closest colour to orange. Identical repeated text within the same alert category is counted by the game as a repeat rather than a new line.

Result: `text`, `badge`, `announcement_type`, `pos`, `report_id`, `index`, `note`.

### `messages.badges`

Args: none. Result: `badges` `[{badge, announcement_type}]`, `default`, `max_chars`.

### `timer.status`

Args: none. Namespace `events`.

The prompt timer (Phase 15) runs a `frames` repeat every 30 frames. Settings (`timer` in the mod's settings file, edited on the settings Timer tab or with `claude-bridge timer`): `enabled` (default off), `mode` (`days`: N in-game days as 1200 ticks each on `world.frame_counter`; `month`: a change of `cur_year_tick // 33600`; `minutes`: N real minutes accumulated from `dfhack.getTickCount()` only while unpaused), `interval` (default 7), `prompt` (default "# Update ..."). When due it queues a `timer` event (a special kind, prompt text as content, delivered whole) unless one is still waiting, and re-arms. Every batch `events.poll` hands out re-arms it; a map unload stops it.

Result: `enabled`, `mode`, `interval`, `prompt`, `running`, `fired`, `last_fired_tick`, `progress` (`armed`, `mode`, `interval`, `since`, and `elapsed_days`/`remaining_days`, `months_passed`, or `elapsed_minutes`/`remaining_minutes`), `paused`, `modes`, `note`.

### `core.ping`

Args: none. Works without a world.

Result: `mod_version`, `protocol_version`, `dfhack_version`, `df_version`, `world_loaded`, `map_loaded`, `fortress_mode`, `paused` (only with a map), `frame`.

### `settings.get`

Also returns `events`: every event kind with its enabled state.

Args: none.

Result: `groups` (display order: General, Units, Items, Commands), `permissions` (object of `{allowed, label, group, toggle}` keyed by namespace; `toggle` marks plain settings such as `stocks_true` that gate behaviour inside a handler rather than an op namespace), `console_allow` (array of command names), `ops` (array of `{op, namespace}`).

### `time.now`

Args: none. Needs a map.

Result: `year`, `month` (1-12), `month_name`, `day` (1-28), `day_of_year`, `season` (spring, summer, autumn, winter), `season_day` (1-84), `hour`, `minute`, `year_tick`, `frame`, `paused`, `weather` (`None`, `Rain`, `Snow`, or null), `fort_name`, `unsaved_seconds`, `date_string`.

### `time.set_pause`

Args: `paused` (boolean, required). Needs a map and `pause_write`.

Calls `dfhack.world.SetPauseState(paused)`. `ReadPauseState` before and after gives the result; it also reports true while the player is single-stepping. The RPC call suspends the core only for its own duration, so the new state holds once the call returns.

Result: `paused_before`, `paused` (state after the call), `changed`, `frame`, `note`.

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

### Military

Squads are `df.squad` records listed by id in the fort entity's `squads` vector. DFHack's military module (`dfhack.military.makeSquad`, `addToSquad`, `removeFromSquad`, `getSquadName`, `updateRoomAssignments`; checked 2026-10-15 against Military.cpp) covers creation and membership; the leader slot and disbanding are the mod's own, mirroring the inverse paths in that code.

### `military.list`

Args: `limit` (default 25). Needs a map. Namespace `military`.

Result: `count`, `total`, `truncated`, `squads` `[{id, name (nickname, else the translated name, else "Squad n"), nickname, kind (melee, crossbow, unarmed: from the weapon slot specs; a ranged weapon or ranged individual choice makes crossbow), members, slots, leader {id, name, hist_figure_id}, routine (name of plotinfo.alerts.routines[cur_routine_idx]), training, orders, symbol, foreground, background}]`, `vacant_positions` `[{assignment_id, position (code), name, squad_size, holder, guard}]` (fort position assignments with `squad_size` above zero and `squad_id` -1; militia seats sort before the captain of the guard), `routines` `[{index, id, name}]`, `presets` `[{id, name, type, slots}]` from the fort entity's `uniforms`, `note`.

### `military.get`

Args: `id`. Needs a map. Namespace `military`.

Result: the list row plus `positions` `[{slot, leader, unit, uniform {body, head, pants, gloves, shoes, shield, weapon: [{item_type, item, material_class, material, individual_choice, specific_item, assigned}]}, exact_matches, replace_clothing, assigned_items}]`, `ammunition` `[{item, material_class, amount, combat, training, assigned}]`, `rooms` `[{zone_id, modes}]`, `supplies` `{carry_food, carry_water}`.

### `military.create`

Args: `name` (nickname, optional), `kind` (`melee` or `crossbow`, optional), `preset` (a uniform preset name, optional; overrides `kind`), `position` (a position code such as `MILITIA_COMMANDER`, `MILITIA_CAPTAIN`, `CAPTAIN_OF_THE_GUARD`, or an assignment id; optional). Needs a map and `military_write`.

Picks the first vacant militia seat (or the named one); when no militia seat is free, or `MILITIA_CAPTAIN` is asked for, a new militia captain assignment is allocated from the entity's `next_assignment_id` the way the game adds one per extra squad. Calls `makeSquad` on it, sets `alias`, copies the preset into every slot (the preset for a kind is the first fort uniform whose name contains "metal armor", "armor", or "leather" for melee, "archer", "ranged", or "crossbow" for crossbow; the vanilla names are "Melee, leather armor", "Melee, metal armor", "Crossbows, leather armor", "Crossbows, metal armor"), adds 100 bolts for combat and training to a crossbow squad, and sets the equipment update flags. A seat the game already appointed a dwarf to (`holder`) makes that dwarf the leader. Refused with `BAD_REQUEST` when no seat is free.

Result: the list row plus `position`, `preset`, `warnings`, `note`. Verified in-game 2026-10-15.

### `military.rename`

Args: `id`, `name` (empty clears). Needs a map and `military_write`. Sets `squad.alias`. Result: the list row plus `previous`.

### `military.set_symbol`

Args: `id`, `symbol` (0 to 22, the index on the vanilla squad symbol sheet, row-wise; graphics mode only), `foreground` and `background` (`[r, g, b]`, 0 to 255); at least one. Needs a map and `military_write`. Writes `squad.symbol` and the `foreground_*` and `background_*` bytes and nothing else: the squad's cached badge textures (`solid_texpos`, `blended_texpos`) are never touched because resetting them crashed the game (2026-10-15, rule 13), so the badge on screen may keep its old look until the game redraws it. The list row carries `symbol`, `foreground`, `background`. Result: the list row plus `previous`, `note`.

### `military.add`

Args: `id`, `unit_id` (a living adult citizen not in a squad), `slot` (optional, 0 to slots-1). Needs a map and `military_write`.

`addToSquad` with the slot or -1 (first free slot after the leader's). Slot 0, or any add to a squad with no leader, goes through `military.set_leader` instead. Result: the list row plus `added`, `slot`.

### `military.remove`

Args: `id`, `unit_id`. Needs a map and `military_write`. `removeFromSquad`: for the leader this also vacates the seat's holder and archives the position link. Result: the list row plus `removed`, `was_leader`.

### `military.set_leader`

Args: `id`, `unit_id`. Needs a map and `military_write`.

The current leader (if another dwarf) is removed through `removeFromSquad`; a member moving up leaves their slot first. Then: slot 0 `occupant`, the unit's `military.squad_id` and `squad_position`, a `histfig_entity_link_squadst` at position 0 on the historical figure, the leading assignment's `histfig` (previous holder to `histfig2`), and a `histfig_entity_link_positionst` for that assignment unless the figure already carries one (a dwarf the game appointed keeps theirs), plus the equipment update flags. Result: the list row plus `changed`, `previous_leader`, `assignment_updated`. Verified in-game 2026-10-15: the new leader's name reads "militia commander" afterwards.

### `military.disband`

Args: `id`. Needs a map and `military_write`.

Every member is removed through `removeFromSquad` (the leader last, which vacates the seat), barracks links are dropped with `updateRoomAssignments(squad, zone, {})`, the assignment's `squad_id` is cleared, the id is erased from the fort entity's `squads` and the squad from `world.squads.all`, and the record deleted. Result: `{id, name, disbanded, members_removed, rooms_detached}`.

### `military.order`

Args: `id`, `kind` (`station` with `x`, `y`, `z` on a walkable tile; `kill` with `unit_ids` (non-citizens) and optional `title`; `patrol` with `route_id`; `cancel`). Needs a map and `military_write`.

No DFHack code issues squad orders; this writes what the game's squad screen writes: every existing order in `squad.orders` and each position's `orders` is erased, then one new `squad_order_movest` (`pos`, `point_id` -1), `squad_order_kill_listst` (`units`, `histfigs`, `title`), or `squad_order_patrol_routest` (`route_id`) is appended to `squad.orders` with `issuer_hf` and `recipient_hf` -1, `year`, `year_tick`, and `origin_army_controller` -1. A squad with no members is refused for anything but `cancel`.

Result: the list row plus `kind`, `cancelled` (orders removed), `orders` (`[{kind, type, pos | units | route_id, title, year, year_tick, complete}]`, also on `military.get`), `note`. Verified in-game 2026-10-15: a station order moved both soldiers to the tiles beside the target within twenty seconds of play; a patrol order along a two-point route moved them likewise.

### `military.set_routine`

Args: `id`, `routine` (a name or index from `military.list`). Needs a map and `military_write`. Sets `squad.cur_routine_idx`; training routines need a barracks. Result: the list row plus `previous`.

### `military.routes`

Args: none. Needs a map. Namespace `military`. Result: `count`, `routes` `[{id, name, points [{id, name, pos}]}]` from `plotinfo.waypoints`.

### `military.create_route`

Args: `name` (optional), `points` (at least two `{x, y, z}` on walkable tiles). Needs a map and `military_write`. Appends a `pointst` per point (ids from `next_point_id`, tile `X`, white on black, named after the route) and a `routest` (id from `next_route_id`) listing them. Result: `{id, name, points, count}`.

### `military.equipment`

Args: `id`. Needs a map. Namespace `military`.

Result: the list row plus `positions` `[{slot, leader, unit, uniform (as military.get), exact_matches, replace_clothing, assigned_items [{id, description}], soldier {mode (unit.uniform.cur_uniform), carried [{id, description}] (unit.uniform.uniforms[mode]), missing [...] (uniform_pickup), worn [{id, description, mode}] (inventory entries worn or wielded)}}]`, `ammunition`, `material_classes`, `note`. Lists are capped at 25. Verified in-game 2026-10-15.

### `military.set_uniform`

Args: `id`, `category` (`body`, `head`, `pants`, `gloves`, `shoes`, `shield`, `weapon`), `item` (an item definition name such as "breastplate", "helm", "crossbow", matched against the category's `world.raws.itemdefs` vector by name, plural, or id; "any" for the type with no subtype; for `weapon` also "melee", "ranged", or "any" for the individual choice flags), `material_class` (`any`, `metal`, `leather`, `cloth`, `wood`, `bone`, `shell`; `metal` becomes `Armor` for armor slots and `WeaponMelee` or `WeaponRanged` for weapons by the definition's `ranged_ammo`), `add` (append instead of replace), `clear`, `exact_matches`, `replace_clothing`, `position` (one slot instead of all). Needs a map and `military_write`.

Writes `squad_uniform_spec` entries (`item` -1, never a specific item) into each position's category vector and the flags, then sets the equipment update flags on the squad and the fort. Unknown items are `NOT_FOUND` with the category's names.

Result: the list row plus `category`, `positions_changed`, `specs_written`, `spec {item, material_class}`, `uniform` (the first changed position's). Verified in-game 2026-10-15.

### `military.set_ammo`

Args: `id`, `item` (an ammunition definition name such as "bolts"), `amount` (default 100), `material_class` (`any`, `metal` (AmmoMetal), `wood`, `bone`), `combat` and `training` (default true), `add`, `clear`. Needs a map and `military_write`.

Writes `squad_ammo_spec` entries into `squad.ammo.ammunition` (replacing the list unless `add`) and sets the update flags. Result: the list row plus `ammunition`.

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

### `kitchen.list`

Args: `category` (optional: `plants`, `seeds`, `drinks`, `other`), `query` (optional substring matched against name, material token, and item type), `banned_only` (default false), `limit` (rows per category, default 25). Needs a map. Namespace `stocks`; not affected by `stocks_true`.

Walks `world.items.other.IN_PLAY`, skipping items flagged dump, forbid, garbage_collect, hostile, on_fire, rotten, trader, in_building, construction, artifact, removed, owned, encased, or spider_web, and keys each item by (item type, subtype, material). Growths carry their growth index as the subtype; creature-caste items (fish, eggs) key on race and caste. A row is listed when its material can be cooked (`EDIBLE_COOKED`) or brewed (a `DRINK_MAT` reaction product), or when the item is a plant, growth, seed, or drink. Only ingredients in stock are listed, as the game's Kitchen screen does. `cook_banned` and `brew_banned` come from `dfhack.kitchen.findExclusion` over `plotinfo.kitchen`; the game bans cooking of every seed type by default, which reads back as `cook_banned`.

Result: `count`, `exclusions` (rows in `plotinfo.kitchen`), `truncated` (categories that hit `limit`), `note`, `categories` keyed by tab, each `{row_count, truncated, rows}` with rows `{key, item_type, subtype, material, name, category, cookable, brewable, cook, brew, cook_banned, brew_banned, count, quantity}` sorted by quantity. `key` is `ITEM_TYPE:subtype:mat_type:mat_index`. Verified in-game 2026-10-15.

### `kitchen.set`

Args: either `key` (from `kitchen.list`) or `item_type` (token such as `PLANT`, `SEEDS`, `DRINK`, `PLANT_GROWTH`, `MEAT`) with `material` (a material token such as `PLANT_MAT:MUSHROOM_HELMET_PLUMP:STRUCTURAL`, or a plant name such as "plump helmet", which resolves to the plant's structural, seed, or drink material to match the item type) and optional `subtype` (growth index, default -1); plus `cook` and/or `brew` as booleans (true allows, false bans; absent leaves it). Needs a map. Namespace `kitchen_write`.

Each flag is applied through `dfhack.kitchen.addExclusion` or `removeExclusion`; a no-op (already banned or already allowed) is not listed in `changed`. Allowing cooking or brewing of an ingredient the game never cooks or brews succeeds with a warning. An unparseable key or unknown item type is `BAD_REQUEST`; an unknown material is `NOT_FOUND`.

Result: `changed` (subset of `cook`, `brew`), `before` and `after` (the row without counts), `warnings`. Verified in-game 2026-10-15.

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

Result: `pos`, `hidden`; for a revealed tile also `tiletype`, `caption`, `shape`, `basic_shape` (`Wall`, `Floor`, `Ramp`, `Stair`, `Open`, ...), `material` (tiletype material class), `special`, `material_name` (the stone, soil, plant, or construction material: "granite", "yellow sand", "date palm trunk"), `material_class` (`natural_stone`, `mineral_vein`, `soil`, `lava_stone`, `feature_stone`, `ice`, `construction`, `tree`, `other`), `wall_kind` (walls only: `natural`, `smoothed`, `engraved`, `constructed`, `tree`), `construction` `{item_type, material}` for constructed tiles, `engraved`, `smooth` (`smooth` or `engrave` when designated), `walkable`, `walkable_group` (0 is not walkable; equal groups are connected), `passable_low`, `passable_high`, `outside`, `subterranean`, `light`, `liquid` `{type, depth}`, `designation` (`smooth`, `pile`), `dig` (`Default`, `UpStair`, `DownStair`, `UpDownStair`, `Channel`, `Ramp` when designated), `traffic`, `occupancy` `{building, unit, item}`, `building` `{id, type, name, built}` (a planned building occupies its tiles before it is built; `built` says whether it is finished), `zones`, `plant` `{id, tree, name}`, `buildable` (flat walkable floor with no building, liquid, or plant), `items` `{entries, total, truncated}`, `units`.

Material lookup (plan 11.2, a Lua copy of DFHack's `MapExtras::BlockInfo::getBaseMaterial`): veins from the block's `block_square_event_mineralst` events (last one covering the tile wins), layer stone and soil from `designation.geolayer_index` into the biome's `world_geo_biome.layers` (a stone tile on a soil layer takes the biome's first stone layer, a soil tile on a stone layer its last soil layer), lava stone from the region details, feature stone from the local or global feature's material, constructions from `dfhack.constructions.findAtTile`, trees and roots from the plant raw. Tree trunk tiletypes carry the `SMOOTH` special, so trees are classed before the special is read.

### `map.area`

Args: `x`, `y`, `z` (top-left origin), `width`, `height` (1-64, default 32), `view` (`shape` default, `material`, `designations`).

Result: `origin`, `width`, `height` (clipped at the map edge), `view`, `rows` (strings, one character per tile), `legend` (characters used), `counts`, `walkable_groups` (walkable tiles per group). Shape legend: `?` hidden, `B` building, `~` water, `%` magma, `T` tree, `#` wall, `^` ramp, `<` `>` `X` stairs, `.` floor, space open air, `*` other. The `material` view replaces `#` with one letter per distinct wall material and kind (`a` through `z`, `A` through `Z`, digits, then `#`), with the legend naming each ("granite wall", "granite wall (smoothed)", "yellow sand wall"); tree trunks show as `T`. The `designations` view draws existing orders over the shape map: `d` mine, `u` up stair, `j` down stair, `i` up/down stair, `h` channel, `r` ramp, `s` smooth, `e` engrave; the same letter in upper case marks an order the game has already turned into a job (see `map.designations`), including on hidden tiles.

### `map.find_space`

Args: `width`, `height` (1-31, default 3), `z` (default: wagon level, else the surface at the search point), `near_x`, `near_y` (default: the wagon, else the map centre), `max_radius` (default 30).

Searches outward in square rings for a rectangle where every tile is revealed, flat floor, in one walkable group, with no building, liquid, or plant, and that passes `dfhack.buildings.checkFreeTiles`.

Result: `found`; when true `origin`, `center`, `width`, `height`, `walkable_group`, `distance`, `searched_from`, `checked`; when false `searched_from`, `max_radius`, `checked`, `note`.

### `map.exposed_walls`

Args: `z`; optional `near_x`, `near_y` (together) and `radius` (default 20) to limit the scan to a square, otherwise the whole level; `material` (substring filter on the material name); `limit` (segments, default 25).

Scans the level for revealed wall tiles with no building that have at least one orthogonal neighbour with a non-zero walkable group. Trees, roots, and tiles of class `other` are left out. Tiles are merged into straight runs along x or y (each tile joins the axis on which its run is longer) when material, kind, and open sides match.

Result: `z`, `scanned` `{x1, y1, x2, y2}`, `total_tiles`, `total_segments`, `count`, `truncated`, `segments` `[{x1, y1, x2, y2, z, length, material, material_class, kind, open_sides, floor_group}]` longest first, `tiles_by_material`, `note`.

### `map.designations`

Args: `x1`, `y1`, `z1`, `x2`, `y2`, `z2` (two corners in any order; every corner must be inside the map; at most 64 by 64 tiles per level and 32 levels), `kind` (optional: `chop`, `gather`, `mine`, `up_stair`, `down_stair`, `up_down_stair`, `channel`, `ramp`, `smooth`, `engrave`), `assigned_only` (default false), `limit` (default 25). A `Default` dig flag on a tree tile reads as `chop` and on a shrub tile as `gather`; `FellTree` and `GatherPlants` jobs map to the same kinds.

Two sources are merged (verified live 2026-10-13). Pending orders are tiles whose `tile_designation.dig` (`Default` is `mine`) or `tile_designation.smooth` (1 smooth, 2 engrave) is set. Taken orders are the entries of `world.jobs.list` whose job type has the `is_designation` attribute (`Dig`, `CarveUpwardStaircase`, `CarveDownwardStaircase`, `CarveUpDownStaircase`, `DigChannel`, `CarveRamp`, `RemoveStairs`, `SmoothWall`, `SmoothFloor`, `DetailWall`, `DetailFloor`, `CarveFortification`), keyed by their `pos`: when the game creates such a job it clears the tile's flag, so a taken order is only visible in the job list, and it reappears as a tile flag if the job is cancelled. The game queues jobs ahead of the miners, so a taken order may have no worker yet; `assigned` means `dfhack.job.getWorker` returned a dwarf.

Result: `box`, `total`, `count`, `truncated`, `counts` (per kind), `taken` (rows with a job), `assigned` (rows with a worker), `designations` `[{pos, kind, state (pending or taken), marker (blueprint mode), hidden, assigned, job {id, type, name, kind, pos, worker {id, name}}}]`, `note`.

### `map.plants`

Args: a box (`x1`..`z2`, any levels) or `circle` `{x, y, z, radius}`, `kind` (optional: `tree`, `shrub`, `sapling`), `query` (species substring), `marked_only` (default false), `limit` (default 25). Needs a map.

Walks `world.plants.all` and keeps plants whose base position is in the shape. A plant with a `tree_info` is a tree; a tree species without one is a sapling; the rest are shrubs. `marked` comes from `dfhack.designations.isPlantMarked` (a `Default` dig flag on the plant's designation tile, or a `FellTree` or `GatherPlants` job there).

Result: `box`, `shape`, `total`, `count`, `truncated`, `counts` (per kind), `species` (name to count), `plants` `[{pos, kind, species, dead, marked, size {width, depth, height} (trees), designation_tile (trees)}]`, `note`. Verified in-game 2026-10-15.

### Digging

Namespace `dig_write` (off by default) for the writes; `dig.plan` is a read under `map`. Rules follow DFHack's quickfort dig module (checked 2026-10-13). A box is two corners in any order (`x1, y1, z1, x2, y2, z2`), every corner inside the map, at most 64 by 64 tiles per level and 32 levels.

### `dig.plan`

Args: `kind` (`mine`, `stairs`, `channel`, `ramp`, `remove_stairs`, `smooth`, `engrave`), and either the box or `circle` `{x, y, z, radius}` (one level, radius 1 to 31, a tile is inside when `dx*dx + dy*dy <= r*r + r`, the whole circle must be inside the map; refused for `stairs`). Needs a map and `map`.

Computes what `dig.designate` would do and changes nothing. Per tile, in order: no map block, map edge, an existing order or designation job (never overwritten), a building, then the kind's rule. `mine` and `ramp` need a wall or fortification that is not a construction or tree. `channel` takes walls, floors, boulders, pebbles, ramps, stairs, shrubs, and saplings. `remove_stairs` takes carved stairs and ramps. `stairs` needs a box of at least two levels: the top level gets a down stair (up/down if the tile is already an up stair), the bottom an up stair (solid rock only), the levels between up/down stairs. Hidden tiles are designated without a shape check, as the game allows. `smooth` and `engrave` write `tile_designation.smooth` (1 and 2) instead of `dig`: the tile must be revealed, a wall or floor of natural hard rock (tiletype material `STONE`, `MINERAL`, `LAVA_STONE`, `FEATURE`, or `FROZEN_LIQUID`; soil and constructions are refused), not already smooth for `smooth`, and already smooth with no entry in `world.engravings` for `engrave`.

Result: `kind`, `box` (for a circle: its bounding box plus `center` and `radius`), `shape` (`box` or `circle`), `dry_run`, `applied`, `designated`, `skipped_existing`, `skipped_unsuitable`, `skipped_building`, `skipped_edge`, `by_level` `[{z, designated, skipped, dig}]`, `skipped` `[{pos, reason}]` (first 25), `skipped_truncated`, `blocks_marked`, `note`.

### `dig.designate`

Args and result as `dig.plan`. Needs a map and `dig_write`. Sets `tile_designation.dig` on each accepted tile, sets `designated` on every touched map block, then calls `dfhack.job.checkDesignationsNow()`. No priority is written; the game's default (4) applies.

Kinds `chop` and `gather` work on plants instead of tiles: every tree (`chop`) or living shrub (`gather`) whose base position is in the box or circle is marked with `dfhack.designations.markPlant` (the same `Default` dig flag, placed on the tree's base trunk tile or the shrub's tile, with the block flagged), after `canMarkPlant` agrees; saplings, dead shrubs, and already marked plants are skipped with reasons. The result carries `plants` (the first 25 marked, with species and the designation tile) and `designations_api` (whether the DFHack module was present; without it the base tile is flagged directly). `by_level` is empty for these kinds. Verified in-game 2026-10-15.

### `dig.erase`

Args: the box, `kind` (optional: `mine`, `up_stair`, `down_stair`, `up_down_stair`, `channel`, `ramp`, `smooth`, `engrave`, `chop`, `gather`). Needs a map and `dig_write`.

Clears the dig and smooth flags and the blueprint marker on matching tiles, and removes the queued designation job for each with `dfhack.job.removeJob`. Dug tiles stay dug. `chop` and `gather` unmark every marked tree or shrub in the box through `dfhack.designations.unmarkPlant` (which also removes the queued job); `cleared` counts plants and `jobs_removed` is 0 for them.

Result: `box`, `kind`, `cleared`, `jobs_removed`, `counts` (per kind), `note`.

### `build.workshop`

Args: `type` (a `workshop_type` or `furnace_type` token such as `Masons` or `Smelter`, or a custom building code or name), `x`, `y`, `z` (top-left corner of the footprint, as `map.find_space` returns in `origin`), `material` (optional, see Materials below). Needs a map and `build_write`.

#### Materials

Shared by `build.workshop`, `orders.create`, and the Phase 7 placement ops (module `materials`, plan 12.2). A material word is normalised (lower case, a leading "any " dropped) and resolved to a spec:

- a form word (`blocks`, `boulders`, `logs`, `bars`), alone or trailing another word ("granite blocks", "wooden logs"), sets `item_type`;
- a stone word (`stone`, `rock`, `inorganic`) is the class `stone` for buildings and the generic inorganic material (`mat_type` 0, `mat_index` -1) for work orders;
- `wood`, `metal`, `gem` set the class bit on `job_item.flags3` for buildings; `wood` and the organic words (`bone`, `shell`, `leather`, `cloth`, `silk`, `yarn`, `horn`, `pearl`, `tooth`, `plant`, `soap`, `strand`) are material category flags for work orders;
- anything else is a `dfhack.matinfo.find` token (as given, or upper-cased with underscores), an inorganic raw matched by id, solid name, or solid adjective, or a plant material matched by its solid name or adjective ("plum wood", "ash") or by the plant's name with " tree" dropped ("plum"), giving `mat_type` and `mat_index`.

An unknown word is `BAD_REQUEST` with up to five close inorganic names. A work order refuses a form word. For buildings the spec is merged into the filter's material slot (`getFiltersByType`'s `material` argument); a specific material clears `non_economic` as DFHack does. DFHack's `isSuitableMaterial` ignores the class bits, so the bridge's own count applies the class and form test itself (`materials.item_matches`); whether the game honours the class bit on a construction job is checked live in 7.1.

Steps, in order: resolve the type and its size with `getCorrectSize`; scan the footprint with the same rules as `map.find_space` and then `checkFreeTiles`; build the game's default job item filters with `getFiltersByType` (restricted to `material` when given) and count usable items in play that satisfy each (`isSuitableItem` and `isSuitableMaterial`, skipping forbidden, dumped, melting, in-job, built, trader, and hostile items); then `constructBuilding` with those filters, which queues the construction job. The building is never completed by the bridge.

Result: `status` of `placed` (with `building` `{id, kind, pos, bounds}`, `requirements`), `invalid_space` (with `footprint`, `blocked_at`, `reason`), or `no_materials` (with `requirements` `[{item_type, quantity, material, flags, available}]` and `missing`). An unknown type is `NOT_FOUND` with the known types listed.

### `build.materials`

Args: `form` (optional: `blocks`, `boulders`, `logs`, `bars`), `material` (optional word as above), `fire_safe`, `magma_safe` (booleans), `limit` (default 25). Needs a map and `stocks`.

Walks `world.items.other.IN_PLAY` once, keeping blocks, boulders, logs, and metal bars that are not forbidden, dumped, melting, in a job, built, held by traders, or hostile, and groups them by material and form. Heat safety uses DFHack's thresholds (every heat point above 11000 for fire safe, 12000 for magma safe, cold damage at 60001 or below the limit). `economic` marks boulders of stone the player's economic list reserves.

Result: `total_items`, `groups`, `count`, `limit`, `truncated`, `materials` `[{material, form, class, count, fire_safe, magma_safe, economic, token}]` sorted by count, `by_class`, `by_form`, `filter`, `note`.

### `build.plan_construction`

Args: `kind` (`wall`, `floor`, `ramp`, `stairs`, `fortification`, `bridge`, `paved_road`, `dirt_road`, `support`); a shape: the box (`x1, y1, z1, x2, y2, z2`, the dig limits), `circle` `{x, y, z, radius}`, or `line` `{x1, y1, x2, y2, z}`; `hollow` (box perimeter or circle ring), `thick` (lines, default true: every diagonal step also gets the orthogonal tile), `material` (a word from the Materials section), `direction` (bridges: `retracting`, `raise_north`, `raise_south`, `raise_east`, `raise_west`). Needs a map and `workshops`. Computes what `build.construct` would do and changes nothing.

Per-tile kinds place one `Construction` building per tile with the subtype `Wall`, `Floor`, `Ramp`, `Fortification`, or for `stairs` the level's subtype: `UpStair` at the bottom, `DownStair` on top, `UpDownStair` between, and `UpDownStair` where the bottom tile is already a down stair or the top tile an up stair (buildingplan's convention). Stairs take a box of at least two levels. A z range repeats the shape per level. Per tile, in order: no map block; map edge; hidden, a building, magma, or water deeper than 1 (quickfort's base rule); then the shape must be `EMPTY`, `FLOOR`, `BOULDER`, `PEBBLES`, `RAMP_TOP`, `BROOK_TOP`, `TWIG`, `SAPLING`, `SHRUB`, or `RAMP`; a constructed tile already of the kind's shape (floor on floor, ramp on ramp, an existing stair of the level's type) is `skipped_existing`. A tile is `unsupported` when it is open air with no non-open tile among its eight neighbours on the level and no wall below; it is still placed. Materials: `needed` is the tile count, `available` the count for the kind's filter (plus the spec's class and form), and when `available < needed` the status is `no_materials` and nothing is placed.

Single buildings take a box on one level, at most 31 by 31. `bridge`: every tile must pass; the anchor edge (the side named by `direction`) cannot sit on a ramp, other tiles may be ramps or stairs; `direction` sets `building_bridgest.direction`; `has_support` comes from `dfhack.buildings.hasSupport`. `paved_road` and `dirt_road`: bad tiles are cut out of the room extents, at least one must remain; dirt roads need soil or grass floor and take no material. `support`: one tile. Material count for bridges and paved roads is `floor(tiles / 4) + 1` (DFHack's `computeMaterialAmount`).

Result (per-tile kinds): `kind`, `shape`, `box` (line endpoints under `line`, circle centre and radius), `hollow`, `thick`, `dry_run`, `applied`, `status` (`plan`, `placed`, `no_materials`, `nothing_to_place`), `placed`, `skipped_existing`, `skipped_unsuitable`, `skipped_building`, `skipped_edge`, `unsupported`, `unsupported_tiles` (first 25), `skipped` `[{pos, reason}]` (first 25), `skipped_truncated`, `by_level`, `materials` `{needed, available, filter}`, `buildings` (first 25 ids), `buildings_truncated`, `warnings`, `note`. Single buildings: `status` (`plan`, `placed`, `no_materials`, `invalid_space` with `blocked_at` and `reason`), `width`, `height`, `tiles`, `direction`, `has_support` (bridges), `materials`, `building` `{id, kind, bounds, material_amount}`.

### `build.construct`

Args and result as `build.plan_construction`. Needs a map and `build_write`. Places each construction with `dfhack.buildings.constructBuilding` and fresh filters per building; a placement DFHack refuses is added to `skipped` as `placement failed`.

### Traps and military buildings (Phase 16)

`build.plan_furniture` and `build.place` take the extra types `lever`, `pressure_plate`, `cage_trap`, `stone_fall_trap`, `weapon_trap` (building type `Trap` with the matching `trap_type` subtype), `upright_spike` (`Weapon`), `catapult` and `ballista` (`SiegeEngine` subtypes, 3 by 3), and `trade_depot` (5 by 5). Inputs come from DFHack's building input table (checked 2026-10-15): one mechanism for the four traps and the plate, a mechanism plus one weapon or trap component for the weapon trap, one spike trap component for the spike, three catapult or ballista parts, three building materials for the depot. Vector-only filters (`ANY_SPIKE`, `ANY_WEAPON`) are counted from the game's own item vectors and labelled "spike (trap component)" and "weapon or trap component"; their `make_with` jobs are `MakeTrapComponent` and `MakeWeapon`, and mechanisms come from `ConstructMechanisms`. The 3 by 3 and 5 by 5 types take one position, the top-left corner, and the response carries `footprint` and the unsuitable tiles. A `pressure_plate` accepts `plate` `{triggers: [units, water, magma, track], citizens, resets, unit_min, unit_max, water_min, water_max, magma_min, magma_max, track_min, track_max}`, written to `building_trapst.plate_info` after placement (defaults: units, not citizens, resets, unit size 50000-200000, depth 1-7, track 1-2000); `plate` on any other type is `BAD_REQUEST`. Cage and stone-fall traps are loaded by the game after they are built. Lever linking is not offered (README open issue). Verified in-game 2026-10-15: a lever and a pressure plate placed from two mechanisms; the spike, siege engines, and weapon trap refused for missing parts with the right work orders named.

### `build.plan_furniture`

Args: `type` (plain name: `door`, `floodgate`, `hatch`, `wall_grate`, `floor_grate`, `vertical_bars`, `floor_bars`, `glass_window`, `gem_window`, `bed`, `table`, `chair`, `cabinet`, `chest`, `armor_stand`, `weapon_rack`, `statue`, `slab`, `coffin`, `cage`, `restraint`, `well`, `archery_target`, `traction_bench`, `nest_box`, `hive`, `bookcase`, `display_case`, `offering_place`, `instrument`, `animal_trap`; aliases `throne`, `seat`, `box`, `coffer`, `container`, `chain`, `rope`, `window`, `grate`, `bars`), either `x, y, z` or a one-level box `x1, y1, z1, x2, y2, z2`, `material` (a word from the Materials section; a form word is refused), `limit` (default 25, the most placed per call). Needs a map and `workshops`. Computes what `build.place` would do.

Per tile: no map block, map edge, quickfort's base rule (hidden, building, magma, deep water), then the type's rule: `coverable` (hatch, floor grate, floor bars) takes floor, open air, ramp top, or a stair; `well` takes open air or a ramp top with an orthogonal floor neighbour; everything else takes a floor-like tile (`FLOOR`, `BOULDER`, `PEBBLES`, `TWIG`, `SAPLING`, `SHRUB`), beds additionally not `outside`, doors additionally a `WALL` or `FORTIFICATION` tile cardinally adjacent (a planned wall is not a wall yet), with a warning when no two opposite sides are walls. Items: the type's filters from `getFiltersByType` with the spec merged into the first; `requirements` carries each filter's item type, quantity times the tile count, material, and the available count; a shortage gives `status` `no_materials` with `missing` and `make_with` `{job, item, tool_use}` (the first of `ConstructDoor`, `ConstructBed`, `ConstructThrone`, `ConstructTable`, `ConstructCabinet`, `ConstructChest`, `ConstructArmorStand`, `ConstructWeaponRack`, `ConstructStatue`, `ConstructCoffin`, `ConstructSlab`, `ConstructHatchCover`, `ConstructGrate`, `ConstructFloodgate`, `ConstructTractionBench`, `MakeWindow`, `MakeCage`, `MakeChain`, `MakeAnimalTrap`, `MakeTool`, `CutGems`, `MakeInstrument` that exists in `df.job_type`).

Result: `type`, `building_type`, `box`, `dry_run`, `applied`, `status` (`plan`, `placed`, `no_materials`, `nothing_to_place`), `placed`, `candidates`, `skipped_unsuitable`, `skipped_building`, `skipped_edge`, `over_limit`, `limit`, `skipped` `[{pos, reason}]` (first 25), `requirements`, `missing`, `make_with`, `warnings`, `buildings` (ids), `note`.

### `build.place`

Args and result as `build.plan_furniture`. Needs a map and `build_write`. One `constructBuilding` per tile with fresh filters.

### Farm plots

`build.plan_furniture` and `build.place` accept `type` `farm_plot`: one building over the whole box (one level, at most 31 by 31), no items. A tile joins the plot when it is a floor, twig, sapling, or shrub tile whose tiletype material is soil, grass, or plant, or any floor whose block has a solid mud spatter with a non-zero amount on that tile (quickfort's rule, checked 2026-10-15); hidden tiles, buildings, magma, water deeper than 1, map edges, and other floors are cut out of the extents and listed in `skipped` with reasons. `fertilize` (default false) sets fertilize-every-season at placement. The response is the furniture placement shape plus `tiles`, `candidates`, `soil` (materials by tile count; grass tiles name the soil layer under them with "(grass)"), and `mud_tiles`; `placed` is 1 for the one building. A planter builds it (a `ConstructBuilding` job). Verified in-game 2026-10-15.

### `farms.list`

Args: `limit` (default 25). Needs a map. Namespace `workshops`.

Result: `count`, `total`, `truncated`, `plots` `{id, pos, bounds, tiles, built, crops {spring, summer, autumn, winter} (plant names or "none"), fertilize_every_season, fertilization {current, max}, soil (main material), subterranean}`. Plots come from `world.buildings.other.FARM_PLOT`.

### `farms.get`

Args: `id`, `limit` (plantable rows per season, default 25). Needs a map. Namespace `workshops`.

Result: the list row plus `soil` `{tiles, materials [{material, tiles}], mud_tiles, subterranean (majority of tiles), subterranean_tiles, outside_tiles, cavern_tiles (subterranean tiles flagged as a local feature), biome, note}` and `plantable` keyed by season with rows `{plant, id, index, seeds, seasons_to_grow}` sorted by seeds in stock, `plantable_truncated`, `plantable_note`. A plant is plantable when its raw has the `SEED` flag and not `TREE`, carries the season flag for every season the crop spans (`growdur` in tens of ticks over 100800 per season), and the `BIOME_<biome>` flag of the plot's biome for surface plots or `BIOME_SUBTERRANEAN_WATER` for underground plots (DFHack autofarm's rule; the game's own is not readable). Seeds count `SEEDS` items by plant index, skipping unusable ones. Verified in-game 2026-10-15.

### `farms.set_crops`

Args: `id`, `crops` (object keyed by `spring`, `summer`, `autumn` (or `fall`), `winter`, values a plant name, raw id, or `none`), `fertilize` (boolean); at least one of the two. Needs a map. Namespace `build_write`.

Writes `plant_id[season]` (the plant raw index, -1 for none) and `farm_flags.seasonal_fertilize` directly, as DFHack's autofarm does. A plant not on that season's plantable list is `BAD_REQUEST` naming the plantable crops; an unknown plant is `NOT_FOUND`. `crops` on a plot that is not built yet is `BAD_REQUEST`: the game clears the crops when the planter finishes the plot (seen live 2026-10-15), while the fertilize flag survives and may be set at any time.

Result: the list row plus `changed` (season names and `fertilize`) and `warnings`. Verified in-game 2026-10-15: the game recomputed `fertilization.max` (13 for 49 tiles) as soon as the flag was set.

### `build.list`

Args: `kind` (optional: a plain name such as `door`, `bed`, `workshop`, `construction`, a `building_type` token, or a subtype such as `Masons` or `Wall`), `planned_only`, `z`, an optional box (`x1..z2`, buildings whose bounds touch it), `limit` (default 25), `offset`. Needs a map and `workshops`.

Walks `world.buildings.all`, leaving out stockpiles and zones. Row: `id`, `kind`, `building_type`, `type` (workshop, furnace, construction, trap, siege engine subtype), `name`, `pos`, `bounds`, `stage`, `max_stage`, `built`, `planned` (stage 0), `marked_for_removal`, `strange_mood`, and when a construction job exists `job` `{id, type, suspended, do_now, worker}`, `suspended`, `materials` `{attached, still_needed}`.

Result: `total`, `count`, `offset`, `limit`, `truncated`, `buildings` (by id), `counts_by_kind`, `filter`.

### `build.remove`

Args: `id` (building id). Needs a map and `build_write`. Every building type but stockpiles and zones (each is `BAD_REQUEST` pointing at its own op); a building claimed by a strange mood is refused.

Calls `dfhack.buildings.deconstruct`: a finished building gets a deconstruction job for the dwarves, an unfinished blueprint is removed at once.

Result: `status` (`removal_queued`, `blueprint_cancelled`, `removed`, or `already_queued`), `building` (a `build.list` row), `note`.

### `build.suspend`

Args: `id`, `suspended` (boolean). Needs a map and `build_write`. Sets `jobs[0].flags.suspend` on an unbuilt building and calls `checkBuildingsNow`; a built building or one without a job is `BAD_REQUEST`.

Result: `changed`, `suspended`, `building`.

### `build.remove_constructions`

Args: the box or `circle` `{x, y, z, radius}`, `dry_run` (default false on the wire; the tool defaults it to true). Needs a map and `build_write`.

Per tile: a finished construction (`dfhack.constructions.findAtTile`, ignoring the `top_of_wall` records above constructed walls) is designated for removal with `designateRemove` unless the tile already carries a dig designation; a planned construction building is removed at once with `deconstruct` (unless a strange mood holds it); other tiles are skipped. `checkDesignationsNow` runs when anything was designated.

Result: `box`, `shape`, `dry_run`, `applied`, `cancelled`, `designated`, `already_designated`, `skipped`, `tiles` `[{pos, action, material | building}]` (first 25), `skipped_tiles` (first 25), `note`.

### Trade (Phase 17.0)

Reads follow DFHack's caravan script (`hack/scripts/internal/caravan`, checked 2026-10-15). Values use `dfhack.items.getValue(item, caravan)` with the active caravan (at the depot, else approaching) so agreement prices apply.

### `trade.caravans`

Args: none. Needs a map. Result: `count`, `caravans` `[{index, civ {id, name, race, home}, state (none, approaching, at_depot, leaving, stuck), active, days_remaining (time_remaining / 120), mood, haggle_failures, animals, import_value, export_value, flags, depot_notified}]`, `merchants_on_map`, `season`, `note`.

### `trade.depot`

Args: `depot_id` (optional; the first depot otherwise), `limit` (default 25). Needs a map. Result: `id`, `pos`, `bounds`, `built`, `accessible` (the game's wagon-access flag), `broker_requested`, `anyone_can_trade` (`trade_flags`), `trade_job` (`{id, worker}` when a `TradeAtDepot` job sits on the depot), `times_used`, `fort_goods` and `merchant_goods` (`{count, value, items [{id, description, value, requested, merchant_goods}], truncated}` from `contained_items` in `TEMP` use mode, split by the `trader` flag), `pending` (`BringItemToDepot` jobs with their workers), `caravan`, `note`.

### `trade.broker`

Args: none. Needs a map. Result: `assigned`, `broker` `{id, name, pos}` (from `getUnitByNobleRole('broker')`, else the BROKER position holder), `job`, `trading` (a `TradeAtDepot` job), `at_depot`, `appraisal`, `depot_id`, `broker_requested`, `anyone_can_trade`, `meetings_waiting` (`plotinfo.meeting_requests`), `is_site_leader`, `warning`, `note`.

### `trade.request_broker`

Args: `requested` (default true), `anyone` (default false), `depot_id`. Needs a map and `trade_write`. Writes `trade_flags.trader_requested` and `anyone_can_trade`, and when a caravan is at the depot and no `TradeAtDepot` job exists creates one the way DFHack's `lever` script creates a pull job (building holder ref, `linkIntoWorld`, `checkBuildingsNow`); withdrawing removes the job. Live on 2026-10-15 the game had created the job itself once the merchants finished unloading. A broker who is also the site leader never comes while a diplomat waits to meet them; `trade.broker` returns `warning` for that case. Result: `depot_id`, `before`, `broker_requested`, `anyone_can_trade`, `caravan_present`, `trade_job`, `job_created`, `job_removed`, `note`.

### `trade.bring`

Args: `item_ids`, or `query` (description substring) with optional `item_type` (an item type token), `limit` (default 25), `depot_id`. Needs a map and `trade_write`. Each item passes DFHack's move-goods rule (not hostile, removed, dead_dwarf, spider_web, construction, encased, murder, trader, owned, garbage_collect, on_fire, forbidden, in a job, in a building, or carried outside a container; mandates checked with `checkMandates`; reachable from the depot by `canWalkBetween`), then `dfhack.items.markForTrade(item, depot)` creates its `BringItemToDepot` job. Result: `depot_id`, `marked`, `value`, `items`, `skipped [{id, description, reason}]`, `note`.

### `trade.unbring`

Args: `item_ids`, `depot_id`. Needs a map and `trade_write`. Removes the item's `BringItemToDepot` job through its specific JOB ref, or clears `in_building` for an item already at the depot (movegoods' release). Result: `depot_id`, `released`, `skipped`.

### `trade.offer`

Args: `give` (fort item ids at the depot), `take` (merchant item ids at the depot), `depot_id`. Needs a map and `trade_write`. Evaluates the deal at the caravan's prices and weights: `give {count, value, items [{id, description, value, kg}]}`, `take {...}`, `profit`, `margin`, `weight {give_kg, take_kg, merchant_load_kg (the merchants' goods at the depot), capacity_kg (caravan_state.total_capacity), load_after_kg, fits, unknown_weights}` (item masses are `item.weight` in kilograms plus milligrams when `flags.weight_computed`), `verdict` (no caravan; invalid; refused, too heavy for the animals; refused, merchants never accept a loss; accepted at 50% profit; likely at 10%; marginal below), `problems`, `executed` (always false: the Trade button is the player's), `note`. Verified in-game 2026-10-15 against a forced dwarven caravan: five granite boulders were refused by the game with the weight reply, and the evaluation gave the same answer (1,095 kg over a 2,100 kg capacity).

### `trade.screen`

Args: none. Needs a map. Namespace `trade`. Reads `df.global.game.main_interface.trade`: `open`, `choosing_merchant`, `still_unloading`, `has_talker`, `fortress_trader`, `merchant_trader`, `depot_id`, `counter_offer`, `reply` (the `talk_line_type` the merchant last said) with `reply_meaning` in plain words (Weight: too heavy for the animals; Money: not enough value; Trade: deal accepted; ...), `capacity_kg`, `merchant_goods` and `fort_goods` `{count, selected, selected_value, selected_kg, total_kg}`, `load_after_kg`, `fits`. Meaningful while the player has the trade screen open.

### `trade.select`

Args: `give` (fort item ids), `take` (merchant item ids), `clear` (default true: unselect everything else), `depot_id`. Needs a map and `trade_write`, and the trade screen open (`BAD_REQUEST` otherwise). Sets `goodflag[1][i].selected` for the fort's list and `goodflag[0][i].selected` for the merchants', as DFHack's trade overlay does; the player then presses Trade or Offer. Result: `give {selected, value, missing}`, `take {...}`, `profit`, `note`. Verified in-game 2026-10-15: the selection showed on the player's screen and the Trade press got the game's weight refusal, which `trade.screen` then reported.

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

Args (circle form): `circle` `{x, y, z, radius}` (radius 1 to 15) in place of the corners; the pile is built with room extents the way quickfort's place module does it, one byte per tile of the bounding box, and `tiles` counts only the tiles inside. Rectangle form args: `x1`, `y1`, `x2`, `y2`, `z` (any two opposite corners, at most 31 by 31), and optionally the configuration fields of `stockpiles.configure` (`categories` as the enable list, `preset`, `preset_mode`, `name`, container limits). Needs a map and `stockpiles_write`.

The configuration arguments are validated first, so a bad category paints nothing. Every tile is checked with the map rules (revealed, flat floor, no building, liquid, or plant); then `constructBuilding{type=Stockpile, abstract=true, pos, width, height}` paints it, and the configuration is applied.

Result: `status` of `placed` (with `stockpile` row plus `settings`, and `changed`), `placed_unconfigured` (the pile exists but a configuration step failed; `error` says why), or `invalid_space` (`footprint`, `blocked_at`, `reason`).

### `stockpiles.configure`

Args: `id`, and at least one of `enable` / `disable` (category name or list; applied through DFHack's `library/cat_<name>` preset so the material lists are sized and filled as the game's own toggle does, with a manual pass as fallback; `ore` has no preset and is manual), `preset` with `preset_mode` (`set` replaces all settings, `enable` adds, `disable` removes; applied through the DFHack stockpiles plugin), `name` (up to 64 characters, converted to code page 437), `max_barrels`, `max_bins`, `max_wheelbarrows`. Needs a map and `stockpiles_write`.

Result: `changed` (list of what was applied), `stockpile` (row plus deep `settings`).

### `stockpiles.rename`

Args: `id`, `name` (empty clears). Result: `changed`, `stockpile`.

### `stockpiles.delete`

Args: `id`. Calls `dfhack.buildings.deconstruct`; an abstract building is removed at once and its items stay on the ground. Result: `status` (`deleted` or `removal_queued`), `stockpile`, `note`.

### Zones

Namespace `zones` (read, on by default, group World). Activity zones are `building_civzonest` entries in `world.buildings.other.ACTIVITY_ZONE`. Plain type names: `meeting_area`, `bedroom`, `dining_hall`, `dormitory`, `barracks`, `archery_range`, `office`, `tomb`, `pen`, `pit`, `pond`, `dump`, `water_source`, `fishing`, `sand`, `clay`, `gather`, `animal_training`, `dungeon` (`pit` and `pond` are both `civzone_type.Pond`, split by `zone_settings.pond.flag.keep_filled`).

### `zones.list`

Args: `type` (optional plain name, token, or alias such as `pasture`, `garbage_dump`), `query` (name substring), `active` (boolean), `limit` (default 25), `offset`. Needs a map.

Row: `id`, `number` (`zone_num`), `name`, `label`, `type`, `type_token`, `active` (`spec_sub_flag.active`), `bounds`, `pos`, `tiles` (counting extents), `assignment` (`owner` for bedroom, office, dining hall, tomb; `units` for pen, pit, pond, dungeon; `squads` for barracks and archery range; `location` for meeting areas; else `none`), `owner` `{id, name}` (`dfhack.buildings.getOwner`), `assigned_units` (count), `squads` (count), `location` `{id, type, name}` from the site's abstract buildings when `location_id` is set.

Result: `total`, `count`, `offset`, `limit`, `truncated`, `zones` (by id), `counts_by_type`, `filter`.

### `zones.get`

Args: `id`, `limit` (default 25, caps every list). Needs a map. A building that is not a zone is `BAD_REQUEST`.

Result: the row plus `extents` (tiles, first `limit`), `tiles_truncated`, `settings` by type (`pen`: `check_occupants`; `pond`: `pit_or_pond`, `keep_filled`, `check_occupants`; `gather`: `pick_trees`, `pick_shrubs`, `gather_fallen`; `archery_range`: `dir_x`, `dir_y`, `shoot_from` with quickfort's mapping, west is `1, 0`, east `-1, 0`, north `0, 1`, south `0, -1`; `tomb`: `allow_pets`, `allow_citizens`), `assigned_units` `[{id, name}]` with `assigned_units_total`, `assigned_items` (vermin count), `squads` `[{id, name, alias}]`, `contained_buildings` `[{id, kind, type, pos, built}]` with a total, `room_description` (`dfhack.buildings.getRoomDescription`, with the owner when there is one; empty on DFHack 53.16-r2 for an owned office, so expect `null` until DFHack fills it).

### `zones.create`

Args: `type` (plain name; `pit` and `pond` both make a `Pond` zone, with `keep_filled` set for `pond`), a box (`x1, y1, x2, y2, z`, at most 64 by 64) or `circle` `{x, y, z, radius}` (1 to 31), `name` (up to 64 characters), `active` (default true), and the type's settings (`check_occupants`; `keep_filled`; `pick_trees`, `pick_shrubs`, `gather_fallen`; `shoot_from` north/south/east/west; `allow_pets`, `allow_citizens`), `limit`. Needs a map and `zones_write`.

Builds room extents over the bounding box with every revealed tile of the shape set (hidden tiles are cut and counted) and calls `constructBuilding{type=Civzone, subtype, abstract=true, pos, width, height, fields={assigned_unit_id=-1, room}}`, as quickfort's zone module does. New pens get `check_occupants`, gather zones all three gather flags, archery ranges shoot from the west, as the game's defaults. A setting that does not belong to the type is `BAD_REQUEST` (on create it is reported as a warning after the zone exists). Zones of the same type sharing a tile are reported in `warnings`.

Result: `status` (`created` or `invalid_space` with `reason`), `zone` (a `zones.get` row), `hidden_skipped`, `changed`, `warnings`, `note`.

### `zones.edit`

Args: `id`, and any of `name`, `active`, the type's settings, `add` and `remove` (each a box `{x1, y1, x2, y2}` on the zone's level or a circle `{x, y, radius}`), `limit`. `type` is refused. Needs a map and `zones_write`.

Tile edits rebuild the extents from the current tiles plus added revealed tiles minus removed ones, refit `x1..y2`, `room`, and the centre, free the old extents, and call `notifyCivzoneModified`. A zone keeps at least one tile.

Result: `changed` (field names, plus `add` and `remove`), `tiles_added`, `tiles_removed`, `zone`.

### `zones.assign`

Args: `id`, `unit_id`. Needs a map and `zones_write`.

Bedroom, office, dining hall, tomb: the unit must be a citizen; `dfhack.buildings.setOwner` replaces any previous owner (`previous_owner` in the result). Pen: a tame non-citizen; pit or pond: neither a citizen nor a pet. The unit is detached from any zone it was assigned to (its `general_ref_building_civzone_assignedst` and the old zone's `assigned_units` entry, the zone plugin's way), then added to `assigned_units` with a new ref; `moved_from` lists the old zone ids. Any other zone type is `BAD_REQUEST`.

Result: `status` (`assigned`, `already_assigned`), `role` (`owner`, `animal`), `previous_owner` or `moved_from`, `zone`.

### `zones.unassign`

Args: `id`, `unit_id` (animals only). Owner types clear the owner (`status` `unassigned` or `no_owner`); pens, pits, and ponds drop the unit and its ref (`unassigned` or `not_assigned`). Result: `status`, `role`, `previous_owner`, `zone`.

### `zones.delete`

Args: `id`. Calls `dfhack.buildings.deconstruct`, which removes an abstract building at once and clears its squad and unit links. Result: `status` (`deleted`), `zone` (the row before deletion), `note`.

### `console.run`

Args: `command` (full console line).

The first word must be on the console allowlist. `lua` additionally needs `lua_eval`. A `claude-bridge` line only runs for the `status`, `help`, `reload`, and `test` subcommands; `perm`, `allow`, `deny`, and `enable`/`disable` style changes are refused with `NOT_ALLOWED` regardless of the allowlist, as is any line containing `;`. Runs through `dfhack.run_command_silent`.

Result: `command`, `ok` (result was `CR_OK`), `result` (numeric `CR_*`), `output` (captured text).
