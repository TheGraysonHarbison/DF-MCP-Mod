from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_event_kinds", annotations=READ_ONLY)
    def list_event_kinds() -> dict[str, Any]:
        """List the in-game event kinds the mod can send (mineral discovered, strange mood,
        caravan arrived, units fighting, petition, ...), which ones the player enabled, how
        each is detected, and the queue state. Enabled events arrive on their own as channel
        messages while the session runs with the channel flag; `poll_events` reads them by
        hand otherwise.
        """
        return call(bridge, "events.kinds")

    @mcp.tool(name="poll_events", annotations=READ_ONLY)
    def poll_events(
        after_seq: int | None = None, limit: int = 50, force: bool = False
    ) -> dict[str, Any]:
        """Read queued events by hand (the fallback when the channel is not loaded).

        Call once without `after_seq` to learn `next_seq`, then pass `after_seq` =
        next_seq - 1 and keep passing the last `last_seq` you received. A batch is returned
        once the newest waiting event is two seconds old or 50 are waiting; `force` returns
        whatever is waiting now. Each event: `seq`, `kind`, `tick`, `text`, `pos`,
        `unit_ids`, `item_id`, `extra`.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        args: dict[str, Any] = {"limit": limit, "force": force}
        if after_seq is not None:
            args["after_seq"] = after_seq
        return call(bridge, "events.poll", args)
