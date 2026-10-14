from __future__ import annotations

from typing import Any

from mcp.server import MCPServer
from mcp.types import ToolAnnotations

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE

FREQUENCIES = ("OneTime", "Daily", "Monthly", "Seasonally", "Yearly")

DELETE = ToolAnnotations(
    read_only_hint=False, destructive_hint=True, idempotent_hint=True, open_world_hint=False
)


def _check_frequency(frequency: str | None) -> None:
    if frequency is not None and frequency not in FREQUENCIES:
        raise ValueError(f"frequency must be one of {', '.join(FREQUENCIES)}")


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_work_orders", annotations=READ_ONLY)
    def list_work_orders(
        query: str | None = None,
        approved: bool | None = None,
        limit: int = 25,
        offset: int = 0,
    ) -> dict[str, Any]:
        """List the manager's work orders.

        Each order has `id`, `label` (the text the Work Orders screen shows), `job` and
        `job_name`, the item and material it makes, `amount`
        `{left, total, unlimited}`, `frequency`, `status {validated, active}`, `approved`
        (validated by the manager; Claude never approves orders), `max_workshops`, and its
        item and order `conditions` as readable text. `query` matches job, item, material,
        or reaction names; `approved` filters by manager validation.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(
            bridge,
            "orders.list",
            {"query": query, "approved": approved, "limit": limit, "offset": offset},
        )

    @mcp.tool(name="get_work_order", annotations=READ_ONLY)
    def get_work_order(order_id: int) -> dict[str, Any]:
        """Get one work order by id, with its conditions and the `raw` material and item
        fields (`mat_type`, `mat_index`, `item_type`, `item_subtype`) for diagnosis."""
        return call(bridge, "orders.get", {"id": order_id})

    @mcp.tool(name="find_job_types", annotations=READ_ONLY)
    def find_job_types(query: str, limit: int = 25) -> dict[str, Any]:
        """Search the job types and custom reactions a work order can use.

        Returns `jobs` (`job` token, `caption`, default `item`, `possible_items`, `skill`)
        and `reactions` (`reaction` code, `name`, `buildings`) whose names contain `query`,
        e.g. "chair", "brew", "smelt". Use the `job` token or `reaction` code with
        `create_work_order`.
        """
        if not query or not query.strip():
            raise ValueError("query must be a non-empty string")
        return call(bridge, "orders.jobs", {"query": query, "limit": limit})

    @mcp.tool(name="create_work_order", annotations=WRITE_SAFE)
    def create_work_order(
        job: str | None = None,
        reaction: str | None = None,
        amount: int = 1,
        item_type: str | None = None,
        item_subtype: str | None = None,
        material: str | None = None,
        material_category: list[str] | None = None,
        frequency: str = "OneTime",
        max_workshops: int = 0,
        workshop_id: int | None = None,
    ) -> dict[str, Any]:
        """Create a work order for the manager to approve. Needs `orders_write`.

        Give either `job` (a token or caption from `find_job_types`, e.g. ConstructThrone
        or "Make Crafts") or `reaction` (a reaction code such as BREW_DRINK or SMELT_IRON).
        `amount` 0 means unlimited. `material` is a plain word: "any stone" for bulk stone
        goods (blocks, doors, tables), "any wood" for wooden ones, or a specific material
        such as "granite", "silver", or "steel" when value or function matters. Raw tokens
        (INORGANIC:IRON, PLANT:PLUMP_HELMET:DRINK) also work. Orders with no material at all
        are refused because the game would list them as "unknown material"; jobs that take
        no material (reactions, meals) are fine without one. `item_subtype` picks what to
        make for jobs with variants (MakeWeapon with "pick"); `item_type` is only needed to
        override the job's default item. `material_category` is an optional list of job
        material flags (wood, bone, shell, cloth, ...). `frequency` is OneTime, Daily,
        Monthly, Seasonally, or Yearly. `max_workshops` 0 is unlimited; `workshop_id` pins
        the order to one workshop. The returned order carries `label`, the text the Work
        Orders screen shows. The order starts unapproved; only the manager validates it.
        """
        if (job is None) == (reaction is None):
            raise ValueError("give exactly one of job or reaction")
        if amount < 0:
            raise ValueError("amount must be 0 (unlimited) or more")
        _check_frequency(frequency)
        if max_workshops < 0:
            raise ValueError("max_workshops must be 0 or more")
        return call(
            bridge,
            "orders.create",
            {
                "job": job,
                "reaction": reaction,
                "amount": amount,
                "item_type": item_type,
                "item_subtype": item_subtype,
                "material": material,
                "material_category": material_category,
                "frequency": frequency,
                "max_workshops": max_workshops,
                "workshop_id": workshop_id,
            },
        )

    @mcp.tool(name="edit_work_order", annotations=WRITE_SAFE)
    def edit_work_order(
        order_id: int,
        amount: int | None = None,
        frequency: str | None = None,
        max_workshops: int | None = None,
        workshop_id: int | None = None,
    ) -> dict[str, Any]:
        """Change a work order's amount, frequency, workshop limit, or pinned workshop
        (-1 clears it). Needs `orders_write`. Approval is the manager's and cannot be set.
        """
        if amount is None and frequency is None and max_workshops is None and workshop_id is None:
            raise ValueError("pass at least one of amount, frequency, max_workshops, workshop_id")
        _check_frequency(frequency)
        return call(
            bridge,
            "orders.edit",
            {
                "id": order_id,
                "amount": amount,
                "frequency": frequency,
                "max_workshops": max_workshops,
                "workshop_id": workshop_id,
            },
        )

    @mcp.tool(name="delete_work_order", annotations=DELETE)
    def delete_work_order(order_id: int) -> dict[str, Any]:
        """Delete a work order. Needs `orders_write`. Returns the order as it was."""
        return call(bridge, "orders.delete", {"id": order_id})
