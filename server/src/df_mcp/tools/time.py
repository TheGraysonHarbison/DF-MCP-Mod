from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="get_time", annotations=READ_ONLY)
    def get_time() -> dict[str, Any]:
        """Get the in-game date, time of day, season, weather, and pause state.

        Includes the fort name when one is loaded and the number of real seconds since the
        game was last saved. Requires a loaded fortress map.
        """
        return call(bridge, "time.now")

    @mcp.tool(name="set_paused", annotations=WRITE_SAFE)
    def set_paused(paused: bool) -> dict[str, Any]:
        """Pause or unpause the game. Needs `pause_write`.

        `paused=true` stops the simulation, `paused=false` lets it run. Returns
        `paused_before`, `paused` (the state after the call), and `changed`. The game must
        be running for dwarves to carry out any order Claude places, and nothing happens
        while it is paused; pause again before reading a long report so the world holds
        still. The read side is `get_time` (`paused`).
        """
        return call(bridge, "time.set_pause", {"paused": bool(paused)})
