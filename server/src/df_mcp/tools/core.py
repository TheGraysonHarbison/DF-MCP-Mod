from __future__ import annotations

from typing import Any

from mcp.server import MCPServer
from mcp.types import ToolAnnotations

from df_mcp.bridge import Bridge
from df_mcp.tools import call

READ_ONLY = ToolAnnotations(read_only_hint=True, destructive_hint=False, open_world_hint=False)
# Changes game state but is reversible and repeatable (renaming, toggling).
WRITE_SAFE = ToolAnnotations(
    read_only_hint=False, destructive_hint=False, idempotent_hint=True, open_world_hint=False
)


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="ping", annotations=READ_ONLY)
    def ping() -> dict[str, Any]:
        """Check the bridge to the running Dwarf Fortress game.

        Returns DFHack and DF versions, mod and protocol versions, whether a world and a map
        are loaded, and the current game tick. Call this first in a session.
        """
        return call(bridge, "core.ping")

    @mcp.tool(name="get_permissions", annotations=READ_ONLY)
    def get_permissions() -> dict[str, Any]:
        """Show what the player has allowed Claude to do.

        Returns the per-namespace permission toggles, the console command allowlist, and the
        list of ops the mod currently exposes. Permissions are set by the player in-game with
        the `claude-bridge settings` window and cannot be changed from here.
        """
        return call(bridge, "settings.get")
