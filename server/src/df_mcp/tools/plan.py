from __future__ import annotations

from typing import Any

from mcp.server import MCPServer
from mcp.types import ToolAnnotations

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY

WRITE = ToolAnnotations(read_only_hint=False, destructive_hint=True, idempotent_hint=True)
APPEND = ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False)


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="get_plan_info", annotations=READ_ONLY)
    def get_plan_info() -> dict[str, Any]:
        """How this fort's plan and goals are stored: `storage` is "site data" (DFHack's
        per-fort data, written into every save including autosaves), `plan` and `goals`
        give each text's size, whether it is stored, and whether its readable mirror file
        in `folder` (`claude-df/` in the current save) matches; plus the size cap and the
        goal prompt the player set.
        """
        return call(bridge, "plan.info")

    @mcp.tool(name="read_plan", annotations=READ_ONLY)
    def read_plan() -> dict[str, Any]:
        """Read your plan for this fort. It is yours to keep plans, standing rules, and
        memory about this fort; it is stored with the fort and follows every save and
        autosave. Read it at the start of a session and whenever goals or events arrive.
        """
        return call(bridge, "plan.read")

    @mcp.tool(name="write_plan", annotations=WRITE)
    def write_plan(text: str) -> dict[str, Any]:
        """Replace your whole plan with `text` (Markdown, at most 64 KB). Use
        `append_plan` for notes; rewrite when the plan changes shape.
        """
        return call(bridge, "plan.write", {"text": text})

    @mcp.tool(name="append_plan", annotations=APPEND)
    def append_plan(text: str) -> dict[str, Any]:
        """Append a section or note to your plan (a newline is added before and after
        as needed). Refused when the plan would pass 64 KB.
        """
        return call(bridge, "plan.append", {"text": text})

    @mcp.tool(name="read_goals", annotations=READ_ONLY)
    def read_goals() -> dict[str, Any]:
        """Read the player's goals for this fort (edited in the game's `claude-bridge goals`
        window). The player sends them to you as a `goals` channel
        message when they change; read them here any time.
        """
        return call(bridge, "goals.read")
