from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_popups", annotations=READ_ONLY)
    def list_popups(limit: int = 25) -> dict[str, Any]:
        """List the box popups open in the game, front (the one on screen) first.

        Popups pause the game until they are closed: the embark message at a new fort, the
        first caravan, a megabeast or werebeast, a siege, an artifact, a mood. A `popup`
        event announces each one; read the full text here when the event's text was cut.
        Each popup: `index` (1-based), `text` (up to 4000 characters, `text_truncated` when
        cut), `color`, `bright`, `portrait` (`hist_figure_id`, `name`) when the box shows a
        figure. Also `count`, `paused`, `truncated` (more than `limit` open). Act on what the
        text says, then close it with `close_popup`.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "popups.list", {"limit": limit})

    @mcp.tool(name="close_popup", annotations=WRITE_SAFE)
    def close_popup(unpause: bool = False) -> dict[str, Any]:
        """Close the front box popup the way its Close button does. Needs `screens_write`.

        Popups pause the game. Read the text first (`list_popups` or the `popup` event), act
        on what it says (first caravan: prepare goods for trade; megabeast or siege: raise
        the military and bring dwarves inside; embark message: start the plan), then close
        it. Pass `unpause=True` when `pause_write` is on (see `get_permissions`) to let the
        game run again; otherwise the game stays paused and you tell the player so. Errors:
        `NOT_FOUND` when no popup is open; `SCREEN_BUSY` when the player has a menu open:
        the menu is never closed, retry later. Returns `closed` (`text` first 400
        characters, `color`, `portrait`), `remaining` (boxes still open; close each),
        `unpaused`, `paused`, `pause_note` when unpause was refused, and `note`.
        """
        return call(bridge, "popups.close", {"unpause": bool(unpause)})
