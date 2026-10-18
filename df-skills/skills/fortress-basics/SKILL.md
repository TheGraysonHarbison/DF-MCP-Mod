---
name: fortress-basics
description: Strategy an experienced Dwarf Fortress player follows and a new one gets wrong. Use when planning food and drink stocks, barrels and bins, storage, trade and what to sell or buy, fort wealth, room value and offices, cage traps and animals, idle miners, dwarves' happiness underground and in rain, elven tree-cutting demands at a meeting, and when answering petitions with list_petitions and answer_petition.
when_to_use: Planning a phase or a season's work, preparing for a caravan or a diplomat, judging stock levels, or a petition event arrives.
---

# Fortress Basics

Strategy from the owner's notes on advanced play and on Claude-played forts that went wrong,
checked against the DF wiki. Numbers are the wiki's where it has them. For how the bridge and
the game mechanically behave (pauses, caps, diagonal movement, seeds, the trade flow, error
codes), see `fortress-quirks`.

## Food and drink

- **Rates.** A dwarf eats about 8 times a year (2 a season) and drinks about 20 times a year
  (5 a season); one meal or one drink is one unit of stock.
- **Yearly stock targets**, with a 1.5 margin for migrants, visitors, and spoilage:
  - food = 8 x population x 1.5 = **12 per dwarf**
  - drink = 20 x population x 1.5 = **30 per dwarf**

  A fort of 30 keeps 360 food and 900 drink. Read the counts with `get_stock_bar` and the
  population with `get_fort_status`; below target, food or drink is the next task.
- **Drink comes first.** A dwarf dies of thirst far sooner than of hunger, and goes slow
  without alcohol after a season.
- **One brew job makes 5 drinks per plant**: a stack of 5 plump helmets becomes 25 wine in one
  barrel. Each job needs an empty barrel or pot. Queue brewing with `create_work_order`
  (`reaction="BREW_DRINK"` or the job `find_job_types` names), usually `frequency="Monthly"`.
- **A meal's stack is the sum of its ingredients**: easy meals take 2 ingredients, fine 3,
  lavish 4; 1 helmet + 10 + 10 + 10 makes 31 roasts. Cook from big stacks of meat, fish,
  cheese, and drink-heavy ingredients, not single plants. Cooking destroys seeds (see
  `fortress-quirks`, Sustainable farming) and `set_kitchen` decides what may be cooked.

## Storage

- **Keep 15 empty barrels and 10 empty bins on hand** at all times. Production fills
  containers fast, and brewing stops without a barrel.
- Make it a standing order: `create_work_order` for barrels and bins (`find_job_types`
  names the jobs; `material="any wood"`) with `frequency="Monthly"`, sized to the shortfall.
- Check with `list_stocks(category="barrel")` and `list_stocks(category="bin")`. The bridge
  has no empty-container filter: compare the totals with what is stored in them (drink,
  food, bins of gems and cloth) and err on the side of making more.

## Trade

- **Value is base x material x quality.** Base value follows how processed the item is (rough
  gem 6, stone or log 3, block or bar 5, furniture and crafts 10, cut gem 20, statue 25,
  mechanism 30); the material multiplies it (gems x2 to x60, gold x30, iron x10). Quality
  adds little since v50 (masterful x2 + 30). A clear glass table beats a wooden one on
  every factor.
- **Cut gems are the main trade good.** A cut gem is worth over three times the rough stone,
  is light, and many fit in one bin, so the weight limit barely bites. Mining turns up rough
  gems; keep a jeweler cutting, and have **a bin of cut gems ready by autumn** for the
  caravan. Check with `list_stocks(category="smallgem")` (cut gems; rough ones are `rough`).
- **Never offer an artifact.** It is usually the largest single piece of the fort's wealth
  (artifact furniture counts three times), the creator may have claimed it, and other
  civilizations may claim or steal it. `offer_trade` and `select_trade_goods` have no
  artifact guard: check `list_artifacts` and leave those ids out of `bring_to_depot`.
- **Buy raw, not processed.** Bars, cloth, leather, wood, seeds, and food are worth buying;
  finished furniture, weapons, and crafts are not, since the fort can make them and imported
  goods are rarely above superior quality. **Musical instruments** are the exception: buy
  them for the tavern and performers.
- **Buy animals to start breeding.** Caravan animals are fully tame and never revert. Grazers
  starve without a pasture: paint a pen with `create_zone(type="pen")` and `assign_zone`
  each animal. Rare beasts (dinosaurs, giant animals) are seldom sold; catch them with cage
  traps instead and train them in an `animal_training` zone.
- **Ask for next year** at the liaison meeting with `set_trade_requests`: raw materials and
  seeds the fort lacks.

## Wealth

- **Wealth is made in the fort, never bought.** Imports are listed apart from created
  wealth, and created and exported wealth are what earn nobles (a baron needs 100,000
  overall and 10,000 exported) and the fort's rank. Read the breakdown with
  `get_fort_status`.
- Wealth also draws thieves, ambushes, and sieges (sieges from about population 80): grow the
  militia with it.

## Rooms and offices

- **Engravings are the cheapest room value.** Smoothed walls count 5x and smoothed floors 4x
  their material; an engraving adds 10 x material x quality (up to x12 for a masterwork).
  `designate_dig(kind="smooth")`, then `kind="engrave"` once smoothed.
- **High-quality furniture comes second.** Every piece adds its full value, but since v50
  quality adds less than engraving. Use valuable materials for nobles' rooms.
