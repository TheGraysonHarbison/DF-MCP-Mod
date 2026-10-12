from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="get_time", annotations=READ_ONLY)
    def get_time() -> dict[str, Any]:
        """Get the in-game date, time of day, season, weather, and pause state.

        Includes the fort name when one is loaded and the number of real seconds since the
        game was last saved. Requires a loaded fortress map.
        """
        return call(bridge, "time.now")
