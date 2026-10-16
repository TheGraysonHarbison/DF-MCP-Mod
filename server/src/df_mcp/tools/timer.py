from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="get_timer_status", annotations=READ_ONLY)
    def get_timer_status() -> dict[str, Any]:
        """Read the player's prompt timer: whether it is on, its mode (every N in-game days,
        every month change, or every N real minutes while unpaused), the prompt it sends,
        how far along it is, and how often it has fired. Its prompt arrives as a `timer`
        channel message; the player changes it in the settings Timer tab.
        """
        return call(bridge, "timer.status")
