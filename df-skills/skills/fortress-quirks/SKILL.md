---
name: fortress-quirks
description: Facts about Dwarf Fortress and the dfhack bridge that are easy to get wrong. Use before digging or building, when laying out rooms, farming, forming squads, trading, reading names or long lists, handling events or the prompt timer, and whenever a tool returns NOT_ALLOWED, MOD_NOT_ENABLED, a refusal, or a truncated list.
when_to_use: Any time a fort action touches the map, the dwarves, the military, trade, or the bridge's limits, or something unexpected comes back from a tool.
---

# Fortress Quirks

What the game and the bridge have taught us. Each line was learned by doing it wrong once.
Strategy (stock targets, trade goods, wealth, room value, elves, petitions) is in
`fortress-basics`.

## The bridge

- **Every call pauses the game** for a few milliseconds while DFHack answers. Prefer one
  call with a bigger `limit` or a bigger box over many small calls. Do not poll in a loop
  while dwarves are working unless the task needs it.
- **Lists are capped at 25 rows** by default. Every list tool takes `limit`; the response
  says when the cap was hit (`truncated`). Raise `limit` when you need the whole list; never
  assume a capped list is complete.
- **Ids are the keys.** Unit, building, item, squad, zone, stockpile, and work order ids are
  stable while the fort is loaded. Turn names into ids with `find_unit` and `find_items`;
  never match by name twice.
- **Dry runs exist** for the three big writes: `plan_dig`, `plan_construction`,
  `plan_furniture`. They report overlaps, bad tiles, and missing items with the work order
  that makes them. Use them before any footprint you have not seen.
- **Writes never overwrite** an existing designation or blueprint; overlapping tiles are
  skipped and reported. A repeat of the same order is refused, not duplicated.
- **Permissions are the player's.** `get_permissions` shows the namespaces. `NOT_ALLOWED`
  names the toggle; tell the player once, do not retry.
- **`SCREEN_BUSY` means the player has another screen open** (a menu, a sheet). Never close
  it for them; retry later, or tell the player what you are waiting for.
