from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY

BAR_CATEGORIES = ("food", "drink", "seed", "meat", "fish", "plant", "other")


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="get_stock_bar", annotations=READ_ONLY)
    def get_stock_bar(category: str | None = None) -> dict[str, Any]:
        """Read the stock counts shown at the top of the screen: food, drink, seed, meat,
        fish, plant, other.

        Each entry has `display` (what the player sees, e.g. "~20" when the bookkeeper's
        records are imprecise), `estimated`, `shown`, and `value` (the true count, present in
        true mode). `bookkeeper` says whether one is assigned and at what precision. Pass
        `category` for a single entry.
        """
        if category is not None and category not in BAR_CATEGORIES:
            raise ValueError(f"category must be one of {', '.join(BAR_CATEGORIES)}")
        return call(bridge, "stocks.bar", {"category": category})

    @mcp.tool(name="list_stocks", annotations=READ_ONLY)
    def list_stocks(
        category: str | None = None, query: str | None = None, limit: int = 25
    ) -> dict[str, Any]:
        """List every stored item in the fort the way the Stocks screen does.

        `categories` is keyed by item type (weapon, helm, drink, seeds, bag, ...) with the
        game's caption as `name`, a `total` quantity, how much is `unavailable` (forbidden,
        dumped, built, or in use), and `rows` of `{item, material, count, quantity,
        unavailable}` sorted by quantity. Empty categories are omitted. `category` narrows to
        one type; `query` keeps only rows whose item or material contains the text; `limit`
        caps rows per category and `truncated` lists the categories that hit it.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "stocks.list", {"category": category, "query": query, "limit": limit})

    @mcp.tool(name="find_items", annotations=READ_ONLY)
    def find_items(query: str, limit: int = 25) -> dict[str, Any]:
        """Search every stored item by name or material and get matching rows across all
        categories, highest quantity first.
        """
        if not query or not query.strip():
            raise ValueError("query must be a non-empty string")
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "stocks.find", {"query": query, "limit": limit})

    @mcp.tool(name="get_fort_status", annotations=READ_ONLY)
    def get_fort_status() -> dict[str, Any]:
        """Read the fort's overall status: site and civilization names, rank (outpost to
        metropolis) with the thresholds for the next rank, progress ratings, the wealth
        breakdown (created, imported, exported, ...), population and animal counts, and
        tallies such as artifacts, deaths, invaders repelled, and discovered features.
        """
        return call(bridge, "stocks.status")

    @mcp.tool(name="list_artifacts", annotations=READ_ONLY)
    def list_artifacts() -> dict[str, Any]:
        """List the world's artifacts known to this fort with their item, material, holder,
        building, and position when on the map.
        """
        return call(bridge, "stocks.artifacts")
