from __future__ import annotations

from typing import Any

from mcp.server import MCPServer
from mcp.types import ToolAnnotations

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE

KINDS = ("melee", "crossbow")
ORDER_KINDS = ("station", "kill", "patrol", "cancel")

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

    @mcp.tool(name="order_squad", annotations=WRITE_SAFE)
    def order_squad(
        squad_id: int,
        kind: str,
        x: int | None = None,
        y: int | None = None,
        z: int | None = None,
        unit_ids: list[int] | None = None,
        route_id: int | None = None,
        title: str | None = None,
    ) -> dict[str, Any]:
        """Give a squad an order, replacing any current order. Needs `military_write`.

        `kind` "station" moves the squad to a walkable tile (x, y, z); "kill" sends it
        after `unit_ids` (non-citizens), with an optional `title`; "patrol" walks a route
        from `list_routes` (`route_id`); "cancel" clears orders so the squad returns to its
        routine. Soldiers follow when they can; `get_squad` lists the active orders.
        """
        if kind not in ORDER_KINDS:
            raise ValueError(f"kind must be one of {', '.join(ORDER_KINDS)}")
        args: dict[str, Any] = {"id": squad_id, "kind": kind}
        if kind == "station":
            if x is None or y is None or z is None:
                raise ValueError("a station order needs x, y, z")
            args.update({"x": x, "y": y, "z": z})
        elif kind == "kill":
            if not unit_ids:
                raise ValueError("a kill order needs unit_ids")
            args["unit_ids"] = unit_ids
            if title is not None:
                args["title"] = title
        elif kind == "patrol":
            if route_id is None:
                raise ValueError("a patrol order needs route_id")
            args["route_id"] = route_id
        return call(bridge, "military.order", args)

    @mcp.tool(name="set_squad_routine", annotations=WRITE_SAFE)
    def set_squad_routine(squad_id: int, routine: str) -> dict[str, Any]:
        """Switch a squad's schedule to one of the fort's routines by name or index (see
        `list_squads`: Off duty, Staggered training, Constant training, Ready). Training
        needs a barracks zone assigned to the squad. Needs `military_write`.
        """
        return call(bridge, "military.set_routine", {"id": squad_id, "routine": routine})

    @mcp.tool(name="list_routes", annotations=READ_ONLY)
    def list_routes() -> dict[str, Any]:
        """List the fort's patrol routes with their waypoints."""
        return call(bridge, "military.routes")

    @mcp.tool(name="create_route", annotations=WRITE_SAFE)
    def create_route(points: list[list[int]], name: str | None = None) -> dict[str, Any]:
        """Create a patrol route from a list of at least two walkable [x, y, z] points, in
        order. Needs `military_write`. Returns the route id for `order_squad(kind="patrol")`.
        """
        if len(points) < 2 or any(len(p) != 3 for p in points):
            raise ValueError("points must be at least two [x, y, z] entries")
        args: dict[str, Any] = {"points": [{"x": p[0], "y": p[1], "z": p[2]} for p in points]}
        if name is not None:
            args["name"] = name
        return call(bridge, "military.create_route", args)
