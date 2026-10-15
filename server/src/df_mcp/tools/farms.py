from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE

SEASONS = ("spring", "summer", "autumn", "winter")


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_farms", annotations=READ_ONLY)
    def list_farms(limit: int = 25) -> dict[str, Any]:
        """List the fort's farm plots: id, position, bounds, tile count, whether built, the
        crop set for each season, fertilize-every-season, fertilization, the main soil
        material, and whether the plot is underground. Place a new one with
        `place_furniture(type="farm_plot", ...)` over a box of soil or mud floor; set its
        crops with `set_farm_crops` once `built` is true.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "farms.list", {"limit": limit})

    @mcp.tool(name="get_farm", annotations=READ_ONLY)
    def get_farm(farm_id: int, limit: int = 25) -> dict[str, Any]:
        """Read one farm plot: its crops per season, fertilization, and a `soil` report
        (materials by tile count, mud tiles, above or below ground, cavern tiles, biome,
        and a yield note: underground soil outside a cavern yields less), plus `plantable`,
        the crops the plot could grow in each season with the seeds in stock for each.

        The plantable list follows DFHack autofarm's rule (seed-bearing plant, season flags,
        biome or cavern flag), which approximates the game's own; a crop with 0 seeds needs
        seeds before it grows. `limit` caps the plantable rows per season.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "farms.get", {"id": farm_id, "limit": limit})

    @mcp.tool(name="set_farm_crops", annotations=WRITE_SAFE)
    def set_farm_crops(
        farm_id: int,
        spring: str | None = None,
        summer: str | None = None,
        autumn: str | None = None,
        winter: str | None = None,
        fertilize: bool | None = None,
    ) -> dict[str, Any]:
        """Set what a farm plot grows each season and whether to fertilize every season.
        Needs `build_write`.

        Pass a plant name from `get_farm`'s plantable list for any season to change
        ("plump helmet", "pig tail"), or "none" to leave that season fallow; seasons you
        leave out are unchanged. A crop the plot cannot grow in that season is refused with
        the plantable list, and crops are refused until the plot is built (the game clears
        them when construction finishes); `fertilize` may be set at any time. Returns the
        plot with `changed` and `warnings`.
        """
        crops = {
            season: value
            for season, value in (
                ("spring", spring),
                ("summer", summer),
                ("autumn", autumn),
                ("winter", winter),
            )
            if value is not None
        }
        if not crops and fertilize is None:
            raise ValueError("pass at least one season or fertilize")
        args: dict[str, Any] = {"id": farm_id}
        if crops:
            args["crops"] = crops
        if fertilize is not None:
            args["fertilize"] = fertilize
        return call(bridge, "farms.set_crops", args)
