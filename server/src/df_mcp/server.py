"""MCP server entry point. Runs over stdio; all logging goes to stderr."""

from __future__ import annotations

import logging
import os
import sys

from mcp.server import MCPServer

from df_mcp import __version__
from df_mcp.bridge import Bridge
from df_mcp.tools import (
    build,
    console,
    core,
    map,
    nobles,
    orders,
    stockpiles,
    stocks,
    time,
    units,
    workshops,
)

INSTRUCTIONS = """\
You are connected to a running Dwarf Fortress game through DFHack. Start with `ping` to confirm
the bridge is up and a map is loaded, then `get_permissions` to learn what the player allows.
Observe with `get_time`, the unit lists (`list_units`, `list_citizens`, `list_domesticated`,
`list_others`), `find_unit` to turn a name into an id, `get_unit` for one unit, and
`get_unit_sheet` or `get_unit_full_sheet` for its profile tabs. `set_unit_nickname` is the
only unit tool that changes the game and needs its own permission. `list_nobles` shows the
fort's positions and holders; `assign_noble` appoints a citizen and needs `nobles_write`.
`get_stock_bar`, `list_stocks`, `find_items`, and `list_artifacts` cover what the fort owns;
`get_fort_status` gives wealth, rank, and population. Work orders: `list_work_orders`,
`find_job_types`, and with `orders_write` `create_work_order`, `edit_work_order`,
`delete_work_order`; only the manager dwarf approves them. `list_workshops` and
`get_workshop` show built workshops, their jobs, and their contents. The map: `get_map_bounds`
first, then `get_wagon`, `get_tile`, `get_area_map`, and `find_build_space`. `place_workshop`
(needs `build_write`) queues a blueprint at a spot `find_build_space` returned.
`list_stockpiles` and `get_stockpile` show where goods are stored and what each pile accepts.
`run_console_command` only runs commands the player has allowlisted in-game. Every call pauses
the game briefly, so batch what you can.
"""

TOOL_MODULES = (
    core,
    time,
    units,
    nobles,
    stocks,
    orders,
    workshops,
    map,
    build,
    stockpiles,
    console,
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
        build_server(bridge).run(transport="stdio")
    finally:
        bridge.close()


if __name__ == "__main__":
    main()
