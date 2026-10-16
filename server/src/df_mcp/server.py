"""MCP server entry point. Runs over stdio; all logging goes to stderr."""

from __future__ import annotations

import logging
import os
import sys

import anyio
from mcp.server import MCPServer

from df_mcp import __version__
from df_mcp.bridge import Bridge
from df_mcp.channel import run_stdio_with_channel
from df_mcp.tools import (
    build,
    console,
    construct,
    core,
    dev,
    dig,
    diplomats,
    events,
    farms,
    furniture,
    kitchen,
    map,
    messages,
    military,
    nobles,
    orders,
    plan,
    plants,
    stockpiles,
    stocks,
    time,
    timer,
    trade,
    units,
    workshops,
    zones,
)

INSTRUCTIONS = """\
You are connected to a running Dwarf Fortress game through DFHack. Start with `ping` to confirm
the bridge is up and a map is loaded, then `get_permissions` to learn what the player allows.
Observe with `get_time`, the unit lists (`list_units`, `list_citizens`, `list_domesticated`,
`list_others`), `find_unit` to turn a name into an id, `get_unit` for one unit, and
`get_unit_sheet` or `get_unit_full_sheet` for its profile tabs. `set_unit_nickname` is the
only unit tool that changes the game and needs its own permission. `list_nobles` shows the
fort's positions and holders; `assign_noble` appoints a citizen and needs `nobles_write`.
Squads: `list_squads`, `get_squad`, and with `military_write` `create_squad`, `rename_squad`,
`add_to_squad`, `remove_from_squad`, `set_squad_leader`, `disband_squad`.
`get_stock_bar`, `list_stocks`, `find_items`, and `list_artifacts` cover what the fort owns;
`get_fort_status` gives wealth, rank, and population. Work orders: `list_work_orders`,
`find_job_types`, and with `orders_write` `create_work_order`, `edit_work_order`,
`delete_work_order`; only the manager dwarf approves them. `list_workshops` and
`get_workshop` show built workshops, their jobs, and their contents. The map: `get_map_bounds`
first, then `get_wagon`, `get_tile`, `get_area_map`, and `find_build_space`. `place_workshop`
(needs `build_write`) queues a blueprint at a spot `find_build_space` returned.
`list_stockpiles` and `get_stockpile` show where goods are stored and what each pile accepts.
`list_farms`, `get_farm`, and `set_farm_crops` cover farm plots (place one with
`place_furniture(type="farm_plot")` over a box of soil or mud floor). `list_kitchen` shows which
ingredients in stock may be cooked or brewed; `set_kitchen` changes that (needs `kitchen_write`).
Digging: `find_exposed_walls` finds reachable rock, `list_designations` shows existing orders,
`plan_dig` previews a box, and with `dig_write` `designate_dig` places mining, staircase,
channel, ramp, chop, and gather orders and `erase_designations` removes them; `list_plants`
shows the trees and shrubs in a box.
Your plan: `read_plan` at the start of a session; keep plans, rules, and memory about this fort in
it with `write_plan` and `append_plan`; `read_goals` holds the player's goals, which also arrive as
`goals` channel messages when the player sends them.
Trade: `list_caravans`, `get_trade_depot`, `get_broker`; with `trade_write` `request_broker`,
`bring_to_depot`, `cancel_bring`, `offer_trade` (prices and weighs a deal), and once the player
has opened the depot's trade screen, `get_trade_screen` and `select_trade_goods`; the player
presses Trade.
Diplomats: `list_diplomats`, `get_trade_request_options`, and with `trade_write`
`set_trade_requests`; the liaison meeting itself is held by the site leader and finished by the
player.
`send_message` tells the player something inside the game (short, light red, on the left-side
alerts, with an optional position to zoom to); use it when a plan is made or a decision is
needed.
A `timer` channel message is the player's prompt timer asking for a status check: review the
fort and your plan, act, and report with `send_message`. `get_timer_status` shows its settings.
Events: when the session was started with the channel flag, batches of in-game events the
player enabled (see `list_event_kinds`) arrive on their own as channel messages; read the
units, tiles, or petitions they name with the tools and act. `poll_events` is the fallback.
`run_console_command` only runs commands the player has allowlisted in-game. For dev testing,
`dev_create_item` and `dev_exterminate` build `modtools/create-item` and `exterminate` lines
and run them the same way; they change the game outside its rules, so use them only when the
player asks for a test setup, and never exterminate with include_friendly unless the player
names the exact units. Unit spawning is unavailable on this DFHack build. Every call pauses
the game briefly, so batch what you can.
"""

TOOL_MODULES = (
    core,
    time,
    units,
    nobles,
    military,
    stocks,
    orders,
    workshops,
    map,
    build,
    stockpiles,
    dig,
    plants,
    construct,
    furniture,
    farms,
    zones,
    kitchen,
    events,
    plan,
    messages,
    timer,
    trade,
    diplomats,
    console,
    dev,
)


def build_server(bridge: Bridge) -> MCPServer:
    mcp = MCPServer(
        name="dfhack",
        title="Dwarf Fortress (DFHack)",
        instructions=INSTRUCTIONS,
        version=__version__,
    )
    for module in TOOL_MODULES:
        module.register(mcp, bridge)
    return mcp


def main() -> None:
    logging.basicConfig(
        stream=sys.stderr,
        level=os.environ.get("DF_MCP_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    bridge = Bridge(
        host=os.environ.get("DFHACK_HOST", "127.0.0.1"),
        port=int(os.environ.get("DFHACK_PORT", "5000")),
    )
    try:
        anyio.run(run_stdio_with_channel, build_server(bridge), bridge)
    finally:
        bridge.close()


if __name__ == "__main__":
    main()
