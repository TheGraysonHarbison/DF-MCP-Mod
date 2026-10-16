# Claude Bridge (DFHack mod)

The in-game half of the DFHack Claude Integration Mod. It exposes a small, permission-gated
JSON RPC surface that the `df-mcp` server (in `../server`) calls through DFHack's remote API.

## Install for development

1. Run `tools/link-mod.sh <path to your Dwarf Fortress folder>` from the repository root.
   It adds this mod's `scripts_modinstalled` folder to `dfhack-config/script-paths.txt`.
2. In the DFHack console: `enable claude-bridge`.
3. Check it: `claude-bridge status`.

## Commands

```
enable claude-bridge          start the bridge (also from gui/control-panel)
disable claude-bridge         stop it
claude-bridge status          show enabled state, permissions, and console allowlist
claude-bridge settings        open the settings window
claude-bridge goals           open the goals window (goals.md and the goal prompt; Ctrl+S sends them)
claude-bridge perm <ns> on|off   toggle a permission namespace (time, units, units_write, nobles,
                                 nobles_write, stocks, orders, orders_write, workshops,
                                 build_write, stockpiles, stockpiles_write, map, console,
                                 settings)
claude-bridge allow <command> add a console command Claude may run
claude-bridge deny <command>  remove it again
claude-bridge test <json>     run a request through the dispatcher locally and print the reply
claude-bridge send <text>     queue a test event with the text for Claude (checks the channel)
claude-bridge event <kind> on|off  enable or disable one event kind (see the settings window)
claude-bridge reload          re-read the Lua modules from disk without disabling (development)
```

Settings are stored in DFHack's mod state folder for `claude-bridge` and apply to every world.
The enabled flag is per fort, like other DFHack enableable scripts.

## What Claude can see and do

Only what the permissions allow. The settings window groups them into General, Units, Items,
and Commands. Reading units, stocks, time, and these settings is on by default. "True stock
counts" is on by default; turn it off and Claude only sees the estimates and bookkeeper records a
player would see.
Renaming units (`units_write`) and assigning noble positions (`nobles_write`) are off until you
turn them on. Console access is deny-all until
you allowlist commands, and running `lua` through the console additionally requires the
`lua_eval` permission.
