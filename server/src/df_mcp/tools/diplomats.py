from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE

MEETING_ACTIONS = ("continue", "choose", "done", "land_holder", "close")


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_diplomats", annotations=READ_ONLY)
    def list_diplomats(limit: int = 25) -> dict[str, Any]:
        """Diplomats and liaisons on the map with their civilization and job, who is waiting
        to meet, the site leader (who holds the meeting) and what they are doing, the
        recorded meetings, the game's diplomacy screen state, and the standing trade
        agreements: what the fort asked the caravan to bring (`imports.requested`, with the
        price mark-up) and what the caravan pays more for (`exports.price_changes`). The
        meeting dialog itself is read with `get_meeting_dialog` and driven with
        `open_meeting_dialog` and `step_meeting_dialog`.
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

    @mcp.tool(name="get_meeting_dialog", annotations=READ_ONLY)
    def get_meeting_dialog(limit: int = 25) -> dict[str, Any]:
        """The liaison's meeting dialog: `available` (a meeting is waiting: a `pending`
        meeting with its actor and noble, or its left-side alert; `available_from` says
        which; `alerts` lists every current alert with its report texts), `open`, `step` (`text`,
        `requests`, `land_holder`, or `closed`), the dialog `text` as lines, the dipscript
        position (`script`), `screen_rows` (the dialog as rendered on screen: its lines and
        the button labels such as Continue, Done, and the replies), the `requests` tabs,
        the `land_holder` positions and candidates (`hist_figure_id`, name), and `paused`.
        The open dialog pauses the game. Flow: a `meeting_ready` event, then
        `open_meeting_dialog`, read this, set next year's requests with
        `set_trade_requests` on the requests step, finish that step with
        `step_meeting_dialog(action="done")`, press `continue` until the liaison says
        farewell (the last Continue closes the dialog itself), choose a land holder when
        asked, and `close` only to leave early.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "trade.dialog", {"limit": limit})

    @mcp.tool(name="open_meeting_dialog", annotations=WRITE_SAFE)
    def open_meeting_dialog() -> dict[str, Any]:
        """Open the liaison's meeting dialog the way a click on its left-side alert does
        (needs `screens_write`). Answers `already_open` when it is open, NOT_FOUND when no
        meeting alert is up or the game has not prepared the meeting yet, and SCREEN_BUSY
        when the player has another screen open (the player's menu is never closed; try
        later or tell the player). Returns the dialog as `get_meeting_dialog` reads it. If
        the dialog does not show, ask the player to click the meeting alert.
        """
        return call(bridge, "trade.open_dialog", {})

    @mcp.tool(name="step_meeting_dialog", annotations=WRITE_SAFE)
    def step_meeting_dialog(
        action: str,
        label: str | None = None,
        hf_id: int | None = None,
        position_index: int | None = None,
        unpause: bool = False,
    ) -> dict[str, Any]:
        """Press a button on the open meeting dialog (needs `screens_write`). The buttons
        are pressed for real, found by their label on the screen. `action`: `continue`
        (the Continue button; the game runs its script one step), `choose` (a reply, with
        `label` as the exact text on its button, read from `screen_rows`), `done` (the
        Done button of the requests step, after `set_trade_requests`), `land_holder` (the
        candidate's button, by `hf_id` from `land_holder.candidates` or by `label`), or
        `close` (Escape; with `unpause=True` the game resumes when `pause_write` is on,
        otherwise it stays paused and `pause_note` says so). NOT_FOUND names a button that
        is not on screen; SCREEN_BUSY means another screen is open. Returns `clicked`, and
        the dialog read afterwards.
        """
        if action not in MEETING_ACTIONS:
            raise ValueError("action must be one of " + ", ".join(MEETING_ACTIONS))
        args: dict[str, Any] = {"action": action}
        if action == "choose":
            if not label:
                raise ValueError("choose needs label, the text on the reply button")
            args["label"] = label
        if action == "land_holder":
            if hf_id is None and not label:
                raise ValueError("land_holder needs hf_id or label")
            if hf_id is not None:
                args["hf_id"] = hf_id
            if label:
                args["label"] = label
            if position_index is not None:
                if position_index < 0:
                    raise ValueError("position_index must be non-negative")
                args["position_index"] = position_index
        if unpause:
            args["unpause"] = True
        return call(bridge, "trade.dialog_step", args)
