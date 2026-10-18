from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call, tool_doc
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
    "lever",
    "pressure_plate",
    "cage_trap",
    "stone_fall_trap",
    "weapon_trap",
    "upright_spike",
    "catapult",
    "ballista",
    "trade_depot",
)
PLATE_TRIGGERS = ("units", "water", "magma", "track")

DOC = """`type` is one of: door, floodgate, hatch, wall_grate, floor_grate, vertical_bars,
        floor_bars, glass_window, gem_window, bed, table, chair, cabinet, chest, armor_stand,
        weapon_rack, statue, slab, coffin, cage, restraint, well, archery_target,
        traction_bench, nest_box, hive, bookcase, display_case, offering_place, instrument,
        animal_trap, farm_plot, lever, pressure_plate, cage_trap, stone_fall_trap, weapon_trap,
        upright_spike, catapult, ballista, trade_depot. Apart from farm_plot, each consumes one
        finished item of that kind made beforehand in a workshop; when none is in stock the
        call returns `no_materials` with `make_with`, the work order job that makes it (queue
        it with `create_work_order`). Give one tile
        (x, y, z) or a box on one level (x, y, z, x2, y2), any size up to the map's bounds
        and clipped at its edge (`box.clipped`), to place one per valid tile, at most `limit`
        (default 25; `over_limit` counts the valid tiles left over and `truncated` says so).
        `material` restricts the item ("any wood", "plum wood",
        "sandstone"). Rules: furniture needs a floor; beds an indoor floor; a door a wall or
        fortification cardinally beside it (planned walls do not count until built), with a
        warning when it is not between two opposite walls; a well an open-air tile beside a
        floor; hatches, floor grates, and floor bars a floor, open air, ramp top, or stair.
        farm_plot is one building over the whole box and needs no item; the game builds a
        plot at most 31 by 31 (its own limit, which DFHack's buildingplan mirrors), so place
        several for a bigger field:
        tiles that are not soil, grass, or mud floors are cut out; `fertilize` sets
        fertilize-every-season; then set crops with `set_farm_crops`. Traps take a mechanism
        (lever, pressure plate, cage trap, stone-fall trap; the weapon trap also one weapon);
        an upright spike takes a spike trap component; catapult and ballista take three of their
        parts and are 3 by 3; the trade depot takes three building materials and is 5 by 5.
        The 3 by 3 and 5 by 5 ones take one position, their top-left corner. A pressure plate
        takes `plate_triggers` (units, water, magma, track), `plate_citizens`, `plate_resets`,
        and `plate_min`/`plate_max` (water or magma depth 1-7). Levers are not linked to
        anything yet (open issue)."""


PLAN_FURNITURE_DOC = tool_doc(
    """Preview a furniture or door placement without changing anything: which tiles
        qualify, what item it needs and how many are in stock. Needs only `workshops`.""",
    DOC,
)

PLACE_FURNITURE_DOC = tool_doc(
    """Place furniture, doors, hatches, grates, bars, or windows for a dwarf to install.
        Needs `build_write`. Run `plan_furniture` first. Returns `status` (`placed`,
        `no_materials` with `make_with`, `nothing_to_place`), `placed`, the skipped tiles
        with reasons, `requirements` with stock counts, `warnings`, and the building ids.""",
    DOC,
)


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
    plate_triggers: list[str] | None = None,
    plate_citizens: bool | None = None,
    plate_resets: bool | None = None,
    plate_min: int | None = None,
    plate_max: int | None = None,
) -> dict[str, Any]:
    key = type.strip().lower().replace(" ", "_").replace("-", "_")
    if limit < 1:
        raise ValueError("limit must be at least 1")
    if (x2 is None) != (y2 is None):
        raise ValueError("a box needs both x2 and y2")
    args: dict[str, Any] = {"type": key, "material": material, "limit": limit}
    if fertilize is not None:
        args["fertilize"] = fertilize
    plate_values = (plate_triggers, plate_citizens, plate_resets, plate_min, plate_max)
    if any(v is not None for v in plate_values):
        if key != "pressure_plate":
            raise ValueError("plate settings only apply to a pressure_plate")
        if plate_triggers is not None and any(t not in PLATE_TRIGGERS for t in plate_triggers):
            raise ValueError(f"plate_triggers entries must be {', '.join(PLATE_TRIGGERS)}")
        plate: dict[str, Any] = {}
        if plate_triggers is not None:
            plate["triggers"] = plate_triggers
        if plate_citizens is not None:
            plate["citizens"] = plate_citizens
        if plate_resets is not None:
            plate["resets"] = plate_resets
        if plate_min is not None:
            plate["water_min"] = plate_min
            plate["magma_min"] = plate_min
        if plate_max is not None:
            plate["water_max"] = plate_max
            plate["magma_max"] = plate_max
        args["plate"] = plate
    if x2 is None:
        args.update({"x": x, "y": y, "z": z})
    else:
        args.update({"x1": x, "y1": y, "z1": z, "x2": x2, "y2": y2, "z2": z})
    return args


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="plan_furniture", annotations=READ_ONLY, description=PLAN_FURNITURE_DOC)
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
        plate_triggers: list[str] | None = None,
        plate_citizens: bool | None = None,
        plate_resets: bool | None = None,
        plate_min: int | None = None,
        plate_max: int | None = None,
    ) -> dict[str, Any]:
        return call(
            bridge,
            "build.plan_furniture",
            _args(
                type, x, y, z, x2, y2, material, limit, fertilize,
                plate_triggers, plate_citizens, plate_resets, plate_min, plate_max,
            ),
        )

    @mcp.tool(name="place_furniture", annotations=WRITE_SAFE, description=PLACE_FURNITURE_DOC)
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
        plate_triggers: list[str] | None = None,
        plate_citizens: bool | None = None,
        plate_resets: bool | None = None,
        plate_min: int | None = None,
        plate_max: int | None = None,
    ) -> dict[str, Any]:
        return call(
            bridge,
            "build.place",
            _args(
                type, x, y, z, x2, y2, material, limit, fertilize,
                plate_triggers, plate_citizens, plate_resets, plate_min, plate_max,
            ),
        )
