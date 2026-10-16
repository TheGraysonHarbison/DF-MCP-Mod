from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE

MODES = ("everybody", "nobody", "only_selected")


def _detail(detail: str) -> str:
    if not detail or not detail.strip():
        raise ValueError("detail must be a work detail name or its 1-based index")
    return detail.strip()


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_work_details", annotations=READ_ONLY)
    def list_work_details(detail: str | None = None, limit: int = 25) -> dict[str, Any]:
        """List the fort's work details: the game's Labor screen, which decides who does what.

        Each detail has `index` (1-based), `name`, `mode`, `labors` (the labors it grants),
        `members` (`id`, `name`, `profession`, capped at `limit`, with `member_count` and
        `members_truncated`), `locked` (a game default detail), and `cannot_be_everybody`.
        `mode` is `everybody` (every adult citizen does its labors, members do not matter),
        `nobody`, or `only_selected` (only the members do them). A new fort's Miners,
        Woodcutters, Hunters, and Fisherdwarves are `only_selected` and their members need a
        pick, axe, or crossbow; Planters, Plant gatherers, Stonecutters, Engravers, Haulers,
        Orderlies, and Siege operators default to `everybody`. `detail` narrows the answer to
        one detail by index, name, or unique part of a name. `children_do_chores` says whether
        children help with chores.
        """
        if limit < 1:
            raise ValueError("limit must be 1 or greater")
        args: dict[str, Any] = {"limit": limit}
        if detail is not None and detail.strip():
            args["detail"] = detail.strip()
        return call(bridge, "labor.details", args)

    @mcp.tool(name="assign_work_detail", annotations=WRITE_SAFE)
    def assign_work_detail(
        detail: str, add: list[int] | None = None, remove: list[int] | None = None
    ) -> dict[str, Any]:
        """Put citizens on a work detail or take them off it; the game then updates their labors.

        `detail` is a name or 1-based index from `list_work_details`. `add` and `remove` are
        unit ids (from `list_citizens` or `find_unit`); give at least one. Only living adult
        citizens can be added: children, babies, visitors, the dead, and units already on the
        detail are skipped with a reason. Any member can be removed, including dead, departed,
        or child units left on a detail; only ids not on it are skipped. Membership only
        matters when the detail's mode is `only_selected`; on an `everybody` or `nobody`
        detail the result's note says so. Members of Miners, Woodcutters, and Hunters need a
        pick, axe, or crossbow, and a dwarf in both Miners and Woodcutters keeps swapping tools
        and wastes time, so keep those two groups apart. This changes the game and needs the
        `labor_write` permission, off by default. Returns `added`, `removed`, `skipped`,
        `recomputed`, and `labors_after` (each touched unit's labors after the change).
        """
        add = add or []
        remove = remove or []
        if not add and not remove:
            raise ValueError("give unit ids in add, remove, or both")
        return call(
            bridge, "labor.assign", {"detail": _detail(detail), "add": add, "remove": remove}
        )

    @mcp.tool(name="set_work_detail_mode", annotations=WRITE_SAFE)
    def set_work_detail_mode(detail: str, mode: str) -> dict[str, Any]:
        """Set who does a work detail's labors: `everybody`, `nobody`, or `only_selected`.

        `detail` is a name or 1-based index from `list_work_details`. `only_selected` hands the
        labors to the detail's members only (put them on with `assign_work_detail` first, or
        nobody does the work); `nobody` stops the labors fort-wide; `everybody` gives them to
        every adult citizen. Details marked `cannot_be_everybody` (Miners, Woodcutters,
        Hunters, Fisherdwarves) refuse `everybody` because their labor needs a tool. Every
        citizen's labors are recomputed. This changes the game and needs the `labor_write`
        permission, off by default. Returns `before`, `after`, and `recomputed_citizens`.
        """
        word = mode.strip().lower() if mode else ""
        if word not in MODES:
            raise ValueError(f"mode must be one of {', '.join(MODES)}")
        return call(bridge, "labor.set_mode", {"detail": _detail(detail), "mode": word})
