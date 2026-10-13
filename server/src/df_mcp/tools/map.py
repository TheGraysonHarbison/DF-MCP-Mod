from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY

MAX_AREA = 64


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

        Returns its shape (wall, floor, ramp, stair, open air), `basic_shape`, material class,
        whether it is `walkable` (and its `walkable_group`: tiles sharing a group are connected
        by walking), `buildable` (flat walkable floor with no building, liquid, or tree),
        `outside`, liquid depth, dig and traffic designations, any `building` or `zones`,
        `plant`, items on the ground (capped at `limit`), and units standing there. A hidden
        tile returns only `hidden: true`, as the player cannot see it either.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "map.tile", {"x": x, "y": y, "z": z, "limit": limit})

    @mcp.tool(name="get_area_map", annotations=READ_ONLY)
    def get_area_map(x: int, y: int, z: int, width: int = 32, height: int = 32) -> dict[str, Any]:
        """Draw a rectangle of one z-level as text, one character per tile, up to 64 by 64.

        `rows` run north to south from (x, y); characters run west to east. `legend` explains
        the characters used: `#` wall, `.` floor, `^` ramp, `<` `>` `X` stairs, `B` building,
        `~` water, `%` magma, `T` tree, space for open air, `?` hidden. `walkable_groups`
        counts walkable tiles per connectivity group.
        """
        if not (1 <= width <= MAX_AREA and 1 <= height <= MAX_AREA):
            raise ValueError(f"width and height must be 1-{MAX_AREA}")
        return call(bridge, "map.area", {"x": x, "y": y, "z": z, "width": width, "height": height})

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