- Room tiers by value: Modest 100, Quarters 250, Decent 500, Fine 1000, Great 1500, Grand
  2500, Royal 10000. `get_zone` shows the game's label (`room_description`). Overlapping
  floor tiles drop every room on them to zero: keep zones apart.
- **Offices go in rooms**: an enclosed dug room with a solid border (`fortress-quirks`,
  Movement and rooms), a chair and a table, painted with `create_zone(type="office")` and
  owned with `assign_zone`. The manager, bookkeeper, and later the mayor need one; visitors
  petition at the office.

## Labor

- **Miners are never idle.** Keep a dig queue ahead of them: storage halls, bedrooms, the next
  workshop level, and exploratory tunnels for gems and ore. `list_designations` shows the
  queue; when it is nearly empty, `designate_dig` the next phase's rooms. `list_work_details`
  shows who is on Miners; idle citizens show in `list_citizens`.
- The same holds for other idle dwarves: give them hauling, smoothing, or a work order
  rather than letting them wander.

## Defense and animals

- **Cage traps need empty cages.** A trap is armed with a mechanism and a cage, and after a
  catch it is reloaded only with an empty cage. Keep a stock of cages (a Monthly
  `create_work_order` while traps are in use) beside `place_furniture(type="cage_trap")`.
- Cage traps catch most invaders and wild beasts but not titans, forgotten beasts, or
  trap-avoiding creatures. A sprung trap left for about a year lets its catch escape: move
  captives to an animal stockpile or a pit.

## Elves

- **Never give in to the tree-huggers.** When the elven diplomat asks for a tree-cutting
  quota at the meeting, refuse it with `step_meeting_dialog(action="choose", label=...)`
  using the refusal's exact label from `get_meeting_dialog`. Record the refusal under
  `Log`.
- The wiki is clear that refusing worsens relations and can lead to war: have the
  entrance sealable and a militia ready, and expect elven archers and their tamed beasts.
  Tower-caps and other underground trees count against a quota; saplings do not.
- Never offer elves anything wooden (`fortress-quirks`, Trade and diplomats).

## Happiness

- **Keep dwarves underground.** Living, working, eating, and sleeping below ground avoids
  weather thoughts, and the fort is easier to defend.
- **Rain sours moods.** Any dwarf caught outside in rain or snow gets an unhappy thought
  (those who like working outdoors are spared). Check `get_time` for the weather before
  sending haulers or woodcutters out, and keep surface work to few dwarves.
- **Counterpoint: cave adaptation.** A dwarf underground for over a year gets irritated by
  the sun, and after about a year and a half vomits when outside, which can leave a soldier
  defenseless for a moment. It does nothing while they stay below and is cured by the
  episode itself. Expect it in soldiers sent to the surface; it is not a reason to bring the
  fort up.

## Petitions

Claude answers petitions on its own, within the permissions the player gave. A `petition`
event says one has arrived. `list_petitions` shows each with its id, kind, petitioners, and
any detail; `answer_petition(id, accept)` answers it. After every answer, `send_message`
one line: who asked, what, and the answer with the reason. Note it under `Log`.

| Petition | Answer |
|---|---|
| Residency: monster hunter or slayer | Accept. They hunt beasts above ground or in the caverns at no cost, and are expendable fighters. |
| Residency: mercenary | Accept when there are beds and food to spare; they can join squads (not lead them). |
| Residency: scholar | Accept when a library exists or is planned; otherwise deny. |
| Residency: performer | Accept when the fort has a tavern; deny otherwise. Troupes come as a group, so check beds and drink first. |
| Location: guildhall or temple | Accept only when the fort can build it in time; else deny. |
| Citizenship | Accept when the resident has behaved; residents ask after about two years. |

- **Locations take a plan.** A guildhall agreement is abandoned if the hall is not built
  within a year; a temple's also lapses if ignored. The location must reach 2,000 value
  (6,000 on a hard economy; a grand guildhall 10,000). Accept only when the fort has the
  space, the dig time, and the furniture to reach that within the year, and add a plan
  task for it at once with the deadline. The bridge cannot attach a temple or guildhall to
  a zone yet: Claude digs, engraves, and furnishes the room and paints a meeting area, then
  asks the player with `send_message` to set it as the location in the zone's menu.
- **Deny when the fort cannot deliver**: no room to dig, a food or drink shortfall, a
  siege, or too few beds. Denied visitors simply leave; a broken location promise
  upsets the petitioners.
- **Weigh a petitioner's history only when the game shows it** (`get_unit`,
  `get_unit_sheet`): deny a known criminal or troublemaker. Do not guess beyond what is
  visible.
- **Never answer an artifact or parley petition** without the player: say what it asks with
  `send_message` and leave it to them.
- `NOT_ALLOWED` on `answer_petition` names the permission; tell the player once and leave
  the petition to them.

## Sources

DF wiki (dwarffortresswiki.org, v53 pages, checked 2026-10-17): Food, Alcohol, Thirst,
Brewer, Kitchen, Item value, Item quality, Gem, Gem cutter, Trading, Legendary artifact,
Wealth, Siege, Zone (Quality and value), Engraving, Elf, Trap (Cage trap), Cave adaptation,
Weather (Rain), Thought, Petition, Guildhall, Temple, Visitor, Animal trainer, Domestic
animal. Owner's notes: `docs/Gameplay.md`.
