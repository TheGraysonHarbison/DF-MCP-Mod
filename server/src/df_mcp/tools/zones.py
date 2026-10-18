from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call, tool_doc
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE
from df_mcp.tools.orders import DELETE

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

    register_writes(mcp, bridge)


def _shape(
    x1: int | None,
    y1: int | None,
    x2: int | None,
    y2: int | None,
    z: int | None,
    center_x: int | None,
    center_y: int | None,
    radius: int | None,
) -> dict[str, Any]:
    circle = [center_x, center_y, radius]
    box = [x1, y1, x2, y2]
    if all(v is not None for v in circle):
        if any(v is not None for v in box):
            raise ValueError(
                "give either a box (x1, y1, x2, y2) or a circle (center_x, center_y, radius)"
            )
        if z is None:
            raise ValueError("a circle needs z")
        return {"circle": {"x": center_x, "y": center_y, "z": z, "radius": radius}}
    if any(v is not None for v in circle):
        raise ValueError("a circle needs center_x, center_y, and radius together")
    if any(v is None for v in box) or z is None:
        raise ValueError(
            "give a box (x1, y1, x2, y2, z) or a circle (center_x, center_y, radius, z)"
        )
    return {"x1": x1, "y1": y1, "x2": x2, "y2": y2, "z": z}


SETTINGS_DOC = """Per-type settings, each optional and refused on the wrong type: `check_occupants`
        (pens, pits, ponds), `keep_filled` (pit or pond; `type` "pit" or "pond" sets it on
        creation), `pick_trees`, `pick_shrubs`, `gather_fallen` (gather zones), `shoot_from`
        (archery ranges: north, south, east, west), `allow_pets`, `allow_citizens` (tombs)."""


def _settings(**kwargs: Any) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key, value in kwargs.items():
        if value is not None:
            out[key] = value
    return out


CREATE_ZONE_DOC = tool_doc(
    """Paint a new activity zone. Needs `zones_write`.

        `type` is one of meeting_area, bedroom, dining_hall, dormitory, barracks,
        archery_range, office, tomb, pen, pit, pond, dump, water_source, fishing, sand,
        clay, gather, animal_training, dungeon. The shape is a box (x1, y1, x2, y2, z, any
        two corners, any size up to the whole map) or a filled circle (center_x, center_y,
        radius 1 or more, z); shapes reaching past the map edge are clipped (`clipped`). Every
        revealed tile counts, walls and water included (walls raise a room's
        value); hidden tiles are left out. Overlapping a zone of the same type is allowed
        but warned about. A bedroom, office, dining hall, or tomb needs the matching
        furniture inside and an owner (`assign_zone`); a pen takes animals the same way.
        Returns the new zone as `get_zone` shows it.""",
    SETTINGS_DOC,
)


EDIT_ZONE_DOC = tool_doc(
    """Change a zone: rename it, activate or deactivate it, grow or shrink it, or
        change its settings. Needs `zones_write`. Its type cannot change.

        `add_box` and `remove_box` are [x1, y1, x2, y2] on the zone's level; `add_circle`
        and `remove_circle` are [center_x, center_y, radius]. Removed tiles leave the zone,
        added revealed tiles join it, and the bounds refit; a zone keeps at least one tile.
        Returns `changed`, `tiles_added`, `tiles_removed`, and the zone.""",
    SETTINGS_DOC,
)


