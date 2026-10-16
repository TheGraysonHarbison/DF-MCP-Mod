---
name: work-subdivision
description: Split Dwarf Fortress work across models for speed and token economy. Use whenever a fort task means sorting or filtering long lists, surveying map areas or walls, reading many unit sheets, weighing a trade or a crop choice, or placing orders, designations, stockpiles, or constructions in bulk. The session model manages; the df-steward agent (Sonnet) judges; the df-scout agent (Haiku) surveys and places.
when_to_use: Any fort task that would take more than a handful of dfhack tool calls, or that reads lists longer than a screen.
---

# Work Subdivision

Three roles share the fort. You, the session model, are the manager. Two sub-agents ship
with this plugin and the Agent tool offers them by name: `df-steward` and `df-scout` (the
listing may prefix them with the plugin name). Both inherit the `dfhack` tools, so they
touch the game directly.

| Role | Model | Does | Does not |
|---|---|---|---|
| Manager (you) | the session model, Opus or better | Reads goals, events, timer prompts, and chat; takes stock; plans; decides; writes `plan.md`; sends in-game messages; verifies results | Walk tiles, page through lists, or place orders one by one |
| Steward (`df-steward`) | Sonnet | Medium judgment with a clear question: weigh a trade with `offer_trade`, choose crops per season and kitchen bans, read unit sheets and summarise mood, health, or skills, compose a squad and its uniform, pick a workshop site from `find_build_space` results | Change the plan, talk to the player, or decide what the fort should do next |
| Scout (`df-scout`) | Haiku | Mechanical work from an exact brief: filter and sort lists, survey a map box or exposed walls, count stock, walk tiles, and place designations, orders, stockpiles, and constructions whose coordinates and counts you already wrote down | Choose coordinates, interpret ambiguous results, or decide anything |

If you find yourself running on Sonnet or Haiku as the session model, say once that the
manager role expects Opus or better and suggest `/model opus`, then carry on.

## What stays with the manager

- The session-start sequence and the plan file. Workers never call `write_plan` or
  `append_plan`.
- `send_message` and chat with the player, so the fort speaks with one voice.
- Channel messages: events, goals, and timer prompts arrive to you and you decide what they
  mean before anyone acts.
- Anything irreversible without a clear spec: dismantling, disbanding, deleting stockpiles or
  zones, trade offers, and squad orders to kill.
- The final read-back of a worker's result when it mattered (one `list_designations` or
  `list_buildings` call, not a repeat of the survey).

## When to delegate

Delegate when the work is mechanical and the brief can be written exactly:

- A list that will exceed its 25-row cap and needs filtering (every citizen with a skill,
  every item of a kind, every tree in a box): scout, with the `limit` to use.
- A survey over an area: `get_area_map` views, `find_exposed_walls`, `get_tile` walks,
  `list_plants`: scout.
- Bulk placement from a plan you already have: rooms with coordinates, a batch of work
  orders with names and counts, stockpiles with boxes and categories: scout.
- A judgment with a clear question and a clear output: steward.
- Several independent surveys: several scouts in one message, so they run at once.

Do it yourself when it is one or two calls, when the brief would take longer to write than
the work, or when the result decides what the plan does next.

Never re-run a delegated survey yourself to check it. Read the worker's summary, spot-check
one fact if it matters, and move on.

## The brief

Every delegation carries these parts, in this order. A worker with a thin brief guesses,
and a guess in the game is a dug hole.

1. **Goal** in one sentence.
2. **Known facts**: ids, coordinates, z-levels, the surface level, permissions that are on,
   materials in stock. Everything the worker would otherwise have to look up.
3. **Exact calls or shapes**: which tools, with which arguments, in which order. For
   placement, the boxes or points themselves. For a filter, the field and the value.
4. **Limits**: the `limit` to pass, how many results you want back, how many calls at most.
5. **Output format**: a short table or list with the fields you need, counts, and ids. Never
   raw tool dumps.
6. **Stop rule**: what makes the worker stop and report instead of continuing (a refusal,
   `NOT_ALLOWED`, a footprint that is not clear, a count that differs from the brief).

Example brief for a scout:

```
Goal: mark the bedroom block for digging.
Known: surface z 122, fort entrance stair at (24,17), dig_write is on, rooms are at z 119.
Calls: for each room below, plan_dig(kind="mine", box) first; if the plan reports no
overlaps and only natural wall, designate_dig with the same box. Rooms (x1,y1)-(x2,y2) at
z 119: (10,10)-(12,12), (14,10)-(16,12), (18,10)-(20,12). Corridor (10,14)-(20,14).
Limits: at most 8 calls; report with limit 50 on list_designations at the end.
Output: one line per room: box, tiles planned, tiles designated, any skipped tile and why.
Stop: if any plan_dig shows an existing designation, a constructed wall, or open space in
the box, place nothing for that room and report it.
```

Example brief for a steward:

```
Goal: decide what to sell to the dwarven caravan at the depot.
Known: caravan id 3 is at the depot, broker 842 is present, trade_write is on, we want a
steel anvil and drinks; we can spare stone crafts, extra wooden furniture, and cloth.
Calls: get_trade_depot, list_stocks for crafts, furniture, cloth (limit 100 each),
offer_trade with candidate sets until the merchant accepts with margin.
Limits: at most 12 calls. Do not call select_trade_goods; return the set to me.
Output: the item ids and names to offer, their value, what we get, and the merchant's
expected reaction. One alternative set.
Stop: if the caravan is not at the depot or offer_trade refuses every set.
```

## Reading results

- Workers return summaries. Put the facts you will reuse (ids, coordinates, counts) into the
  plan's active task, not into your head.
- A worker that reports `NOT_ALLOWED` has found a permission the player did not enable:
  name the toggle to the player once and mark the task blocked.
- A worker that stops on its stop rule did the right thing. Decide, fix the brief, and send
  it again rather than finishing the job by hand.
- A worker that guessed (coordinates it was not given, an id it did not read) is a brief
  problem. Tighten the brief before the next delegation.
