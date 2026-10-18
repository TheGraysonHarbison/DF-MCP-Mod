from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY

KINDS = ("tree", "shrub", "sapling")


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_plants", annotations=READ_ONLY)
    def list_plants(
        x1: int | None = None,
        y1: int | None = None,
        z1: int | None = None,
        x2: int | None = None,
        y2: int | None = None,
        z2: int | None = None,
        center_x: int | None = None,
        center_y: int | None = None,
        center_z: int | None = None,
        radius: int | None = None,
        kind: str | None = None,
        query: str | None = None,
        marked_only: bool = False,
        limit: int = 25,
    ) -> dict[str, Any]:
        """List the trees, shrubs, and saplings whose base tile is in a box (two corners,
        any levels, any size up to the whole map) or a filled circle on one level
        (center_x, center_y, center_z, radius 1 or more); shapes past the map edge are
        clipped (`box.clipped`).

        Each row has `pos` (the base tile), `kind` (tree, shrub, sapling), `species`,
        `dead`, `marked` (already ordered for felling or gathering), and for trees `size`
        and `designation_tile` (the trunk tile the order goes on). `counts` and `species`
        summarise everything that matched. Then order work with `designate_dig` kind "chop"
        (trees) or "gather" (shrubs); saplings must grow first. `kind` and `query` (species
        substring) filter; `marked_only` keeps ordered plants.
        """
        if kind is not None and kind not in KINDS:
            raise ValueError(f"kind must be one of {', '.join(KINDS)}")
        if limit < 1:
            raise ValueError("limit must be at least 1")
        circle = [center_x, center_y, center_z, radius]
        box = [x1, y1, z1, x2, y2, z2]
        args: dict[str, Any] = {
            "kind": kind,
            "query": query,
            "marked_only": marked_only,
            "limit": limit,
        }
        if all(v is not None for v in circle):
            if any(v is not None for v in box):
                raise ValueError("give either a box (x1..z2) or a circle, not both")
            args["circle"] = {"x": center_x, "y": center_y, "z": center_z, "radius": radius}
        elif any(v is not None for v in circle):
            raise ValueError("a circle needs center_x, center_y, center_z, and radius together")
        elif any(v is None for v in box):
            raise ValueError("give a box (x1, y1, z1, x2, y2, z2) or a circle")
        else:
            args.update({"x1": x1, "y1": y1, "z1": z1, "x2": x2, "y2": y2, "z2": z2})
        return call(bridge, "map.plants", args)
