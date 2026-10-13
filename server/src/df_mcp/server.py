"""MCP server entry point. Runs over stdio; all logging goes to stderr."""

from __future__ import annotations

import logging
import os
import sys

from mcp.server import MCPServer

from df_mcp import __version__
from df_mcp.bridge import Bridge
from df_mcp.tools import console, core, nobles, stocks, time, units

INSTRUCTIONS = """\
You are connected to a running Dwarf Fortress game through DFHack. Start with `ping` to confirm
the bridge is up and a map is loaded, then `get_permissions` to learn what the player allows.
Observe with `get_time`, the unit lists (`list_units`, `list_citizens`, `list_domesticated`,
`list_others`), `find_unit` to turn a name into an id, `get_unit` for one unit, and
`get_unit_sheet` or `get_unit_full_sheet` for its profile tabs. `set_unit_nickname` is the
only unit tool that changes the game and needs its own permission. `list_nobles` shows the
fort's positions and holders; `assign_noble` appoints a citizen and needs `nobles_write`.
`get_stock_bar`, `list_stocks`, `find_items`, and `list_artifacts` cover what the fort owns;
`get_fort_status` gives wealth, rank, and population.
`run_console_command` only runs commands the player has allowlisted in-game. Every call pauses
the game briefly, so batch what you can.
"""

TOOL_MODULES = (core, time, units, nobles, stocks, console)


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
