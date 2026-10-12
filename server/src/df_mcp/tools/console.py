from __future__ import annotations

from typing import Any

from mcp.server import MCPServer
from mcp.types import ToolAnnotations

from df_mcp.bridge import Bridge
from df_mcp.tools import call

CONSOLE = ToolAnnotations(read_only_hint=False, destructive_hint=True, open_world_hint=False)


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="run_console_command", annotations=CONSOLE)
    def run_console_command(command: str) -> dict[str, Any]:
        """Run a DFHack console command and return its output.

        Only commands the player has added to the allowlist (see `get_permissions`) will run;
        anything else is refused with NOT_ALLOWED. The whole line is passed to DFHack, so
        include arguments, for example `ls`, `prospect --help`, or `quickfort list`.
        """
        return call(bridge, "console.run", {"command": command})
