from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_diplomats", annotations=READ_ONLY)
    def list_diplomats(limit: int = 25) -> dict[str, Any]:
        """Diplomats and liaisons on the map with their civilization and job, who is waiting
        to meet, the site leader (who holds the meeting) and what they are doing, the
        recorded meetings, the game's diplomacy screen state, and the standing trade
        agreements: what the fort asked the caravan to bring (`imports.requested`, with the
        price mark-up) and what the caravan pays more for (`exports.price_changes`).
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "trade.diplomats", {"limit": limit})

    @mcp.tool(name="get_trade_request_options", annotations=READ_ONLY)
    def get_trade_request_options(
        category: str | None = None, civ_id: int | None = None, limit: int = 25
    ) -> dict[str, Any]:
        """The goods the fort can ask the liaison's civilization to bring next year, by
        category (MetalBars, Weapon, Armor, Drinks, Plants, Pets, Leather, ...), each with
        its current priority 0 to 4. Available once the liaison meeting has reached its
        Requests step (the request list is created then).
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        args: dict[str, Any] = {"limit": limit}
        if category is not None:
            args["category"] = category
        if civ_id is not None:
            args["civ_id"] = civ_id
        return call(bridge, "trade.request_options", args)

    @mcp.tool(name="set_trade_requests", annotations=WRITE_SAFE)
    def set_trade_requests(
        requests: list[dict[str, Any]], civ_id: int | None = None
    ) -> dict[str, Any]:
        """Set next year's import requests on the liaison meeting: a list of
        `{"category": "MetalBars", "item": "steel", "priority": 4}` entries, where `item`
        is a name substring, an index from `get_trade_request_options`, or "all" for the
        whole category, and `priority` is 0 (none) to 4 (strongest; the caravan charges
        more for requested goods). Needs `trade_write` and a meeting that has reached its
        Requests step; the player then finishes the meeting with Done.
        """
        if not requests:
            raise ValueError("requests must not be empty")
        for r in requests:
            if "category" not in r or "priority" not in r:
                raise ValueError("each request needs category and priority")
        args: dict[str, Any] = {"requests": requests}
        if civ_id is not None:
            args["civ_id"] = civ_id
        return call(bridge, "trade.set_requests", args)
