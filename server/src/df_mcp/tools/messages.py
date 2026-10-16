from __future__ import annotations

from typing import Any

from mcp.server import MCPServer
from mcp.types import ToolAnnotations

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY

MAX_CHARS = 200
BADGES = (
    "rumor",
    "general",
    "research",
    "guest",
    "masterpiece",
    "noble",
    "era",
    "holdings",
    "deity",
    "agreement",
)
SAY = ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False)


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="send_message", annotations=SAY)
    def send_message(
        text: str,
        x: int | None = None,
        y: int | None = None,
        z: int | None = None,
        badge: str = "rumor",
    ) -> dict[str, Any]:
        """Tell the player something inside the game: the text appears in the announcement
        log and as an alert on the left side of the screen, in light red. Keep it short
        (at most 200 characters, one sentence or two). Give x, y, z to let the player click
        the alert and zoom to that spot (a new room, a threat, a stockpile). `badge` picks
        the alert icon's category: rumor (default, a speech bubble), general, research,
        guest, masterpiece, noble, era, holdings, deity, agreement. Use it to report that a
        plan is made, to ask for a decision, or to point at something; not for logs.
        """
        if not text or not text.strip():
            raise ValueError("text must not be empty")
        if len(text.strip()) > MAX_CHARS:
            raise ValueError(f"text must be at most {MAX_CHARS} characters")
        if badge not in BADGES:
            raise ValueError(f"badge must be one of {', '.join(BADGES)}")
        pos = [x, y, z]
        if any(v is not None for v in pos) and any(v is None for v in pos):
            raise ValueError("give x, y, and z together")
        args: dict[str, Any] = {"text": text.strip(), "badge": badge}
        if x is not None:
            args.update({"x": x, "y": y, "z": z})
        return call(bridge, "messages.say", args)

    @mcp.tool(name="list_message_badges", annotations=READ_ONLY)
    def list_message_badges() -> dict[str, Any]:
        """List the badge categories `send_message` can use and the message length cap."""
        return call(bridge, "messages.badges")
