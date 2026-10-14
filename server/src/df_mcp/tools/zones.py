from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY

TYPES = (
    "meeting_area",
    "bedroom",
    "dining_hall",
    "dormitory",
    "barracks",
    "archery_range",
    "office",
    "tomb",
    "pen",
    "pit",
    "pond",
    "dump",
    "water_source",
    "fishing",
    "sand",
    "clay",
    "gather",
    "animal_training",
    "dungeon",
)


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_zones", annotations=READ_ONLY)
    def list_zones(
        type: str | None = None,
        query: str | None = None,
        active: bool | None = None,
        limit: int = 25,
        offset: int = 0,
    ) -> dict[str, Any]:
        """List the fort's activity zones.

        Each row has `id` (the key `get_zone` takes), `number` and `label` (the game's
        "Zone #n" unless named), `name`, `type` (meeting_area, bedroom, dining_hall,
        dormitory, barracks, archery_range, office, tomb, pen, pit, pond, dump,
        water_source, fishing, sand, clay, gather, animal_training, dungeon), `active`,
        `bounds`, `pos`, `tiles`, `assignment` (owner, units, squads, location, or none),
        `owner`, `assigned_units` and `squads` counts, and `location` (tavern, temple,
        library, guildhall, hospital) when attached. Filter by `type`, by `query` on the
        name, or by `active`. `counts_by_type` covers the whole fort.
        """
        if type is not None and type.strip().lower().replace(" ", "_") not in TYPES:
            raise ValueError(f"type must be one of {', '.join(TYPES)}")
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(
            bridge,
            "zones.list",
            {
                "type": type.strip().lower().replace(" ", "_") if type else None,
                "query": query,
                "active": active,
                "limit": limit,
                "offset": offset,
            },
        )

    @mcp.tool(name="get_zone", annotations=READ_ONLY)
    def get_zone(zone_id: int, limit: int = 25) -> dict[str, Any]:
        """Get one zone by id: the list row plus its `extents` (tiles, capped by `limit`
        with `tiles` as the total), `settings` per type (pit_or_pond and keep_filled;
        pick_trees, pick_shrubs, gather_fallen; shoot_from for archery ranges;
        allow_pets and allow_citizens for tombs; check_occupants for pens), the
        `assigned_units` (animals in a pen, pit, or pond) and `owner`, `squads`,
        `location`, `contained_buildings` (beds, chairs, workshops inside it), and
        `room_description` (the game's quality label, such as "Decent Bedroom").
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "zones.get", {"id": zone_id, "limit": limit})
