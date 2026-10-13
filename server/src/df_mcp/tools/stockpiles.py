from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY

CATEGORIES = (
    "animals",
    "food",
    "furniture",
    "corpses",
    "refuse",
    "stone",
    "ore",
    "ammo",
    "coins",
    "bars_blocks",
    "gems",
    "finished_goods",
    "leather",
    "cloth",
    "wood",
    "weapons",
    "armor",
    "sheet",
)


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_stockpiles", annotations=READ_ONLY)
    def list_stockpiles(
        category: str | None = None, limit: int = 25, offset: int = 0
    ) -> dict[str, Any]:
        """List the fort's stockpiles.

        Each row has the building `id` (use it with `get_stockpile`), `label` (its name or
        "Stockpile #n"), `bounds` and `pos`, `tiles`, the enabled `categories` (food, stone,
        wood, furniture, ...), and the item count. `category` keeps only piles that accept
        that category; `counts_by_category` always covers the map.
        """
        if category is not None and category not in CATEGORIES:
            raise ValueError(f"category must be one of {', '.join(CATEGORIES)}")
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(
            bridge, "stockpiles.list", {"category": category, "limit": limit, "offset": offset}
        )

    @mcp.tool(name="get_stockpile", annotations=READ_ONLY)
    def get_stockpile(building_id: int, limit: int = 25) -> dict[str, Any]:
        """Inspect one stockpile by building id.

        Returns the list row plus `settings` (enabled categories, organic and inorganic
        allowances, container limits, and per-category `details` such as how many sub-entries
        are enabled), `links` (give-to and take-from piles and workshops), and `contents`
        (items capped at `limit`, with `by_type` totals for everything).
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "stockpiles.get", {"id": building_id, "limit": limit})
