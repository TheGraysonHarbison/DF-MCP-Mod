# claude-df: skills for playing the fort

A Claude Code plugin that teaches a session how to run a Dwarf Fortress fort through the
`dfhack` MCP server in this repository. It replaces the development `CLAUDE.md`, which does
not ship with releases.

## Install

From the folder you extracted the release into:

```
claude plugin marketplace add ./df-skills
claude plugin install claude-df@claude-df --scope project
```

The first command registers this folder as a plugin source; the second enables the plugin
for this project (it writes `.claude/settings.json` here). `claude plugin details
claude-df@claude-df` lists what was loaded. Claude Code copies the plugin when it installs
it, so after editing anything in this folder run `claude plugin marketplace update claude-df`
and install again. For a one-off session without installing, start Claude Code with
`claude --plugin-dir df-skills` instead.

## Skills

Skills trigger on their own when the situation matches their description, and each can be
invoked by hand as `/claude-df:<name>`.

- **fortress-planner** (`skills/fortress-planner/SKILL.md`): the session-start sequence
  (ping, permissions, time, goals, plan, status), how to take stock of the whole fort, the
  planning rules (seasons ahead, phases and tasks with states, pause while planning, act then
  tell the player), the fixed template for `plan.md` in the save, and what to do on goals,
  timer, and event messages.
- **work-subdivision** (`skills/work-subdivision/SKILL.md`): how the session model manages
  while the two worker agents below do the mechanical and medium work, what never leaves
  the manager, when to delegate, and the brief every delegation carries.
- **fortress-quirks** (`skills/fortress-quirks/SKILL.md`): what the game and the bridge have
  taught us: calls pause the game, lists are capped, dwarves move diagonally so rooms need
  solid corners, crops are set after the plot is built, a seed reserve per crop keeps farming
  sustainable, work orders need a manager, the
  Trade button and the liaison meeting stay with the player, never touch texture fields,
  and a table of error codes with what to do about each.

- **fortress-basics** (`skills/fortress-basics/SKILL.md`): strategy from the owner's notes
  checked against the DF wiki: yearly food and drink targets per dwarf, spare barrels and
  bins, what to sell (cut gems, never artifacts) and buy (raw goods, instruments, animals),
  wealth made in the fort, room value from engravings, offices, idle miners, cage traps,
  refusing elven tree quotas, underground living and rain, and the policy for answering
  petitions.

## Agents

- **df-scout** (`agents/df-scout.md`, Haiku): lists, surveys, counts, and bulk placement from
  an exact brief. Stops and reports rather than guessing.
- **df-steward** (`agents/df-steward.md`, Sonnet): one judgment question at a time: a trade,
  crops, a unit summary, a squad's uniform, a site choice.

Both inherit the `dfhack` tools from the session. Neither writes the plan or talks to the
player; the manager does.
