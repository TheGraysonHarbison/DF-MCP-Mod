---
name: fortress-planner
description: Plan and run a Dwarf Fortress fort through the dfhack MCP tools. Use at the start of every fort session, when a goals or timer channel message arrives, at a season change, and whenever no task is active. Reads the player's goals and the plan stored in the save, takes stock of the whole fort, and keeps a phased long-term plan in plan.md.
when_to_use: A dfhack MCP server is connected and the player wants the fort played, planned, or checked.
---

# Fortress Planner

You are playing a Dwarf Fortress fort for the player through the `dfhack` MCP tools. The
player watches the game and talks to you in Claude Code chat, in the goals window, and
through the prompt timer. Your memory of this fort is `plan.md` inside the save, which you
read and write with `read_plan`, `write_plan`, and `append_plan`. The player's wishes are
`goals.md`, read with `read_goals`. Both survive between sessions; your chat context does not.

## Session start

Run this sequence before anything else, every session, in this order:

1. `ping`. It must say the bridge is up and a map is loaded. If not, tell the player what
   `ping` returned and stop; the fix is theirs (`enable claude-bridge` in the DFHack console,
   or loading a fort).
2. `get_permissions`. Note which write namespaces are on. You will only act inside them.
3. `get_time`. Season, month, day, weather, and whether the game is paused.
4. `read_goals`. The player's goals, restated in your plan under `Goals`.
5. `read_plan`. If it is empty, this is a new fort for you: build the first plan below. If it
   has content, it is the truth about what you were doing; reconcile it with the game before
   you act, because the player may have played between sessions.
6. `get_fort_status`, `list_citizens`, `get_stock_bar`. The headline numbers.

Then write or update the plan, and only then start work.

## Taking stock

"Total fortress status" means all of these, not the first three. Delegate the long reads
(see the `work-subdivision` skill) and keep the summaries.

| Area | Tools | What you are looking for |
|---|---|---|
| People | `list_citizens`, `list_nobles` | Population, children, idle or unhappy dwarves, vacant manager, bookkeeper, broker, and militia seats |
| Labor | `list_work_details` | Who mines and who cuts wood (empty Miners or Woodcutters means no digging or felling), newcomers on no detail; put them on details with `assign_work_detail` |
| Food and drink | `get_stock_bar`, `list_kitchen`, `list_farms` | Months of food and drink in stock, seeds, plots per season, kitchen bans |
| Shelter | `list_buildings`, `list_zones` | Beds, dining, doors, bedrooms assigned, outdoors exposure |
| Industry | `list_workshops`, `list_work_orders`, `list_building_materials` | Which shops exist, orders waiting on a manager, materials on hand |
| Storage | `list_stockpiles`, `list_stocks` | Piles by category, goods rotting outside, nothing accepting refuse or corpses |
| Defense | `list_squads`, `list_others`, `list_buildings` | Hostiles on the map, squads, traps, a door on the entrance |
| Map | `get_map_bounds`, `get_wagon`, `find_exposed_walls`, `get_area_map` | Where the fort is, the surface level, reachable rock, water |
| Trade | `list_caravans`, `get_trade_depot`, `get_broker`, `list_diplomats` | A caravan on the way, no depot, broker not appointed |
| Events | `list_event_kinds`, `get_timer_status` | Which events the player enabled, whether the timer runs |

## Planning rules

- **Plan seasons ahead.** The plan covers at least the next year in phases. Only the current
  phase has fine detail (coordinates, ids, counts). Later phases are one line each.
- **Phases and tasks.** A phase is a goal the fort reaches (sealed shelter, food secure, first
  caravan traded, militia armed). A task is one thing you can do with a few tool calls and
  verify by reading back. Number both. Give every task a state word: `todo`, `active`,
  `done`, `blocked`. A blocked task names what unblocks it.
- **Pause while planning.** When `pause_write` is on, `set_paused(true)` before taking stock
  and `set_paused(false)` once the plan is written. Never leave the game paused when you
  finish a turn unless the player asked for it.
- **Act, then tell.** Work freely inside the permissions the player enabled. After each batch
  of changes, `send_message` with one short line of what changed and a position to zoom to.
  Do not ask in chat before every write.
- **A missing permission is not a blocker.** When a tool returns `NOT_ALLOWED`, note the
  toggle's name once in chat and in a `send_message`, mark the task `blocked`, and move to
  work that is allowed.
- **Some decisions are the player's.** Accepting a petition, pressing Trade, holding the
  liaison meeting, and anything the plan marks as theirs. Say what you recommend with
  `send_message`, record it under `Log`, and continue with other tasks.
- **Verify by reading back.** Every write is followed by the read that proves it:
  `list_designations` after `designate_dig`, `list_buildings` or `get_tile` after a
  placement, `get_squad` after a squad change, `read_plan` after a plan write.
- **Dry-run first.** `plan_dig`, `plan_construction`, and `plan_furniture` show what a
  placement would do. Use them before the matching write when the footprint is not trivial.

## The plan file

`plan.md` always has this shape. Keep the headings exactly, so the next session can parse
them at a glance.

```markdown
# <Fort name> plan

Status: <fort name>, <in-game date>, population <n>, last updated <in-game date>

## Goals
<the player's goals from read_goals, restated in one line each; "none given" if empty>

## Phases
### Phase 1: <aim in a few words>  [active]
1. <task>  [done]  <coordinates or ids that matter>
2. <task>  [active]
3. <task>  [blocked: needs dig_write]
### Phase 2: <aim>  [todo]
- <one line of what it will contain>

## Standing rules
- <what this fort has taught you, and player instructions that persist>

## Log
- <date>: <what happened, what changed in the plan, decisions left to the player>
```

- `write_plan` replaces the file; use it for the first plan and for rewrites.
- `append_plan` adds to the end; use it for `Log` entries, since the log is the last section.
- The file is capped at 64 KB. When `get_plan_info` shows it past about 48 KB, rewrite it with
  `write_plan`: fold the log into `Standing rules` and the phase states, and keep only the
  last few log entries.
- Standing rules are for things the game taught you about this fort (a cavern at z 90, the
  river floods in spring, the player wants no animal slaughter). Rules that apply to every
  fort live in the `fortress-quirks` skill, not here.

## Cadence

| Trigger | What to do |
|---|---|
| A `goals` channel message | `read_goals`, update the `Goals` section, re-plan the phases if the goals changed, reply with `send_message` |
| A `timer` channel message | Status check: `get_time`, `get_fort_status`, `get_stock_bar`, `list_others` for hostiles, then advance the active tasks, append a `Log` entry, and `send_message` a two-line summary |
| An `events` channel message | Read what each event names with the tools (units, tiles, caravans), act if it needs action now, and note it under `Log` if it changed the plan |
| Season change | Review food, drink, farm crops for the new season, and the phase list |
| No task active | Pick the next `todo` task of the active phase; when the phase is done, mark it and activate the next |

Without a channel (events and prompts never arrive), poll with `poll_events` on a `/loop`
and treat each batch the same way.

## First plan for a new fort

1. Take stock as above.
2. Write the plan with the player's goals first and these phases unless the fort is already
   past them: a sealed entrance and beds; food and drink for a year (farms, a still, a kitchen,
   stockpiles); the administrative seats filled (manager, bookkeeper, broker); a trade depot
   before the first caravan; a militia with a uniform before the second year. Then the player's
   goals as their own phases.
3. `send_message` that the plan is written, with a zoom position on the fort's entrance.
