from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import WRITE_SAFE


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="place_workshop", annotations=WRITE_SAFE)
    def place_workshop(
        type: str, x: int, y: int, z: int, material: str | None = None
    ) -> dict[str, Any]:
        """Place a workshop or furnace blueprint for the dwarves to build. Needs `build_write`.

        `type` is a workshop or furnace name such as Masons, Carpenters, Kitchen, Still,
        Smelter, or a custom building code. (x, y, z) is the top-left corner of the
        footprint; use `find_build_space` and pass its `origin`. The game's default material
        filters are used, so dwarves fetch the closest suitable material; `material` (a token
        like INORGANIC:GRANITE) restricts it. Returns `status`: `placed` with the new
        building, `invalid_space` with the blocking tile, or `no_materials` with what is
        missing. Only a blueprint is placed; nothing is built instantly.
        """
        if not type or not type.strip():
            raise ValueError("type must be a workshop or furnace name")
        return call(
            bridge,
            "build.workshop",
            {"type": type.strip(), "x": x, "y": y, "z": z, "material": material},
        )
