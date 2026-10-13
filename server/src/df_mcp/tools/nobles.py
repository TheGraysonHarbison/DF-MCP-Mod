from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_nobles", annotations=READ_ONLY)
    def list_nobles() -> dict[str, Any]:
        """List the fort's noble and administrative positions and who holds them.

        Each position has `code` (use it with `assign_noble`), `name`, `precedence`,
        `holders` (unit ids and names), `slots`, `vacant`, `military` (assigned through
        squads, not here), `responsibilities`, and the rooms and furniture it requires.
        """
        return call(bridge, "nobles.list")

    @mcp.tool(name="assign_noble", annotations=WRITE_SAFE)
    def assign_noble(
        position: str, unit_id: int | None = None, slot: int | None = None
    ) -> dict[str, Any]:
        """Assign a citizen to a noble position, or vacate it.

        `position` is a code from `list_nobles` such as MANAGER, BOOKKEEPER, BROKER, or
        CHIEF_MEDICAL_DWARF. `unit_id` is the citizen to appoint; omit it to leave the
        position empty. `slot` picks one of several seats when the position has more than
        one; by default the unit's current seat, else the first vacant, else the first.
        Military positions are refused. This changes the game and needs the
        `nobles_write` permission, off by default. Returns `changed`, `previous` holder,
        and the updated position.
        """
        if not position or not position.strip():
            raise ValueError("position must be a non-empty code or id")
        if slot is not None and slot < 1:
            raise ValueError("slot must be 1 or greater")
        return call(
            bridge, "nobles.assign", {"position": position.strip(), "id": unit_id, "slot": slot}
        )
