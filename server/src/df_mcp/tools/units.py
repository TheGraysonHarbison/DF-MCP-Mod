from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY

CATEGORIES = (
    "citizen",
    "resident",
    "visitor",
    "merchant",
    "diplomat",
    "animal",
    "wildlife",
    "invader",
    "undead",
    "hostile",
    "other",
)


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_units", annotations=READ_ONLY)
    def list_units(
        category: str | None = None,
        include_dead: bool = False,
        limit: int = 200,
        offset: int = 0,
    ) -> dict[str, Any]:
        """List units on the map: citizens, visitors, animals, wildlife, invaders, and more.

        `category` filters to one of: citizen, resident, visitor, merchant, diplomat, animal,
        wildlife, invader, undead, hostile, other. Omit it for everything. Each row has the unit
        id, name, category, race, profession, age, sex, position, and current job. Use
        `get_unit` with an id for details. Results are paged with `limit` and `offset`;
        `counts_by_category` always covers the whole map.
        """
        if category is not None and category not in CATEGORIES:
            raise ValueError(f"category must be one of {', '.join(CATEGORIES)}")
        return call(
            bridge,
            "units.list",
            {
                "category": category,
                "include_dead": include_dead,
                "limit": limit,
                "offset": offset,
            },
        )

    @mcp.tool(name="get_unit", annotations=READ_ONLY)
    def get_unit(unit_id: int) -> dict[str, Any]:
        """Get details for one unit by id: mood, stress, skills, labors, wounds, squad, flags.

        Ids come from `list_units`.
        """
        return call(bridge, "units.get", {"id": unit_id})
