from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE

SLOT_COUNT = 16


def _check_slot(slot: int) -> None:
    if not 1 <= slot <= SLOT_COUNT:
        raise ValueError(f"slot must be between 1 and {SLOT_COUNT}")


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_hotkeys", annotations=READ_ONLY)
    def list_hotkeys() -> dict[str, Any]:
        """List the 16 zoom hotkeys: the player's F-key points of interest.

        Each slot has `slot` (1-16), `key` (the key label the game shows, such as F1),
        `kind` (`none`, `zoom`, `follow_unit`, `follow_item`), `name`, `empty`, and `pos`
        `{x, y, z}` for zoom slots (or `unit_id` / `item_id` for follow slots).
        `free_slots` lists the unused ones. Slot 1 is the game's default "Wagon arrival
        location". Use these slots to name the fort's points of interest (entrance, depot,
        farms, barracks, a project site) so the player can jump there.
        """
        return call(bridge, "hotkeys.list")

    @mcp.tool(name="set_hotkey", annotations=WRITE_SAFE)
    def set_hotkey(
        name: str,
        x: int,
        y: int,
        z: int,
        slot: int | None = None,
        overwrite: bool = False,
    ) -> dict[str, Any]:
        """Name a point of interest as a zoom hotkey the player can jump to with an F-key.

        Use the 16 slots for the fort's points of interest (entrance, depot, farms,
        barracks, a project site) with short names. `x`, `y`, `z` must be inside the map
        (`get_map_bounds`). `slot` (1-16) is optional: by default the first unused slot is
        taken; when all 16 are used, clear one with `clear_hotkey` or pass `slot` with
        `overwrite`. Slot 1 is the wagon by default. A slot that already holds something,
        often the player's own, is refused unless `overwrite=True`; if you overwrite one,
        tell the player with `send_message`. Names are clipped to the game's length.
        Refused while the player has the Hotkeys window open. Needs `hotkeys_write`, off by
        default. Returns `slot`, `key`, the stored `name`, `pos`, and `overwrote` (the
        replaced slot) when one was replaced.
        """
        if not name or not name.strip():
            raise ValueError("name must be a non-empty string")
        if slot is not None:
            _check_slot(slot)
        return call(
            bridge,
            "hotkeys.set",
            {
                "name": name.strip(),
                "x": x,
                "y": y,
                "z": z,
                "slot": slot,
                "overwrite": overwrite,
            },
        )

    @mcp.tool(name="clear_hotkey", annotations=WRITE_SAFE)
    def clear_hotkey(slot: int) -> dict[str, Any]:
        """Clear one zoom hotkey slot (1-16) so it is free again.

        Only clear slots you set yourself or the player asked you to; slot 1 is the wagon
        default. Refused while the player has the Hotkeys window open. Needs
        `hotkeys_write`, off by default. Returns `slot`, `cleared` (false when the slot was
        already empty), and `previous` `{name, kind, pos}`.
        """
        _check_slot(slot)
        return call(bridge, "hotkeys.clear", {"slot": slot})
