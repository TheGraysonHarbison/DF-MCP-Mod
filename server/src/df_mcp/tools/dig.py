from __future__ import annotations

from typing import Any

from mcp.server import MCPServer
from mcp.types import ToolAnnotations

from df_mcp.bridge import Bridge
from df_mcp.tools import call, tool_doc
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE

KINDS = (
    "mine",
    "stairs",
    "channel",
    "ramp",
    "remove_stairs",
    "smooth",
    "engrave",
    "chop",
    "gather",
)
ERASE_KINDS = (
    "mine",
    "up_stair",
    "down_stair",
    "up_down_stair",
    "channel",
    "ramp",
    "smooth",
    "engrave",
    "chop",
    "gather",
)

ERASE = ToolAnnotations(
    read_only_hint=False, destructive_hint=True, idempotent_hint=True, open_world_hint=False
)

BOX_DOC = """The box is two corners in any order and may be any size up to the whole map
        (`get_map_bounds`); corners past the map edge are clipped to it (the result's
        `box.clipped` is true) and a box wholly off the map is refused. Big boxes pause the
        game longer while every tile is checked: preview with `plan_dig` first. `kind`: "mine" digs
        out walls; "stairs"
        carves a staircase through every level of the box (down stair on top, up/down
        between, up stair at the bottom; the box must span at least two levels; a 1 by 1
        box makes a stair column); "channel" digs the floor away, leaving a ramp below;
        "ramp" carves a ramp out of a wall; "remove_stairs" removes carved stairs and ramps;
        "smooth" smooths natural rock walls and floors (not soil, not constructions, not
        hidden rock); "engrave" engraves tiles that are already smooth; "chop" marks every
        tree whose base tile is in the box for felling (saplings are skipped); "gather" marks
        every living shrub in the box for herbalists. `list_plants` shows what is there.
        Tiles that already carry an order or a job are skipped, never overwritten, as are
        constructions, trees, buildings, and the map edge. Unrevealed rock is designated,
        which is how exploratory mining works. Instead of a box, a filled circle on one
        level takes `center_x`, `center_y`, `center_z` (on the map), and `radius` (1 or more,
        clipped at the map edge; a tile is in when dx*dx + dy*dy <= r*r + r), for every
        kind but stairs. Returns `designated`,
        the skipped counts, `by_level`, and the first 25 skipped tiles with reasons.
        Layout rule: dwarves move diagonally, so a room needs a fully solid border
        including its corners; leave at least one wall tile between rooms and between a
        room and a corridor, and connect them only through deliberate doorways. Two rooms
        whose corners touch are one room."""


PLAN_DIG_DOC = tool_doc(
    """Preview a dig order without changing anything: what `designate_dig` would place.

        Use this first, then `designate_dig` with the same arguments once the plan looks
        right (or show it to the player). Needs only `map`.""",
    BOX_DOC,
)

DESIGNATE_DIG_DOC = tool_doc(
    """Place dig orders in a box anywhere on the map for the miners. Needs `dig_write`.

        Nothing is dug instantly; miners take the orders when free, exactly as if the
        player had drawn the box. Preview with `plan_dig` first.""",
    BOX_DOC,
)


def _box(x1: int, y1: int, z1: int, x2: int, y2: int, z2: int, kind: str | None) -> dict[str, Any]:
    return {"x1": x1, "y1": y1, "z1": z1, "x2": x2, "y2": y2, "z2": z2, "kind": kind}


def _shape(
    kind: str,
    x1: int | None,
    y1: int | None,
    z1: int | None,
    x2: int | None,
    y2: int | None,
    z2: int | None,
    center_x: int | None,
    center_y: int | None,
    center_z: int | None,
    radius: int | None,
) -> dict[str, Any]:
    circle = [center_x, center_y, center_z, radius]
    box = [x1, y1, z1, x2, y2, z2]
    if all(v is not None for v in circle):
        if any(v is not None for v in box):
            raise ValueError("give either a box (x1..z2) or a circle (center_x..radius), not both")
        if kind == "stairs":
            raise ValueError("stairs take a box; a 1 by 1 box across levels makes a stair column")
        return {
            "kind": kind,
            "circle": {"x": center_x, "y": center_y, "z": center_z, "radius": radius},
        }
    if any(v is not None for v in circle):
        raise ValueError("a circle needs center_x, center_y, center_z, and radius together")
    if any(v is None for v in box):
        raise ValueError(
            "give a box (x1, y1, z1, x2, y2, z2) or a circle (center_x, center_y, center_z, radius)"
        )
    return _box(x1, y1, z1, x2, y2, z2, kind)  # type: ignore[arg-type]


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="plan_dig", annotations=READ_ONLY, description=PLAN_DIG_DOC)
    def plan_dig(
        kind: str,
        x1: int | None = None,
        y1: int | None = None,
        z1: int | None = None,
        x2: int | None = None,
        y2: int | None = None,
        z2: int | None = None,
        center_x: int | None = None,
        center_y: int | None = None,
        center_z: int | None = None,
        radius: int | None = None,
    ) -> dict[str, Any]:
        if kind not in KINDS:
            raise ValueError(f"kind must be one of {', '.join(KINDS)}")
        return call(
            bridge,
            "dig.plan",
            _shape(kind, x1, y1, z1, x2, y2, z2, center_x, center_y, center_z, radius),
        )

    @mcp.tool(name="designate_dig", annotations=WRITE_SAFE, description=DESIGNATE_DIG_DOC)
    def designate_dig(
        kind: str,
        x1: int | None = None,
        y1: int | None = None,
        z1: int | None = None,
        x2: int | None = None,
        y2: int | None = None,
        z2: int | None = None,
        center_x: int | None = None,
        center_y: int | None = None,
        center_z: int | None = None,
        radius: int | None = None,
    ) -> dict[str, Any]:
        if kind not in KINDS:
            raise ValueError(f"kind must be one of {', '.join(KINDS)}")
        return call(
            bridge,
            "dig.designate",
            _shape(kind, x1, y1, z1, x2, y2, z2, center_x, center_y, center_z, radius),
        )

    @mcp.tool(name="erase_designations", annotations=ERASE)
    def erase_designations(
        x1: int, y1: int, z1: int, x2: int, y2: int, z2: int, kind: str | None = None
    ) -> dict[str, Any]:
        """Remove dig, stair, channel, ramp, smooth, and engrave orders in a box (any size up
        to the whole map, clipped at its edge), cancelling
        any queued jobs for them, and chop and gather orders on trees and shrubs. Needs
        `dig_write`. `kind` limits it to one of mine, up_stair, down_stair, up_down_stair,
        channel, ramp, smooth, engrave, chop, gather. Already dug
        tiles are not changed. Check `list_designations` first so a staircase is not erased
        by accident.
        """
        if kind is not None and kind not in ERASE_KINDS:
            raise ValueError(f"kind must be one of {', '.join(ERASE_KINDS)}")
        return call(bridge, "dig.erase", _box(x1, y1, z1, x2, y2, z2, kind))
