from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE
from df_mcp.tools.orders import DELETE


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_workshops", annotations=READ_ONLY)
    def list_workshops(type: str | None = None, limit: int = 25, offset: int = 0) -> dict[str, Any]:
        """List the built workshops and furnaces on the map.

        Each row has the building `id` (use it with `get_workshop`), `kind` (workshop or
        furnace), `type` (Masons, Carpenters, Kitchen, Still, Smelter, ... or a custom
        building code), `name`, `custom_name`, `pos` and `bounds`, `built`, the number of
        queued `jobs`, whether a `strange_mood` has claimed it, and the item count.
        `type` filters to one type, e.g. "Kitchen"; `counts_by_type` always covers the map.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "workshops.list", {"type": type, "limit": limit, "offset": offset})

    @mcp.tool(name="get_workshop", annotations=READ_ONLY)
    def get_workshop(building_id: int, limit: int = 25) -> dict[str, Any]:
        """Inspect one workshop or furnace by building id.

        Returns the list row plus `jobs` (each with name, worker, flags such as suspend or
        repeat, the work order it came from, and whether it is a strange mood job),
        `inventory` (items sitting in the workshop, capped at `limit`), `materials` (the items
        it was built from), and its worker `profile`.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "workshops.get", {"id": building_id, "limit": limit})

    @mcp.tool(name="list_workshop_tasks", annotations=READ_ONLY)
    def list_workshop_tasks(
        building_id: int, query: str | None = None, limit: int = 25, offset: int = 0
    ) -> dict[str, Any]:
        """List what one workshop or furnace can make: its "Add new task" choices.

        Each task has a `label` (use it with `add_workshop_job`), the `job` token, an `item`
        `{id, name}` for tasks that make one kind of weapon, armor, tool, or toy, a `reaction`
        `{code, name}` for raw reactions (brewing, tanning, smelting alloys, custom shops),
        `needs_material` with the `materials` it takes in plain words ("wood", "stone",
        "a metal such as iron"), `direct` (false: only a work order can do it), and
        `unverified` when its item filters are not yet confirmed in play. `queued` and
        `max_jobs` (10) show room in the queue. `query` filters by label, job, item, or
        reaction; lists are capped at `limit`.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(
            bridge,
            "workshops.tasks",
            {"id": building_id, "query": query, "limit": limit, "offset": offset},
        )

    @mcp.tool(name="add_workshop_job", annotations=WRITE_SAFE)
    def add_workshop_job(
        building_id: int,
        job: str | None = None,
        reaction: str | None = None,
        item: str | None = None,
        material: str | None = None,
        repeat: bool = False,
        do_now: bool = False,
    ) -> dict[str, Any]:
        """Add a job straight to a workshop's queue, as the shop's "Add new task" button does.
        No manager or office is needed. Needs `orders_write`.

        `job` is a task label from `list_workshop_tasks` ("bed", "mechanisms", "pick"), or a
        job token when it is unique at that shop; `item` narrows a token with several rows
        (job "MakeTool", item "minecart"). `reaction` picks a raw reaction by code or name
        instead. `material` takes the same plain words as `create_work_order`: "any wood",
        "any stone", "granite", "iron", "cloth", "bone". Wood and stone shops default to any
        wood or any stone; forges, jewelers, glass furnaces, clothiers, craftsdwarfs, and
        smelting need one. `repeat` keeps the job queued after each item; `do_now` puts it
        first. Refused when the shop does not offer the task (the refusal lists what it
        does), when it is unbuilt or claimed by a strange mood, when its queue already
        holds 10 jobs, or when the material does not fit. Returns the new `job` with its id.
        """
        if (job is None) == (reaction is None):
            raise ValueError("give exactly one of job or reaction")
        return call(
            bridge,
            "workshops.add_job",
            {
                "id": building_id,
                "job": job,
                "reaction": reaction,
                "item": item,
                "material": material,
                "repeat": repeat,
                "do_now": do_now,
            },
        )

    @mcp.tool(name="set_workshop_job", annotations=WRITE_SAFE)
    def set_workshop_job(
        building_id: int,
        job_id: int,
        suspend: bool | None = None,
        repeat: bool | None = None,
        do_now: bool | None = None,
    ) -> dict[str, Any]:
        """Suspend or resume, repeat or not, and do-now or not one job in a workshop's queue
        (job ids come from `get_workshop`). Suspending a job a dwarf is working on makes the
        dwarf drop it. Strange mood jobs are refused. Needs `orders_write`.
        """
        if suspend is None and repeat is None and do_now is None:
            raise ValueError("pass at least one of suspend, repeat, do_now")
        return call(
            bridge,
            "workshops.set_job",
            {
                "id": building_id,
                "job_id": job_id,
                "suspend": suspend,
                "repeat": repeat,
                "do_now": do_now,
            },
        )

    @mcp.tool(name="cancel_workshop_job", annotations=DELETE)
    def cancel_workshop_job(building_id: int, job_id: int) -> dict[str, Any]:
        """Cancel one job in a workshop's queue (job ids come from `get_workshop`), even one a
        dwarf has started. Strange mood jobs are refused. When the job came from a work order
        the result names the `order`; the order itself stays. Needs `orders_write`.
        """
        return call(bridge, "workshops.cancel_job", {"id": building_id, "job_id": job_id})
