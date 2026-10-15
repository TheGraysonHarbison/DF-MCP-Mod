from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE

TYPES = (
    "door",
    "floodgate",
    "hatch",
    "wall_grate",
    "floor_grate",
    "vertical_bars",
    "floor_bars",
    "glass_window",
    "gem_window",
    "bed",
    "table",
    "chair",
    "cabinet",
    "chest",
    "armor_stand",
    "weapon_rack",
    "statue",
    "slab",
    "coffin",
    "cage",
    "restraint",
    "well",
    "archery_target",
    "traction_bench",
    "nest_box",
    "hive",
    "bookcase",
    "display_case",
    "offering_place",
    "instrument",
    "animal_trap",
    "farm_plot",
)

DOC = """`type` is one of: door, floodgate, hatch, wall_grate, floor_grate, vertical_bars,
        floor_bars, glass_window, gem_window, bed, table, chair, cabinet, chest, armor_stand,
        weapon_rack, statue, slab, coffin, cage, restraint, well, archery_target,
        traction_bench, nest_box, hive, bookcase, display_case, offering_place, instrument,
        animal_trap, farm_plot. Apart from farm_plot, each consumes one finished item of that
        kind made beforehand in a workshop; when none is in stock the call returns
        `no_materials` with `make_with`, the work order job that makes it (queue it with
        `create_work_order`). Give one tile
        (x, y, z) or a box on one level (x, y, z, x2, y2) to place one per valid tile, at
        most `limit` (default 25). `material` restricts the item ("any wood", "plum wood",
        "sandstone"). Rules: furniture needs a floor; beds an indoor floor; a door a wall or
        fortification cardinally beside it (planned walls do not count until built), with a
        warning when it is not between two opposite walls; a well an open-air tile beside a
        floor; hatches, floor grates, and floor bars a floor, open air, ramp top, or stair.
        farm_plot is one building over the whole box (at most 31 by 31) and needs no item:
        tiles that are not soil, grass, or mud floors are cut out; `fertilize` sets
        fertilize-every-season; then set crops with `set_farm_crops`."""


def _args(
    type: str,
    x: int,
    y: int,
    z: int,
    x2: int | None,
    y2: int | None,
    material: str | None,
    limit: int,
    fertilize: bool | None = None,
) -> dict[str, Any]:
    key = type.strip().lower().replace(" ", "_").replace("-", "_")
    if limit < 1:
        raise ValueError("limit must be at least 1")
    if (x2 is None) != (y2 is None):
        raise ValueError("a box needs both x2 and y2")
    args: dict[str, Any] = {"type": key, "material": material, "limit": limit}
    if fertilize is not None:
        args["fertilize"] = fertilize
    if x2 is None:
        args.update({"x": x, "y": y, "z": z})
    else:
        args.update({"x1": x, "y1": y, "z1": z, "x2": x2, "y2": y2, "z2": z})
    return args


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="plan_furniture", annotations=READ_ONLY)
    def plan_furniture(
        type: str,
        x: int,
        y: int,
        z: int,
        x2: int | None = None,
        y2: int | None = None,
        material: str | None = None,
        limit: int = 25,
        fertilize: bool | None = None,
    ) -> dict[str, Any]:
        (
            """Preview a furniture or door placement without changing anything: which tiles
        qualify, what item it needs and how many are in stock. Needs only `workshops`.

        """
            + DOC
        )
        return call(
            bridge, "build.plan_furniture", _args(type, x, y, z, x2, y2, material, limit, fertilize)
        )

    @mcp.tool(name="place_furniture", annotations=WRITE_SAFE)
    def place_furniture(
        type: str,
        x: int,
        y: int,
        z: int,
        x2: int | None = None,
        y2: int | None = None,
        material: str | None = None,
        limit: int = 25,
        fertilize: bool | None = None,
    ) -> dict[str, Any]:
        (
            """Place furniture, doors, hatches, grates, bars, or windows for a dwarf to install.
        Needs `build_write`. Run `plan_furniture` first. Returns `status` (`placed`,
        `no_materials` with `make_with`, `nothing_to_place`), `placed`, the skipped tiles
        with reasons, `requirements` with stock counts, `warnings`, and the building ids.

        """
            + DOC
        )
        return call(
            bridge, "build.place", _args(type, x, y, z, x2, y2, material, limit, fertilize)
        )
