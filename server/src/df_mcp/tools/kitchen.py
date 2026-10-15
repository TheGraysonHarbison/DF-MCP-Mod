from __future__ import annotations

from typing import Any

from mcp.server import MCPServer
from mcp.types import ToolAnnotations

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY

CATEGORIES = ("plants", "seeds", "drinks", "other")

WRITE = ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=True)


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_kitchen", annotations=READ_ONLY)
    def list_kitchen(
        category: str | None = None,
        query: str | None = None,
        banned_only: bool = False,
        limit: int = 25,
    ) -> dict[str, Any]:
        """List the fort's kitchen preferences: every ingredient in stock and whether the
        game may cook it and brew it, grouped like the Kitchen screen (plants, seeds, drinks,
        other).

        Each row has `key` (pass it to `set_kitchen`), `name`, `material` token, `item_type`,
        `cookable` and `brewable` (what the ingredient allows at all), `cook` and `brew` (what
        the game will do now), `cook_banned` and `brew_banned`, and the `count` and
        `quantity` in stock. Only ingredients in stock are listed, as in the game. Cooking a
        plant destroys its seeds, so ban cooking on crops you want to keep planting; brewing
        returns the seeds. `category` narrows to one tab, `query` to names containing the
        text, `banned_only` to rows with a ban; `limit` caps rows per category.
        """
        if category is not None and category not in CATEGORIES:
            raise ValueError(f"category must be one of {', '.join(CATEGORIES)}")
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(
            bridge,
            "kitchen.list",
            {"category": category, "query": query, "banned_only": banned_only, "limit": limit},
        )

    @mcp.tool(name="set_kitchen", annotations=WRITE)
    def set_kitchen(
        cook: bool | None = None,
        brew: bool | None = None,
        key: str | None = None,
        item_type: str | None = None,
        material: str | None = None,
        subtype: int | None = None,
    ) -> dict[str, Any]:
        """Allow or ban cooking and brewing of one ingredient, as the Kitchen screen does.
        Needs the `kitchen_write` permission.

        Name the ingredient with `key` from `list_kitchen`, or with `item_type` (PLANT,
        SEEDS, DRINK, PLANT_GROWTH, MEAT, CHEESE, ...) plus `material` (a plant or creature
        name such as "plump helmet", or a material token such as
        PLANT_MAT:MUSHROOM_HELMET_PLUMP:STRUCTURAL) and, for growths, `subtype`. The second
        form also works for ingredients not yet in stock. Pass `cook` and/or `brew` as true
        (allow) or false (ban). Returns `changed`, `before`, `after`, and `warnings`.
        """
        if cook is None and brew is None:
            raise ValueError("pass cook and/or brew")
        if key is None and (item_type is None or material is None):
            raise ValueError("pass key, or item_type with material")
        args: dict[str, Any] = {"cook": cook, "brew": brew}
        if key is not None:
            args["key"] = key
        else:
            args["item_type"] = item_type
            args["material"] = material
            if subtype is not None:
                args["subtype"] = subtype
        return call(bridge, "kitchen.set", args)
