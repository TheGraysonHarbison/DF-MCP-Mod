from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_workshops", annotations=READ_ONLY)
    def list_workshops(type: str | None = None, limit: int = 25, offset: int = 0) -> dict[str, Any]:
        """List the built workshops and furnaces on the map.

        Each row has the building `id` (use it with `get_workshop`), `kind` (workshop or
        furnace), `type` (Masons, Carpenters, Kitchen, Still, Smelter, ... or a custom
        building code), `name`, `custom_name`, `pos` and `bounds`, `built`, the number of
        queued `jobs`, whether a `strange_mood` has claimed it, and the item count.
        `type` filters to one type, e.g. "Kitchen"; `counts_by_type` always covers the map.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "workshops.list", {"type": type, "limit": limit, "offset": offset})

    @mcp.tool(name="get_workshop", annotations=READ_ONLY)
    def get_workshop(building_id: int, limit: int = 25) -> dict[str, Any]:
        """Inspect one workshop or furnace by building id.

        Returns the list row plus `jobs` (each with name, worker, flags such as suspend or
        repeat, the work order it came from, and whether it is a strange mood job),
        `inventory` (items sitting in the workshop, capped at `limit`), `materials` (the items
        it was built from), and its worker `profile`.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "workshops.get", {"id": building_id, "limit": limit})
