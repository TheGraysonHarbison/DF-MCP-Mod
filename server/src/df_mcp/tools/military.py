from __future__ import annotations

from typing import Any

from mcp.server import MCPServer
from mcp.types import ToolAnnotations

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE

KINDS = ("melee", "crossbow")

DISBAND = ToolAnnotations(
    read_only_hint=False, destructive_hint=True, idempotent_hint=False, open_world_hint=False
)


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_squads", annotations=READ_ONLY)
    def list_squads(limit: int = 25) -> dict[str, Any]:
        """List the fort's military squads with id, name, nickname, kind (melee, crossbow,
        or unarmed, from the uniform's weapon slot), member count, slots, leader, current
        routine, and whether it is training. Also returns `vacant_positions` (the militia
        commander and captain seats a new squad can be created on, with their holder when the
        game already appointed one), `routines` (Off duty, Staggered training, Constant
        training, Ready), and the fort's uniform `presets`.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "military.list", {"limit": limit})

    @mcp.tool(name="get_squad", annotations=READ_ONLY)
    def get_squad(squad_id: int) -> dict[str, Any]:
        """Read one squad: every slot with its member and uniform (per category: body, head,
        pants, gloves, shoes, shield, weapon, each a list of item type, item, material class,
        individual choice), the exact-match and replace-clothing flags, ammunition, barracks
        rooms, and supplies.
        """
        return call(bridge, "military.get", {"id": squad_id})

    @mcp.tool(name="create_squad", annotations=WRITE_SAFE)
    def create_squad(
        name: str | None = None,
        kind: str | None = None,
        preset: str | None = None,
        position: str | None = None,
    ) -> dict[str, Any]:
        """Create a squad on a vacant military seat. Needs `military_write`.

        `kind` "melee" or "crossbow" picks the matching vanilla uniform preset (crossbow
        squads also get 100 bolts for combat and training); `preset` names one of the fort's
        uniform presets instead (see `list_squads`). `name` is the squad's nickname.
        `position` picks the seat (a position token such as MILITIA_COMMANDER or an
        assignment id); by default the first militia seat is used. If the game already
        appointed a dwarf to that seat, they become the leader; otherwise set one with
        `set_squad_leader` before adding members.
        """
        if kind is not None and kind not in KINDS:
            raise ValueError(f"kind must be one of {', '.join(KINDS)}")
        args: dict[str, Any] = {}
        if name is not None:
            args["name"] = name
        if kind is not None:
            args["kind"] = kind
        if preset is not None:
            args["preset"] = preset
        if position is not None:
            args["position"] = position
        return call(bridge, "military.create", args)

    @mcp.tool(name="rename_squad", annotations=WRITE_SAFE)
    def rename_squad(squad_id: int, name: str) -> dict[str, Any]:
        """Set a squad's nickname (shown in place of its generated name; empty clears it).
        Needs `military_write`.
        """
        return call(bridge, "military.rename", {"id": squad_id, "name": name})

    @mcp.tool(name="set_squad_symbol", annotations=WRITE_SAFE)
    def set_squad_symbol(
        squad_id: int,
        symbol: int | None = None,
        foreground: list[int] | None = None,
        background: list[int] | None = None,
    ) -> dict[str, Any]:
        """Set the badge the game draws for a squad: `symbol` is an index 0 to 22 on the
        vanilla squad symbol sheet (row-wise), `foreground` and `background` are [r, g, b]
        colours 0 to 255. Pass any subset. Needs `military_write`.
        """
        if symbol is not None and not 0 <= symbol <= 22:
            raise ValueError("symbol must be 0 to 22")
        for name, value in (("foreground", foreground), ("background", background)):
            if value is not None and (len(value) != 3 or any(not 0 <= v <= 255 for v in value)):
                raise ValueError(f"{name} must be [r, g, b] with values 0 to 255")
        if symbol is None and foreground is None and background is None:
            raise ValueError("pass symbol, foreground, or background")
        args: dict[str, Any] = {"id": squad_id}
        if symbol is not None:
            args["symbol"] = symbol
        if foreground is not None:
            args["foreground"] = foreground
        if background is not None:
            args["background"] = background
        return call(bridge, "military.set_symbol", args)

    @mcp.tool(name="add_to_squad", annotations=WRITE_SAFE)
    def add_to_squad(squad_id: int, unit_id: int, slot: int | None = None) -> dict[str, Any]:
        """Add a citizen to a squad, into `slot` (0 is the leader) or the first free slot.
        Needs `military_write`. A citizen already in a squad must be removed first. Adding
        to a squad with no leader makes the citizen its leader.
        """
        args: dict[str, Any] = {"id": squad_id, "unit_id": unit_id}
        if slot is not None:
            args["slot"] = slot
        return call(bridge, "military.add", args)

    @mcp.tool(name="remove_from_squad", annotations=WRITE_SAFE)
    def remove_from_squad(squad_id: int, unit_id: int) -> dict[str, Any]:
        """Remove a member from a squad (the leader included, which frees the seat). Needs
        `military_write`.
        """
        return call(bridge, "military.remove", {"id": squad_id, "unit_id": unit_id})

    @mcp.tool(name="set_squad_leader", annotations=WRITE_SAFE)
    def set_squad_leader(squad_id: int, unit_id: int) -> dict[str, Any]:
        """Make a citizen the squad's leader (slot 0 and the seat's holder), replacing the
        current leader, who leaves the squad. Needs `military_write`.
        """
        return call(bridge, "military.set_leader", {"id": squad_id, "unit_id": unit_id})

    @mcp.tool(name="disband_squad", annotations=DISBAND)
    def disband_squad(squad_id: int) -> dict[str, Any]:
        """Disband a squad: every member is removed, its barracks links dropped, its seat
        freed, and the squad deleted. Needs `military_write`. Cannot be undone.
        """
        return call(bridge, "military.disband", {"id": squad_id})
