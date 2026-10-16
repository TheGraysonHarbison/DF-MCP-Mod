from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_mods", annotations=READ_ONLY)
    def list_mods(limit: int = 25, only_enabled: bool = False) -> dict[str, Any]:
        """The active Dwarf Fortress mods in load order (id, name, version, source: vanilla,
        installed, workshop) and the loaded DFHack plugins with their commands and, for
        plugins that have a switch, whether they are enabled. `only_enabled` keeps only
        switched-on plugins. Use it to learn which raws and tools shape this fort before
        assuming vanilla behaviour.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "settings.mods", {"limit": limit, "only_enabled": only_enabled})
