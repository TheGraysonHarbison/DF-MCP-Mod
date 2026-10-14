from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE
from df_mcp.tools.orders import DELETE

CATEGORIES = (
    "animals",
    "food",
    "furniture",
    "corpses",
    "refuse",
    "stone",
    "ore",
    "ammo",
    "coins",
    "bars_blocks",
    "gems",
    "finished_goods",
    "leather",
    "cloth",
    "wood",
    "weapons",
    "armor",
    "sheet",
)


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_stockpiles", annotations=READ_ONLY)
    def list_stockpiles(
        category: str | None = None, limit: int = 25, offset: int = 0
    ) -> dict[str, Any]:
        """List the fort's stockpiles.

        Each row has the building `id` (use it with `get_stockpile`), `label` (its name or
        "Stockpile #n"), `bounds` and `pos`, `tiles`, the enabled `categories` (food, stone,
        wood, furniture, ...), and the item count. `category` keeps only piles that accept
        that category; `counts_by_category` always covers the map.
        """
        if category is not None and category not in CATEGORIES:
            raise ValueError(f"category must be one of {', '.join(CATEGORIES)}")
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(
            bridge, "stockpiles.list", {"category": category, "limit": limit, "offset": offset}
        )

    @mcp.tool(name="get_stockpile", annotations=READ_ONLY)
    def get_stockpile(building_id: int, limit: int = 25) -> dict[str, Any]:
        """Inspect one stockpile by building id.

        Returns the list row plus `settings` (enabled categories, organic and inorganic
        allowances, container limits, and per-category `details` such as how many sub-entries
        are enabled), `links` (give-to and take-from piles and workshops), and `contents`
        (items capped at `limit`, with `by_type` totals for everything).
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "stockpiles.get", {"id": building_id, "limit": limit})

    @mcp.tool(name="list_stockpile_presets", annotations=READ_ONLY)
    def list_stockpile_presets(query: str | None = None, limit: int = 25) -> dict[str, Any]:
        """List DFHack's bundled stockpile presets (names like library/cat_stone), for use
        with `create_stockpile` or `configure_stockpile`. `query` filters by substring.
        """
        return call(bridge, "stockpiles.presets", {"query": query, "limit": limit})

    @mcp.tool(name="create_stockpile", annotations=WRITE_SAFE)
    def create_stockpile(
        x1: int | None = None,
        y1: int | None = None,
        x2: int | None = None,
        y2: int | None = None,
        z: int | None = None,
        name: str | None = None,
        center_x: int | None = None,
        center_y: int | None = None,
        radius: int | None = None,
        categories: list[str] | None = None,
        preset: str | None = None,
        preset_mode: str = "set",
    ) -> dict[str, Any]:
        """Paint a stockpile: a rectangle between two corners, or a filled circle from
        `center_x`, `center_y`, `z`, and `radius` (1 to 15). Needs `stockpiles_write`.

        Every tile must be revealed, flat floor, with no building, liquid, or tree. Then the
        pile is configured: `categories` enables whole categories with all their options
        (stone, wood, food, furniture, ...), `preset` applies a DFHack preset from
        `list_stockpile_presets` (`preset_mode` set replaces, enable adds, disable removes),
        and `name` labels it. Returns `status` placed, placed_unconfigured, or invalid_space
        with the blocking tile.
        """
        if preset_mode not in ("set", "enable", "disable"):
            raise ValueError("preset_mode must be set, enable, or disable")
        if z is None:
            raise ValueError("z is required")
        circle: dict[str, int] | None = None
        if radius is not None or center_x is not None or center_y is not None:
            if radius is None or center_x is None or center_y is None:
                raise ValueError("a circle needs center_x, center_y, and radius together")
            if any(v is not None for v in (x1, y1, x2, y2)):
                raise ValueError("give either corners (x1, y1, x2, y2) or a circle, not both")
            circle = {"x": center_x, "y": center_y, "z": z, "radius": radius}
        elif any(v is None for v in (x1, y1, x2, y2)):
            raise ValueError(
                "give corners (x1, y1, x2, y2, z) or a circle (center_x, center_y, z, radius)"
            )
        if categories is not None:
            for c in categories:
                if c not in CATEGORIES:
                    raise ValueError(f"category must be one of {', '.join(CATEGORIES)}")
        return call(
            bridge,
            "stockpiles.create",
            {
                "x1": x1,
                "y1": y1,
                "x2": x2,
                "y2": y2,
                "z": z,
                "name": name,
                "categories": categories,
                "preset": preset,
                "preset_mode": preset_mode,
                "circle": circle,
            },
        )

    @mcp.tool(name="configure_stockpile", annotations=WRITE_SAFE)
    def configure_stockpile(
        building_id: int,
        enable: list[str] | None = None,
        disable: list[str] | None = None,
        preset: str | None = None,
        preset_mode: str = "set",
        name: str | None = None,
        max_barrels: int | None = None,
        max_bins: int | None = None,
        max_wheelbarrows: int | None = None,
    ) -> dict[str, Any]:
        """Change what a stockpile accepts. Needs `stockpiles_write`.

        `enable` and `disable` take category names and switch every option under them;
        `preset` applies a DFHack preset (`preset_mode` set, enable, or disable); container
        limits and `name` can be set too. Returns the updated settings.
        """
        if preset_mode not in ("set", "enable", "disable"):
            raise ValueError("preset_mode must be set, enable, or disable")
        for group in (enable or [], disable or []):
            for c in group:
                if c not in CATEGORIES:
                    raise ValueError(f"category must be one of {', '.join(CATEGORIES)}")
        if not any(
            v is not None
            for v in (enable, disable, preset, name, max_barrels, max_bins, max_wheelbarrows)
        ):
            raise ValueError("pass at least one change")
        return call(
            bridge,
            "stockpiles.configure",
            {
                "id": building_id,
                "enable": enable,
                "disable": disable,
                "preset": preset,
                "preset_mode": preset_mode,
                "name": name,
                "max_barrels": max_barrels,
                "max_bins": max_bins,
                "max_wheelbarrows": max_wheelbarrows,
            },
        )

    @mcp.tool(name="rename_stockpile", annotations=WRITE_SAFE)
    def rename_stockpile(building_id: int, name: str) -> dict[str, Any]:
        """Rename a stockpile (empty string clears the name). Needs `stockpiles_write`."""
        if len(name) > 64:
            raise ValueError("name is limited to 64 characters")
        return call(bridge, "stockpiles.rename", {"id": building_id, "name": name})

    @mcp.tool(name="delete_stockpile", annotations=DELETE)
    def delete_stockpile(building_id: int) -> dict[str, Any]:
        """Remove a stockpile. Items stay where they lie. Needs `stockpiles_write`."""
        return call(bridge, "stockpiles.delete", {"id": building_id})
