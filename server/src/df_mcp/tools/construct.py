from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call, tool_doc
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE

KINDS = (
    "wall",
    "floor",
    "ramp",
    "stairs",
    "fortification",
    "bridge",
    "paved_road",
    "dirt_road",
    "support",
)
TILE_KINDS = ("wall", "floor", "ramp", "stairs", "fortification")
SHAPES = ("box", "circle", "line")
DIRECTIONS = ("retracting", "raise_north", "raise_south", "raise_east", "raise_west")

SHAPE_DOC = """`kind`: "wall", "floor", "ramp", "stairs", "fortification" place one construction
        per tile; "bridge", "paved_road", "dirt_road", "support" place one building.
        `shape` "box" (default) takes two corners (x1, y1, z1, x2, y2, z2) in any order, any
        size up to the whole map (clipped at its edge, `box.clipped`; big boxes pause the
        game longer); a z range stacks the shape on every level. "circle" takes center_x,
        center_y, center_z, radius (1 or more). "line" takes the
        corners as endpoints on one level and draws a straight wall or floor between them
        at any angle; `thick` (default true) fills the diagonal steps so dwarves cannot
        slip through. `hollow` keeps only the perimeter of a box or the ring of a circle.
        "stairs" needs a box of at least two levels: up stair at the bottom, down stair on
        top, up/down between (up/down on an existing stair). A bridge needs `direction`
        ("retracting" or "raise_north"/"raise_south"/"raise_east"/"raise_west", the side
        that becomes a wall when raised), one level, at most 31 by 31 (the game's own limit
        for one bridge or road, which DFHack's buildingplan mirrors; place several side by
        side for more); roads cut out bad
        tiles; a support is one tile. `material` is a plain word as `place_workshop` takes
        ("any stone", "logs", "plum wood", "sandstone blocks"); leave it out for the
        closest material. A construction goes on open air, floor, boulders, pebbles, a
        ramp, or a ramp top; not on hidden tiles, buildings, deep water, magma, or a
        constructed tile of the same shape. Tiles with nothing beside or below them are
        counted as `unsupported` and still placed. If the materials in stock are fewer
        than the tiles, nothing is placed (`status: no_materials`)."""


def _args(
    kind: str,
    shape: str,
    x1: int | None,
    y1: int | None,
    z1: int | None,
    x2: int | None,
    y2: int | None,
    z2: int | None,
    center_x: int | None,
    center_y: int | None,
    center_z: int | None,
    radius: int | None,
    hollow: bool,
    thick: bool,
    material: str | None,
    direction: str | None,
) -> dict[str, Any]:
    if kind not in KINDS:
        raise ValueError(f"kind must be one of {', '.join(KINDS)}")
    if shape not in SHAPES:
        raise ValueError(f"shape must be one of {', '.join(SHAPES)}")
    if kind not in TILE_KINDS and shape != "box":
        raise ValueError(f"{kind} takes a box")
    if direction is not None and direction not in DIRECTIONS:
        raise ValueError(f"direction must be one of {', '.join(DIRECTIONS)}")
    if kind == "bridge" and direction is None:
        raise ValueError("a bridge needs direction")
    args: dict[str, Any] = {
        "kind": kind,
        "hollow": hollow,
        "thick": thick,
        "material": material,
        "direction": direction,
    }
    box = [x1, y1, z1, x2, y2, z2]
    circle = [center_x, center_y, center_z, radius]
    if shape == "circle":
        if any(v is None for v in circle):
            raise ValueError("a circle needs center_x, center_y, center_z, and radius")
        args["circle"] = {"x": center_x, "y": center_y, "z": center_z, "radius": radius}
        return args
    if any(v is not None for v in circle):
        raise ValueError("center_x, center_y, center_z, radius are for shape circle")
    if shape == "line":
        if any(v is None for v in (x1, y1, z1, x2, y2)):
            raise ValueError("a line needs x1, y1, z1, x2, y2 (z2 optional, equal to z1)")
        if z2 is not None and z2 != z1:
            raise ValueError("a line stays on one level: z2 must equal z1")
        args["line"] = {"x1": x1, "y1": y1, "x2": x2, "y2": y2, "z": z1}
        return args
    if any(v is None for v in box):
        raise ValueError("a box needs x1, y1, z1, x2, y2, z2")
    args.update({"x1": x1, "y1": y1, "z1": z1, "x2": x2, "y2": y2, "z2": z2})
    return args



PLAN_CONSTRUCTION_DOC = tool_doc(
    """Preview a construction order without changing anything: what
        `place_construction` would place, which tiles it would skip and why, how many
        materials it needs and how many are in stock. Needs only `workshops`.""",
    SHAPE_DOC,
)


PLACE_CONSTRUCTION_DOC = tool_doc(
    """Place construction blueprints for the dwarves to build: walls, floors, ramps,
        stairwells, fortifications, bridges, roads, supports. Needs `build_write`. Run
        `plan_construction` with the same arguments first. Returns `status` (`placed`,
        `no_materials`, `nothing_to_place`, `invalid_space`), `placed`, the skipped counts
        with the first 25 reasons, `unsupported`, `materials {needed, available}`, and the
        first 25 building ids. Only blueprints are placed; dwarves build them in time.""",
    SHAPE_DOC,
)

def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="plan_construction", annotations=READ_ONLY, description=PLAN_CONSTRUCTION_DOC)
    def plan_construction(
        kind: str,
        shape: str = "box",
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
        hollow: bool = False,
        thick: bool = True,
        material: str | None = None,
        direction: str | None = None,
    ) -> dict[str, Any]:
        return call(
            bridge,
            "build.plan_construction",
            _args(
                kind,
                shape,
                x1,
                y1,
                z1,
                x2,
                y2,
                z2,
                center_x,
                center_y,
                center_z,
                radius,
                hollow,
                thick,
                material,
                direction,
            ),
        )

    @mcp.tool(name="place_construction", annotations=WRITE_SAFE, description=PLACE_CONSTRUCTION_DOC)
    def place_construction(
        kind: str,
        shape: str = "box",
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
        hollow: bool = False,
        thick: bool = True,
        material: str | None = None,
        direction: str | None = None,
    ) -> dict[str, Any]:
        return call(
            bridge,
            "build.construct",
            _args(
                kind,
                shape,
                x1,
                y1,
                z1,
                x2,
                y2,
                z2,
                center_x,
                center_y,
                center_z,
                radius,
                hollow,
                thick,
                material,
                direction,
            ),
        )
