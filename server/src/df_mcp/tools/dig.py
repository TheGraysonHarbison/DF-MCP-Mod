from __future__ import annotations

from typing import Any

from mcp.server import MCPServer
from mcp.types import ToolAnnotations

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE

KINDS = ("mine", "stairs", "channel", "ramp", "remove_stairs", "smooth", "engrave")
ERASE_KINDS = (
    "mine",
    "up_stair",
    "down_stair",
    "up_down_stair",
    "channel",
    "ramp",
    "smooth",
    "engrave",
)

ERASE = ToolAnnotations(
    read_only_hint=False, destructive_hint=True, idempotent_hint=True, open_world_hint=False
)

BOX_DOC = """The box is two corners in any order, every corner inside the map, at most
        64 by 64 tiles per level and 32 levels. `kind`: "mine" digs out walls; "stairs"
        carves a staircase through every level of the box (down stair on top, up/down
        between, up stair at the bottom; the box must span at least two levels; a 1 by 1
        box makes a stair column); "channel" digs the floor away, leaving a ramp below;
        "ramp" carves a ramp out of a wall; "remove_stairs" removes carved stairs and ramps;
        "smooth" smooths natural rock walls and floors (not soil, not constructions, not
        hidden rock); "engrave" engraves tiles that are already smooth.
        Tiles that already carry an order or a job are skipped, never overwritten, as are
        constructions, trees, buildings, and the map edge. Unrevealed rock is designated,
        which is how exploratory mining works. Returns `designated`, the skipped counts,
        `by_level`, and the first 25 skipped tiles with reasons. Layout rule: dwarves move
        diagonally, so a room needs a fully solid border including its corners; leave at
        least one wall tile between rooms and between a room and a corridor, and connect
        them only through deliberate doorways. Two rooms whose corners touch are one room."""


def _box(x1: int, y1: int, z1: int, x2: int, y2: int, z2: int, kind: str | None) -> dict[str, Any]:
    return {"x1": x1, "y1": y1, "z1": z1, "x2": x2, "y2": y2, "z2": z2, "kind": kind}


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="plan_dig", annotations=READ_ONLY)
    def plan_dig(kind: str, x1: int, y1: int, z1: int, x2: int, y2: int, z2: int) -> dict[str, Any]:
        (
            """Preview a dig order without changing anything: what `designate_dig` would place.

        Use this first, then `designate_dig` with the same arguments once the plan looks
        right (or show it to the player). Needs only `map`.
        """
            + BOX_DOC
        )
        if kind not in KINDS:
            raise ValueError(f"kind must be one of {', '.join(KINDS)}")
        return call(bridge, "dig.plan", _box(x1, y1, z1, x2, y2, z2, kind))

    @mcp.tool(name="designate_dig", annotations=WRITE_SAFE)
    def designate_dig(
        kind: str, x1: int, y1: int, z1: int, x2: int, y2: int, z2: int
    ) -> dict[str, Any]:
        (
            """Place dig orders in a box for the miners. Needs `dig_write`.

        Nothing is dug instantly; miners take the orders when free, exactly as if the
        player had drawn the box. Preview with `plan_dig` first.
        """
            + BOX_DOC
        )
        if kind not in KINDS:
            raise ValueError(f"kind must be one of {', '.join(KINDS)}")
        return call(bridge, "dig.designate", _box(x1, y1, z1, x2, y2, z2, kind))

    @mcp.tool(name="erase_designations", annotations=ERASE)
    def erase_designations(
        x1: int, y1: int, z1: int, x2: int, y2: int, z2: int, kind: str | None = None
    ) -> dict[str, Any]:
        """Remove dig, stair, channel, ramp, smooth, and engrave orders in a box, cancelling
        any queued jobs for them. Needs `dig_write`. `kind` limits it to one of mine,
        up_stair, down_stair, up_down_stair, channel, ramp, smooth, engrave. Already dug
        tiles are not changed. Check `list_designations` first so a staircase is not erased
        by accident.
        """
        if kind is not None and kind not in ERASE_KINDS:
            raise ValueError(f"kind must be one of {', '.join(ERASE_KINDS)}")
        return call(bridge, "dig.erase", _box(x1, y1, z1, x2, y2, z2, kind))
