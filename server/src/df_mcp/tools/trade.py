from __future__ import annotations

from typing import Any

from mcp.server import MCPServer
from mcp.types import ToolAnnotations

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE

CANCEL = ToolAnnotations(read_only_hint=False, destructive_hint=True, idempotent_hint=True)
# Trade, Offer, and Seize hand goods over for good; pressing twice is a second deal.
PRESS = ToolAnnotations(
    read_only_hint=False, destructive_hint=True, idempotent_hint=False, open_world_hint=False
)
PRESS_ACTIONS = ("trade", "offer", "seize", "accept_counter", "decline_counter", "close")


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_caravans", annotations=READ_ONLY)
    def list_caravans() -> dict[str, Any]:
        """List the caravans the fort knows about: civilization (race, home civ or not),
        state (approaching, at_depot, leaving, stuck), days remaining, merchant mood,
        flags (seized, offended, hardship, tribute), animals, and values; plus how many
        merchants are on the map and the season. Elves come in spring, humans in summer,
        dwarves in autumn.
        """
        return call(bridge, "trade.caravans")

    @mcp.tool(name="get_trade_depot", annotations=READ_ONLY)
    def get_trade_depot(depot_id: int | None = None, limit: int = 25) -> dict[str, Any]:
        """Read the trade depot: position, built, wagon access, whether the broker (or
        anyone) is requested, the TradeAtDepot job if a trader is there, the fort's goods
        at the depot and the merchants' goods with values at the active caravan's prices,
        and goods still being hauled. Place a depot with `place_furniture(type="trade_depot")`.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        args: dict[str, Any] = {"limit": limit}
        if depot_id is not None:
            args["depot_id"] = depot_id
        return call(bridge, "trade.depot", args)

    @mcp.tool(name="get_broker", annotations=READ_ONLY)
    def get_broker() -> dict[str, Any]:
        """Who the broker is, what they are doing, whether they stand at the depot, their
        appraisal skill, and whether a trader is requested at the depot. No broker: appoint
        one with `assign_noble` (position BROKER) or request anyone.
        """
        return call(bridge, "trade.broker")

    @mcp.tool(name="get_trade_screen", annotations=READ_ONLY)
    def get_trade_screen(limit: int = 25) -> dict[str, Any]:
        """Read the game's own trade screen while it is open (opened by the player or by
        `open_trade_screen`): whether it is open, the two traders, whether unloading is
        finished, the merchant's last reply in plain words (too heavy, not enough value,
        deal accepted, ...), `merchant_message` (the merchant's words), the caravan's `mood`,
        whether a counter-offer is pending with `counter_offer_items` (id, description, value;
        up to `limit`), the caravan's carrying capacity, and both goods lists with what is
        selected, its value, and its weight.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "trade.screen", {"limit": limit})

    @mcp.tool(name="select_trade_goods", annotations=WRITE_SAFE)
    def select_trade_goods(
        give: list[int] | None = None,
        take: list[int] | None = None,
        clear: bool = True,
        depot_id: int | None = None,
    ) -> dict[str, Any]:
        """Select goods on the player's open trade screen: `give` fort item ids, `take`
        merchant item ids (both from `get_trade_depot`). Needs `trade_write` and the screen
        open (`open_trade_screen`, or the player presses Trade on the depot). Check the deal
        first with `offer_trade` (value, profit, weight), then press with `press_trade` (or
        the player presses Trade or Offer).
        """
        args: dict[str, Any] = {"give": give or [], "take": take or [], "clear": clear}
        if depot_id is not None:
            args["depot_id"] = depot_id
        return call(bridge, "trade.select", args)

    @mcp.tool(name="request_broker", annotations=WRITE_SAFE)
    def request_broker(
        requested: bool = True, anyone: bool = False, depot_id: int | None = None
    ) -> dict[str, Any]:
        """Ask the broker to come to the depot (the game's "request trader" button), or
        allow anyone to trade with `anyone`. Needs `trade_write`. `requested=false`
        withdraws the request. The dwarf goes once a caravan is at the depot.
        """
        args: dict[str, Any] = {"requested": requested, "anyone": anyone}
        if depot_id is not None:
            args["depot_id"] = depot_id
        return call(bridge, "trade.request_broker", args)

    @mcp.tool(name="bring_to_depot", annotations=WRITE_SAFE)
    def bring_to_depot(
        item_ids: list[int] | None = None,
        query: str | None = None,
        item_type: str | None = None,
        limit: int = 25,
        depot_id: int | None = None,
    ) -> dict[str, Any]:
        """Have haulers bring goods to the depot for trade (the game's "move goods"
        screen). Needs `trade_write`. Name items by `item_ids` (from `find_items`) or by a
        `query` on their description with an optional `item_type` (CRAFTS, GEM, BAR, ...),
        up to `limit`. Forbidden, owned, in-use, mandated, merchant, or unreachable items
        are skipped with reasons. Returns the marked items with their trade values.
        """
        if not item_ids and not query:
            raise ValueError("pass item_ids or a query")
        if limit < 1:
            raise ValueError("limit must be at least 1")
        args: dict[str, Any] = {"limit": limit}
        if item_ids:
            args["item_ids"] = item_ids
        if query:
            args["query"] = query
        if item_type:
            args["item_type"] = item_type
        if depot_id is not None:
            args["depot_id"] = depot_id
        return call(bridge, "trade.bring", args)

    @mcp.tool(name="cancel_bring", annotations=CANCEL)
    def cancel_bring(item_ids: list[int], depot_id: int | None = None) -> dict[str, Any]:
        """Stop bringing items to the depot (cancels their hauling job) or release items
        already there back to the fort. Needs `trade_write`.
        """
        if not item_ids:
            raise ValueError("item_ids must not be empty")
        args: dict[str, Any] = {"item_ids": item_ids}
        if depot_id is not None:
            args["depot_id"] = depot_id
        return call(bridge, "trade.unbring", args)

    @mcp.tool(name="offer_trade", annotations=WRITE_SAFE)
    def offer_trade(
        give: list[int] | None = None,
        take: list[int] | None = None,
        depot_id: int | None = None,
    ) -> dict[str, Any]:
        """Evaluate a trade with the caravan at the depot: `give` are the fort's item ids at
        the depot, `take` the merchants' item ids (both from `get_trade_depot`). Returns both
        sides' values at the caravan's prices, the profit and margin, and a verdict
        (merchants never accept a loss; 50% profit is always accepted). Needs `trade_write`.
        It trades nothing: select the goods with `select_trade_goods` on the open trade
        screen and press with `press_trade`.
        """
        args: dict[str, Any] = {"give": give or [], "take": take or []}
        if depot_id is not None:
            args["depot_id"] = depot_id
        return call(bridge, "trade.offer", args)

    @mcp.tool(name="open_trade_screen", annotations=WRITE_SAFE)
    def open_trade_screen(
        depot_id: int | None = None, caravan_index: int | None = None
    ) -> dict[str, Any]:
        """Open the game's trade screen at the depot, as the depot's Trade button does.
        Needs `screens_write`. A caravan must be at the depot (`list_caravans` state
        at_depot) and the depot built; wait until the broker stands at the depot
        (`get_broker`) and the merchants have finished unloading, or the screen opens without
        a trader. `caravan_index` (from `list_caravans`) picks one when several are at the
        depot. Returns `opened`, the fields written, the `get_trade_screen` view, and
        `warnings`. SCREEN_BUSY means the player has another menu open: try later or ask them.
        """
        args: dict[str, Any] = {}
        if depot_id is not None:
            args["depot_id"] = depot_id
        if caravan_index is not None:
            args["caravan_index"] = caravan_index
        return call(bridge, "trade.open_screen", args)

    @mcp.tool(name="press_trade", annotations=PRESS)
    def press_trade(action: str, unpause: bool = False, limit: int = 25) -> dict[str, Any]:
        """Press a button on the open trade screen through the game's own handler. Needs
        `screens_write`. Evaluate the deal with `offer_trade` and select the goods with
        `select_trade_goods` first. `action`:
        `trade` exchanges the selected goods and is final;
        `offer` gives the selected fort goods away as a gift, nothing comes back;
        `seize` takes the selected merchant goods, angers their civilization, and ends
        trading with this caravan: never use it unless the player asked;
        `accept_counter` / `decline_counter` answer a counter-offer, which comes back as
        `counter_offer: true` with `counter_offer_items` (up to `limit`);
        `close` closes the screen when done, with `unpause=True` when `pause_write` is on.
        Returns the merchant's `reply` and `reply_meaning`, `merchant_message`, `mood_before`
        and `mood_after`, the counter-offer, whether the screen is still open, the goods
        counts after, and the pause state. SCREEN_BUSY means the player has another menu open.
        """
        if action not in PRESS_ACTIONS:
            raise ValueError(f"action must be one of {', '.join(PRESS_ACTIONS)}")
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(
            bridge, "trade.press", {"action": action, "unpause": unpause, "limit": limit}
        )