def register_writes(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="create_zone", annotations=WRITE_SAFE, description=CREATE_ZONE_DOC)
    def create_zone(
        type: str,
        x1: int | None = None,
        y1: int | None = None,
        x2: int | None = None,
        y2: int | None = None,
        z: int | None = None,
        center_x: int | None = None,
        center_y: int | None = None,
        radius: int | None = None,
        name: str | None = None,
        active: bool = True,
        check_occupants: bool | None = None,
        keep_filled: bool | None = None,
        pick_trees: bool | None = None,
        pick_shrubs: bool | None = None,
        gather_fallen: bool | None = None,
        shoot_from: str | None = None,
        allow_pets: bool | None = None,
        allow_citizens: bool | None = None,
    ) -> dict[str, Any]:
        args: dict[str, Any] = {
            "type": type.strip().lower().replace(" ", "_"),
            "name": name,
            "active": active,
        }
        args.update(_shape(x1, y1, x2, y2, z, center_x, center_y, radius))
        args.update(
            _settings(
                check_occupants=check_occupants,
                keep_filled=keep_filled,
                pick_trees=pick_trees,
                pick_shrubs=pick_shrubs,
                gather_fallen=gather_fallen,
                shoot_from=shoot_from,
                allow_pets=allow_pets,
                allow_citizens=allow_citizens,
            )
        )
        return call(bridge, "zones.create", args)

    @mcp.tool(name="edit_zone", annotations=WRITE_SAFE, description=EDIT_ZONE_DOC)
    def edit_zone(
        zone_id: int,
        name: str | None = None,
        active: bool | None = None,
        add_box: list[int] | None = None,
        remove_box: list[int] | None = None,
        add_circle: list[int] | None = None,
        remove_circle: list[int] | None = None,
        check_occupants: bool | None = None,
        keep_filled: bool | None = None,
        pick_trees: bool | None = None,
        pick_shrubs: bool | None = None,
        gather_fallen: bool | None = None,
        shoot_from: str | None = None,
        allow_pets: bool | None = None,
        allow_citizens: bool | None = None,
    ) -> dict[str, Any]:
        args: dict[str, Any] = {"id": zone_id, "name": name, "active": active}
        for key, box, circle in (
            ("add", add_box, add_circle),
            ("remove", remove_box, remove_circle),
        ):
            if box is not None and circle is not None:
                raise ValueError(f"give {key}_box or {key}_circle, not both")
            if box is not None:
                if len(box) != 4:
                    raise ValueError(f"{key}_box must be [x1, y1, x2, y2]")
                args[key] = {"x1": box[0], "y1": box[1], "x2": box[2], "y2": box[3]}
            elif circle is not None:
                if len(circle) != 3:
                    raise ValueError(f"{key}_circle must be [center_x, center_y, radius]")
                args[key] = {"x": circle[0], "y": circle[1], "radius": circle[2]}
        args.update(
            _settings(
                check_occupants=check_occupants,
                keep_filled=keep_filled,
                pick_trees=pick_trees,
                pick_shrubs=pick_shrubs,
                gather_fallen=gather_fallen,
                shoot_from=shoot_from,
                allow_pets=allow_pets,
                allow_citizens=allow_citizens,
            )
        )
        return call(bridge, "zones.edit", args)

    @mcp.tool(name="assign_zone", annotations=WRITE_SAFE)
    def assign_zone(zone_id: int, unit_id: int) -> dict[str, Any]:
        """Assign a unit to a zone. Needs `zones_write`.

        A bedroom, office, dining hall, or tomb takes one citizen as owner (a previous
        owner is replaced); a pen takes a tame animal; a pit or pond takes any unit that
        is not a citizen or a pet (the bridge never pits dwarves), moving it from any zone
        it was assigned to before. Other zone types take no unit; squads for barracks and
        archery ranges wait for the military phase. Unit ids come from the unit lists.
        """
        return call(bridge, "zones.assign", {"id": zone_id, "unit_id": unit_id})

    @mcp.tool(name="unassign_zone", annotations=WRITE_SAFE)
    def unassign_zone(zone_id: int, unit_id: int | None = None) -> dict[str, Any]:
        """Remove a zone's owner (bedroom, office, dining hall, tomb; no `unit_id` needed)
        or take one animal (`unit_id`) out of a pen, pit, or pond. Needs `zones_write`.
        """
        return call(bridge, "zones.unassign", {"id": zone_id, "unit_id": unit_id})

    @mcp.tool(name="delete_zone", annotations=DELETE)
    def delete_zone(zone_id: int) -> dict[str, Any]:
        """Delete a zone outright. Needs `zones_write`. Buildings and items inside it stay;
        its owner and animals lose the assignment. Ids come from `list_zones`.
        """
        return call(bridge, "zones.delete", {"id": zone_id})
