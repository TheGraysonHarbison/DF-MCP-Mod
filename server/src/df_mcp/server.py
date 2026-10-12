"""MCP server entry point. Runs over stdio; all logging goes to stderr."""

from __future__ import annotations

import logging
import os
import sys

from mcp.server import MCPServer

from df_mcp import __version__
from df_mcp.bridge import Bridge
from df_mcp.tools import console, core, time, units

INSTRUCTIONS = """\
You are connected to a running Dwarf Fortress game through DFHack. Start with `ping` to confirm
the bridge is up and a map is loaded, then `get_permissions` to learn what the player allows.
Observe with `get_time`, `list_units`, and `get_unit`. `run_console_command` only runs commands
the player has allowlisted in-game. Every call pauses the game briefly, so batch what you can.
"""

TOOL_MODULES = (core, time, units, console)


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