- **Text is CP437.** Names come back with the English surname in quotes ("Urist
  Scourgears"); the quoted part is not a nickname. Some accented capitals become `?`. Do not
  "fix" spellings.
- **The game's own notion of stock** depends on the bookkeeper. If the player turned off
  true counts, `list_stocks` shows what a bookkeeper would know, which may be rounded or
  stale.

## Movement and rooms

- **Dwarves move diagonally.** Two dug rooms whose corners touch are one room; a room whose
  corner touches a corridor is open to it. Every dug room needs a fully solid border,
  corners included, with at least one wall tile between it and any other room or corridor,
  and a deliberate doorway tile.
- **Z-levels connect only through stairs and ramps.** A floor above needs an up stair or a
  ramp below it. Roof floors need a ramp or stair to be built; a tree canopy above a ramp
  blocks it.
- **Doors need an adjacent wall.** A door on open ground is refused.
- **Beds go indoors.** A bed on a surface tile with sky above is refused.
- The wagon's roof is its own small walkable group; do not count it as fort floor.

## Digging

- `find_exposed_walls` lists rock that borders walkable floor: that is where digging can
  start without a tile walk.
- `designate_dig` kinds: `mine`, `stairs` (a box spanning at least two levels; down stair
  on top, up/down between, up stair at the bottom; a 1 by 1 box makes a stair column),
  `channel`, `ramp`, `remove_stairs`, `smooth`, `engrave`, `chop`, `gather`. Boxes span
  z-levels; circles take a centre and radius for every kind but stairs.
- **The whole map is in reach.** Boxes and circles take any size up to the map bounds
  (`get_map_bounds`) and are clipped at the edge (`box.clipped`). The wagon is only the
  default start of `find_build_space`; pass a point or `whole_map=true` to look further.
  Big boxes pause the game longer, so preview them with the plan tools first. One bridge,
  road, or farm plot is at most 31 by 31 (the game's limit); place several for more.
- **A designation job without a worker is normal.** The game queues the jobs long before a
  miner picks one. `list_designations` shows pending tiles and taken jobs; the tile's own
  flag clears when the job is created and comes back if the job is cancelled.
- **Smoothing and engraving** are refused on tiles already done; engrave only after smooth.
- **Trees** are felled from their base tile; saplings are neither chopped nor gathered.
  `list_plants` shows trees and shrubs in a box.
- Soil layers (loam, clay, sand, silt, peat) dig fast and take farms; stone layers do not.
  `get_tile` names the material; the surface level is in `get_map_bounds` and `get_wagon`.

## Building

- **Materials in plain words.** "any stone", "any wood", "granite", "blocks", "plum wood",
  "granite blocks". `list_building_materials` shows what is usable with counts. A material
  with zero available is refused and nothing is placed.
- **Furniture is made first, placed second.** A door, bed, table, chair, or cabinet needs the
  item in stock; the refusal names the work order job that makes it. Workshops and
  constructions take raw materials directly.
- **A building shown on a tile may not be built.** `get_tile` and `list_buildings` say
  whether it is built, planned, or suspended.
- Workshops need a 3 by 3 clear footprint; `find_build_space` returns usable spots. The
  trade depot is 5 by 5 and must be reachable by wagons (a 3-wide path from the map edge).
- Dwarves build wooden constructions fast (25 in about half a minute of unpaused play);
  stone follows the hauling distance.
- **Traps and levers:** traps need a mechanism in stock; levers cannot be linked through the
  bridge (open issue), so ask the player to link them in the game.

## Farming and food

- **Farm plots go on soil or mud.** Soil floors (including grass over soil) and any floor
  with mud. Stone floors are cut from the plot and reported. Underground soil outside a
  cavern yields less; near water or in a cavern it yields more.
- **Crops are set after the plot is built.** Setting crops on a planned plot is undone by
  the game; `set_farm_crops` waits for a built plot. Underground crops per season: plump
  helmets year round, then pig tails, cave wheat, sweet pods, dimple cups, quarry bushes by
  season. Seeds are their own section below.
- Drink is more urgent than food. A still, a plump helmet plot, and barrels or pots.
- Food left outside rots; a food stockpile indoors early, refuse outdoors.

## Sustainable farming

- **One planted tile takes one seed.** A plot's seed need per season is its tile count
  (`list_farms` gives tiles per plot).
- **Seeds return only from eating raw plants and from brewing**, never from cooking. The
  game bans cooking seeds by default; keep it so.
- **Keep one planting cycle in reserve per crop:** seeds at least equal to the tiles of
  every plot that grows it.
- **Check seed counts with `get_farm`** (its plantable list carries seeds in stock) at
  every season change and before every `set_farm_crops`. `season_changed` is off by
  default; without it, check when `get_time` shows a new season.
- **Below the reserve:** ban cooking that plant with `set_kitchen` (`item_type="PLANT"`,
  `material="<plant>"`, `cook=false`). Brewing stays allowed: it gives the seeds back. Do
  not sell or offer its plants or its seeds. If its plants go into meals faster than they
  are eaten or brewed, add a brew order with `create_work_order` (`find_job_types` names
  the job).
- **Never set a crop whose seed count is below the tiles it needs.** Plant a crop you have
  seeds for instead, or leave the season fallow.
- **Buy seeds.** Caravans sell seed bags: `bring_to_depot` goods to pay, then pick the seeds
  with `select_trade_goods` on the trade screen. Put seeds in next year's requests with
  `set_trade_requests` (`get_trade_request_options` shows the seeds category).
- **Gather wild plants** with `designate_dig(kind="gather")` for extra seeds and new crops.
- **Plump helmets are the backbone crop**, year round underground. Pig tails for cloth and
  the brewing crops (cave wheat, sweet pods, dimple cups) are the second tier.
- **Each seed type caps at 200 in the fort;** more are destroyed, so a huge reserve is
  waste.
- **A seedless season starves the fort a year later.** The seed check is a standing rule
  every season, not a reaction to hunger.

## Workshops and orders

- **Work orders need a manager.** Without one, orders sit unapproved. `list_nobles` shows
  the seat; `assign_noble` fills it (needs `nobles_write`). The same goes for the
  bookkeeper (stock counts) and the broker (trade). Jobs added straight to a workshop do
  not: `list_workshop_tasks` shows what the shop offers, `add_workshop_job` queues one
  (at most 10 per shop), and `set_workshop_job` and `cancel_workshop_job` manage them.
- `find_job_types` turns a plain name into the job the order needs; `create_work_order`
  takes a material in plain words and refuses orders the game would label "unknown
  material".
- `get_workshop` shows the shop's jobs and contents; a shop with a stuck job is usually
  missing a material or a dwarf with the labor: check the work details (`list_work_details`)
  for a detail that grants it and has someone doing it.

## Stockpiles

- A freshly painted stockpile accepts nothing until categories are set; `configure_stockpile`
  with a category or a preset name (`list_stockpile_presets`). Circles leave their corners as
  floor.
- Refuse and corpses need their own pile outdoors; bars, blocks, and stone their own indoors.

## Points of interest

- Hotkeys are the game's 16 F-key zoom slots; `list_hotkeys` shows them with the key each one
  sits on. Slot 1 is the game's wagon default.
- Name the places the plan talks about (entrance, depot, farms, barracks, the current project)
  with `set_hotkey` and short names, so the player can jump there.
- The slots are the player's too: never overwrite one silently. Take a free slot; if you must
  replace one, pass `overwrite=True` and say so with `send_message`.
- Writes need `hotkeys_write`, off by default, and are refused while the Hotkeys window is open.

## Military

- A new squad needs a vacant military position (militia commander or captain); `list_squads`
  shows seats and the game's uniform presets.
- Equipment is set by item type and material class (`breastplate`, `metal`), never a
  specific item; the game assigns the gear. Crossbow squads need bolts with combat and
  training ammunition set.
- Routines: Off duty, Staggered training, Constant training, Ready. Training needs an
  archery range or barracks zone assigned to the squad.
- Orders: `station`, `kill`, `patrol` (a route from `create_route`), `cancel`. A kill order
  on a citizen is refused. A station order moves soldiers to the tiles beside the target.
- The squad badge on screen may lag after a symbol or colour change. Leave it.
- Sparring between soldiers arrives as `sparring` events, not fights, when that kind is on.

## Trade and diplomats

- Caravans need a built trade depot and an appointed broker; `request_broker` calls them
  to the depot. `bring_to_depot` hauls goods; `offer_trade` prices a set and tells you
  whether the merchant would accept, including the weight limit.
- **The trade flow** (needs `trade_write` and `screens_write`): bring goods, `request_broker`,
  wait until `get_broker` shows the broker at the depot and the merchants have finished
  unloading, `open_trade_screen`, `select_trade_goods`, `offer_trade` to check the verdict,
  `press_trade("trade")`, read `reply_meaning` and `mood_after`, answer a counter-offer with
  `accept_counter` or `decline_counter`, then `press_trade("close", unpause=True)`.
- `trade` is final, `offer` is a gift, and `seize` angers the civilization: never seize
  unless the player asked. Without `screens_write`, select the goods and tell the player
  with `send_message` to press Trade.
- `SCREEN_BUSY` means the player has a menu open. Their menu is never closed; try later or
  ask them.
- **The liaison meeting** (needs `screens_write`). A `meeting_ready` event says the liaison
  is waiting to meet the leader. `get_meeting_dialog` shows whether it is waiting or open,
  its text, its step, and `screen_rows` (the dialog as drawn, with its button labels).
  `open_meeting_dialog`, then `step_meeting_dialog(action="continue")` presses the game's
  Okay button and the liaison talks; on the requests step set next year's requests with
  `set_trade_requests`, then `action="done"`; keep pressing `continue` until the farewell,
  which closes the dialog itself. A reply button is pressed with `action="choose"` and its
  exact `label` from `screen_rows`. `close` (Escape) leaves early; the meeting resumes with
  `open_meeting_dialog`. A land-holder offer has not been seen yet: press the candidate's
  name with `land_holder`, and if that fails tell the player.
- Elves refuse anything made of wood; offering it offends the caravan.

## Units and names

- Units come in three buckets: citizens, domesticated animals, and others (visitors,
  merchants, wildlife, hostiles, undead). `list_others` is where hostiles show.
- `get_unit_sheet` reads one tab (thoughts, health, skills, relations); `get_unit_full_sheet`
  reads all of them with each list capped. Use the tab you need.
- A dwarf's mood in the list row is the game's overall mood word; the thoughts tab explains
  it.
- Nicknames (`set_unit_nickname`) are the only unit write and need `units_write`.

## Labor

- Work details are the game's Labor screen and decide who does what: a dwarf's labors follow
  the details, so change the details, never individual labors. `list_work_details` reads
  them; `assign_work_detail` and `set_work_detail_mode` change them and need `labor_write`.
- A detail's mode is `everybody`, `nobody`, or `only_selected`. Membership only matters on
  `only_selected`; adding dwarves to an `everybody` detail does nothing.
- Miners, Woodcutters, Hunters, and Fisherdwarves are `only_selected` and cannot be
  everybody. Their members need a pick, axe, or crossbow; with no members nobody mines or
  cuts wood, whatever you designate.
- Planters, Plant gatherers, Stonecutters, Engravers, Haulers, Orderlies, and Siege
  operators default to `everybody` and need no members.
- A dwarf in both Miners and Woodcutters keeps swapping pick and axe and wastes the day.
  Keep the two groups apart.
- Children and babies cannot be put on a detail; they are skipped with a reason, as are
  visitors and the dead. When migrants arrive, put the newcomers on details.
- Details cannot be created, renamed, or given other labors through the bridge.

## Events, timer, and channel

- Events arrive as channel messages when the session was started with the channel flag:
  batches two quiet seconds or 50 events apart, each line `[kind] text (x,y,z) units ...`.
  A `goals` message is the player's goals in their prompt; a `timer` message is the prompt
  timer asking for a status check.
- The player chooses which kinds are on (`list_event_kinds`); mineral discovered, migrants
  arrived, popup, units fighting, and petition are on by default. Do not ask for kinds to be enabled unless the
  plan needs them.
- `migrants_arrived` names the newcomers (`newcomers: Name (Profession)`, ids in
  `unit_ids`). Greet them with work: check their professions, put them on work details,
  and add beds before they sleep on the floor. The "no one came" and "discouraged" texts
  are the same kind with no newcomers.
- Any batch sent to you re-arms the prompt timer, so a busy fort is driven by events and a
  quiet one by the timer. The timer counts only while the game is unpaused.
- Without the channel, `poll_events` returns the same batches: call it first without
  `after_seq`, then with the last sequence received, on a `/loop`.
- `send_message` is your voice in the game: short, with a position when there is one. It
  does not pause or recenter the game.
- A `popup` event means the game paused on a box: the embark message at a new fort, the
  first caravan, a megabeast, a siege, an artifact. The event text stops at 400 characters;
  read the rest with `list_popups` when it was cut. Act on it first, then
  `close_popup(unpause=True)` when `pause_write` is on, else tell the player the game is
  paused on a popup.

## Early fort priorities

In this order unless the goals say otherwise: a dug entrance with a door, beds and a
dining area, drink and food for a year (still, farms, kitchen, indoor food stockpile),
manager, bookkeeper, and broker appointed, a trade depot before the first autumn caravan,
a militia with a uniform before the second year, then wealth, nobles, and the player's
monuments.

## Known open issues

- Petitions cannot be read or answered through the bridge yet; the player answers them in
  the game. Petition events still arrive.
- Trade counter-offers: `accept_counter` and `decline_counter` come back `NOT_FOUND` until the
  buttons are measured; the player answers a counter-offer by hand.
- The liaison meeting's land-holder step (a barony offer) has not been seen yet; if pressing
  the candidate's name fails, the player clicks it.
- Levers cannot be linked, weapon traps hold one weapon, siege engines cannot be aimed.
- Dev tools cannot spawn units on this DFHack build.

## When something is off

| Symptom | Meaning | What to do |
|---|---|---|
| `MOD_NOT_ENABLED` | The mod is off in this fort | Tell the player to run `enable claude-bridge` in the DFHack console |
| `DISCONNECTED` or `RPC_FAILED` | Dwarf Fortress is not running or DFHack's remote port is closed | Tell the player; retry `ping` once they confirm |
| `NO_MAP` | A world is loaded but no fort | Wait for the player to load a fort |
| `NOT_ALLOWED` | A permission namespace is off, or a console command is not allowlisted | Name the toggle once; mark the task blocked |
| A list says `truncated` | The 25-row cap | Repeat with a higher `limit` |
| A write says skipped tiles | Existing orders, buildings, or open space in the footprint | Read the skipped list; adjust the box, do not force it |
| No events ever arrive | The session lacks the channel flag, or the organization's Channels switch is off | Tell the player: start with `claude --dangerously-load-development-channels server:dfhack`; an Owner enables Channels under Organization settings > Claude Code; the log is in `~/.cache/claude-cli-nodejs/<project>/mcp-logs-dfhack/`. Meanwhile poll with `poll_events` |
| The game seems frozen and `get_time` says paused | A popup box may be up | `list_popups`, then `close_popup` |
| The game seems frozen | It is paused | `get_time` shows `paused`; `set_paused(false)` if `pause_write` is on, else ask the player |
| A crop write changed nothing | The plot is not built yet | Wait for the planter; set crops after `list_farms` shows it built |

## Never

- Never write to texture or render cache fields on game structures (anything named
  `*_texpos` or `texture_*`), and never ask the console to do it: it crashed the game. The
  bridge does not expose them; do not look for a way around that.
- Never run `exterminate` or any destructive console command against a race the fort owns,
  and never without the player naming the exact target.
- Never leave the game paused at the end of a turn unless the player asked.
