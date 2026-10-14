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
        """Ask for a workshop or furnace to be removed. Needs `build_write`.

        A finished building gets a deconstruction job, so a dwarf takes it apart and its
        materials drop on the ground (`status: removal_queued`). An unfinished blueprint is
        cancelled immediately (`blueprint_cancelled`). A building claimed by a strange mood
        is refused. Ids come from `list_workshops`.
        """
        return call(bridge, "build.remove", {"id": building_id})

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
