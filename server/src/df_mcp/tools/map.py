from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY

MAX_AREA = 64
VIEWS = ("shape", "material", "designations")


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="get_map_bounds", annotations=READ_ONLY)
    def get_map_bounds() -> dict[str, Any]:
        """Get the map's valid coordinate ranges, its centre, the surface z there, and the
        wagon's z. Call this before any tile or area read. z counts upward.
        """
        return call(bridge, "map.bounds")

    @mcp.tool(name="get_wagon", annotations=READ_ONLY)
    def get_wagon() -> dict[str, Any]:
        """Locate the embark wagon. Its z is the surface level with the most open ground.
        If it has been deconstructed, returns the map centre at surface level instead.
        """
        return call(bridge, "map.wagon")

    @mcp.tool(name="get_tile", annotations=READ_ONLY)
    def get_tile(x: int, y: int, z: int, limit: int = 25) -> dict[str, Any]:
        """Read one map tile.

        Returns its shape (wall, floor, ramp, stair, open air), `basic_shape`, the stone or
        soil it is made of (`material_name` such as "granite" or "clay loam", and
        `material_class`: natural_stone, mineral_vein, soil, lava_stone, feature_stone, ice,
        construction, other), for walls `wall_kind` (natural, smoothed, engraved, constructed)
        and `construction` details, whether it is `walkable` (and its `walkable_group`: tiles
        sharing a group are connected by walking), `buildable` (flat walkable floor with no
        building, liquid, or tree), `outside`, liquid depth, `dig` and `smooth` designations,
        traffic, any `building` or `zones`, `plant`, items on the ground (capped at `limit`),
        and units standing there. A hidden tile returns only `hidden: true`, as the player
        cannot see it either.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "map.tile", {"x": x, "y": y, "z": z, "limit": limit})

    @mcp.tool(name="get_area_map", annotations=READ_ONLY)
    def get_area_map(
        x: int, y: int, z: int, width: int = 32, height: int = 32, view: str = "shape"
    ) -> dict[str, Any]:
        """Draw a rectangle of one z-level as text, one character per tile, up to 64 by 64.

        `rows` run north to south from (x, y); characters run west to east. `legend` explains
        the characters used. `view` "shape" (default): `#` wall, `.` floor, `^` ramp, `<` `>`
        `X` stairs, `B` building, `~` water, `%` magma, `T` tree, space for open air, `?`
        hidden. `view` "material": each wall gets a letter per material and kind, e.g. "a:
        granite wall", "b: clay loam wall", "c: granite wall (smoothed)". `view`
        "designations": existing orders drawn over the shape map, `d` mine, `u` up stair, `j`
        down stair, `i` up/down stair, `h` channel, `r` ramp, `s` smooth, `e` engrave.
        `walkable_groups` counts walkable tiles per connectivity group.
        """
        if not (1 <= width <= MAX_AREA and 1 <= height <= MAX_AREA):
            raise ValueError(f"width and height must be 1-{MAX_AREA}")
        if view not in VIEWS:
            raise ValueError(f"view must be one of {', '.join(VIEWS)}")
        return call(
            bridge,
            "map.area",
            {"x": x, "y": y, "z": z, "width": width, "height": height, "view": view},
        )

    @mcp.tool(name="find_exposed_walls", annotations=READ_ONLY)
    def find_exposed_walls(
        z: int,
        near_x: int | None = None,
        near_y: int | None = None,
        radius: int | None = None,
        material: str | None = None,
        limit: int = 25,
    ) -> dict[str, Any]:
        """Find walls that border walkable floor on one z-level, as straight segments.

        Use this to plan hallways and rooms without walking tiles: every returned segment is
        rock a dwarf can reach and dig into. Scans the whole level, or a square of `radius`
        around (`near_x`, `near_y`). Each segment has `x1, y1, x2, y2, z`, `length`,
        `material` (e.g. "granite"), `material_class`, `kind` (natural, smoothed, engraved,
        constructed), `open_sides` (which sides touch walkable floor), and `floor_group` (the
        walkable group of that floor). Longest first, `limit` segments (default 25), with
        `total_tiles`, `total_segments`, `truncated`, and `tiles_by_material`. `material`
        filters by substring. Hidden rock is never included.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        if (near_x is None) != (near_y is None):
            raise ValueError("near_x and near_y go together")
        return call(
            bridge,
            "map.exposed_walls",
            {
                "z": z,
                "near_x": near_x,
                "near_y": near_y,
                "radius": radius,
                "material": material,
                "limit": limit,
            },
        )

    @mcp.tool(name="find_build_space", annotations=READ_ONLY)
    def find_build_space(
        width: int = 3,
        height: int = 3,
        z: int | None = None,
        near_x: int | None = None,
        near_y: int | None = None,
        max_radius: int = 30,
    ) -> dict[str, Any]:
        """Find the nearest clear rectangle of walkable floor for a building.

        Searches outward in rings from (near_x, near_y), defaulting to the wagon or the map
        centre, on level `z` (default: the wagon's level or the surface). Every tile must be
        revealed, flat floor, walkable in one connected group, with no building, liquid, or
        tree. Returns the rectangle's `origin` (top-left) and `center`, or `found: false`.
        """
        if not (1 <= width <= 31 and 1 <= height <= 31):
            raise ValueError("width and height must be 1-31")
        return call(
            bridge,
            "map.find_space",
            {
                "width": width,
                "height": height,
                "z": z,
                "near_x": near_x,
                "near_y": near_y,
                "max_radius": max_radius,
            },
        )
