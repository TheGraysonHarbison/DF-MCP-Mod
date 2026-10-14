from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE
from df_mcp.tools.orders import DELETE

FORMS = ("blocks", "boulders", "logs", "bars")


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="place_workshop", annotations=WRITE_SAFE)
    def place_workshop(
        type: str, x: int, y: int, z: int, material: str | None = None
    ) -> dict[str, Any]:
        """Place a workshop or furnace blueprint for the dwarves to build. Needs `build_write`.

        `type` is a workshop or furnace name such as Masons, Carpenters, Kitchen, Still,
        Smelter, or a custom building code. (x, y, z) is the top-left corner of the
        footprint; use `find_build_space` and pass its `origin`. Without `material` the
        game's default filter applies and dwarves fetch the closest suitable material.
        `material` restricts it in plain words: a class ("any stone", "wood", "metal"), a
        specific material ("sandstone", "silver"), a form ("blocks", "boulders", "logs",
        "bars"), or both ("sandstone blocks"); tokens such as INORGANIC:GRANITE still work.
        Check `list_building_materials` first when it matters. Returns `status`: `placed`
        with the new building, `invalid_space` with the blocking tile, or `no_materials`
        with what is missing. Only a blueprint is placed; nothing is built instantly.
        """
        if not type or not type.strip():
            raise ValueError("type must be a workshop or furnace name")
        return call(
            bridge,
            "build.workshop",
            {"type": type.strip(), "x": x, "y": y, "z": z, "material": material},
        )

    @mcp.tool(name="remove_building", annotations=DELETE)
    def remove_building(building_id: int) -> dict[str, Any]:
        """Ask for a building to be removed: a workshop, furnace, furniture, door, bridge,
        road, or an unbuilt construction. Needs `build_write`.

        A finished building gets a deconstruction job, so a dwarf takes it apart and its
        items drop on the ground (`status: removal_queued`). An unfinished blueprint is
        cancelled immediately (`blueprint_cancelled`). Stockpiles and zones have their own
        delete tools; a building claimed by a strange mood is refused. Finished walls,
        floors, and stairs are map tiles, not buildings: use `remove_constructions`. Ids
        come from `list_buildings`.
        """
        return call(bridge, "build.remove", {"id": building_id})

    @mcp.tool(name="list_buildings", annotations=READ_ONLY)
    def list_buildings(
        kind: str | None = None,
        planned_only: bool = False,
        z: int | None = None,
        x1: int | None = None,
        y1: int | None = None,
        z1: int | None = None,
        x2: int | None = None,
        y2: int | None = None,
        z2: int | None = None,
        limit: int = 25,
        offset: int = 0,
    ) -> dict[str, Any]:
        """List every building in the fort except stockpiles and zones: workshops,
        furnaces, furniture, doors, bridges, roads, and unbuilt constructions.

        Each row has `id`, `kind` (plain name such as door, bed, workshop, construction),
        `type` (the workshop, furnace, or construction subtype), `name`, `pos`, `bounds`,
        `built`, `planned` (nothing built yet), `suspended`, `marked_for_removal`,
        `strange_mood`, and for unbuilt ones `job` (type, worker, suspended) and `materials`
        (items attached vs still needed). Filter with `kind` (a plain name, a building
        type, or a subtype such as Masons or Wall), `planned_only`, `z`, or a box. Finished
        walls and floors are map tiles, not buildings; see `get_tile`.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        box = [x1, y1, z1, x2, y2, z2]
        if any(v is not None for v in box) and any(v is None for v in box):
            raise ValueError("a box needs all of x1, y1, z1, x2, y2, z2")
        args: dict[str, Any] = {
            "kind": kind.strip().lower() if kind else None,
            "planned_only": planned_only,
            "z": z,
            "limit": limit,
            "offset": offset,
        }
        if all(v is not None for v in box):
            args.update({"x1": x1, "y1": y1, "z1": z1, "x2": x2, "y2": y2, "z2": z2})
        return call(bridge, "build.list", args)

    @mcp.tool(name="suspend_building", annotations=WRITE_SAFE)
    def suspend_building(building_id: int, suspended: bool = True) -> dict[str, Any]:
        """Suspend (`suspended=true`) or resume (`false`) the construction job of an
        unbuilt building, so dwarves leave it alone or pick it up again. Needs
        `build_write`. A finished building has no job and is refused.
        """
        return call(bridge, "build.suspend", {"id": building_id, "suspended": bool(suspended)})

    @mcp.tool(name="remove_constructions", annotations=DELETE)
    def remove_constructions(
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
        dry_run: bool = True,
    ) -> dict[str, Any]:
        """Remove constructions (walls, floors, ramps, stairs, fortifications) in a box or a
        filled circle. Needs `build_write`. Defaults to `dry_run=true`, which only reports;
        pass `dry_run=false` to act.

        Planned constructions are cancelled at once; finished ones are designated for
        removal and a miner takes them apart, leaving the material on the ground. Natural
        tiles are skipped. Returns `cancelled`, `designated`, `already_designated`,
        `skipped`, and the first 25 tiles with their action.
        """
        circle = [center_x, center_y, center_z, radius]
        box = [x1, y1, z1, x2, y2, z2]
        args: dict[str, Any] = {"dry_run": dry_run}
        if all(v is not None for v in circle):
            if any(v is not None for v in box):
                raise ValueError("give either a box or a circle, not both")
            args["circle"] = {"x": center_x, "y": center_y, "z": center_z, "radius": radius}
        elif any(v is not None for v in circle):
            raise ValueError("a circle needs center_x, center_y, center_z, and radius")
        elif any(v is None for v in box):
            raise ValueError("give a box (x1, y1, z1, x2, y2, z2) or a circle")
        else:
            args.update({"x1": x1, "y1": y1, "z1": z1, "x2": x2, "y2": y2, "z2": z2})
        return call(bridge, "build.remove_constructions", args)

    @mcp.tool(name="list_building_materials", annotations=READ_ONLY)
    def list_building_materials(
        form: str | None = None,
        material: str | None = None,
        fire_safe: bool = False,
        magma_safe: bool = False,
        limit: int = 25,
    ) -> dict[str, Any]:
        """List the building materials the fort can use right now, grouped by material and
        form, most plentiful first.

        Each row has `material`, `form` (blocks, boulders, logs, bars), `class` (stone,
        wood, metal, gem, glass), `count`, `fire_safe`, `magma_safe`, and for boulders
        `economic` (ore or flux the game keeps for industry unless the player allows it).
        `by_class` and `by_form` total everything. Filter with `form`, `material` (any word
        `place_workshop` accepts, such as "any stone" or "sandstone"), `fire_safe`, or
        `magma_safe` (needed for furnaces and magma workshops). Counts exclude forbidden,
        dumped, in-use, built, and trader items. Use the row's `material` word, with or
        without the form, as `material` in a placement call.
        """
        if form is not None and form.strip().lower() not in FORMS:
            raise ValueError(f"form must be one of {', '.join(FORMS)}")
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(
            bridge,
            "build.materials",
            {
                "form": form.strip().lower() if form else None,
                "material": material,
                "fire_safe": fire_safe,
                "magma_safe": magma_safe,
                "limit": limit,
            },
        )
