from __future__ import annotations

from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE

BUCKETS = ("citizen", "domesticated", "other")

KINDS = {
    "citizen": ("citizen", "resident"),
    "domesticated": ("pet", "war_animal", "hunting_animal", "livestock", "stray"),
    "other": (
        "visitor",
        "merchant",
        "diplomat",
        "invader",
        "undead",
        "wildlife",
        "agitated",
        "hostile",
        "other",
    ),
}


# Tabs and sub-tabs of the in-game unit profile. Mirrors CATEGORIES in sheet.lua.
SHEET_CATEGORIES: dict[str, tuple[str, ...]] = {
    "overview": (),
    "relations": (),
    "groups": (),
    "military": ("squads", "uniform", "kills"),
    "thoughts": ("recent", "memories"),
    "personality": ("traits", "values", "preferences", "needs"),
    "items": (),
    "health": ("status", "wounds", "treatment", "history", "description"),
    "skills": ("labor", "combat", "social", "other", "knowledge"),
    "rooms": (),
    "labor": ("work_details", "workshops", "locations", "work_animals"),
}


def _check_bucket(bucket: str | None) -> None:
    if bucket is not None and bucket not in BUCKETS:
        raise ValueError(f"bucket must be one of {', '.join(BUCKETS)}")


def _check_kind(bucket: str | None, kind: str | None) -> None:
    if kind is None:
        return
    allowed = KINDS[bucket] if bucket else tuple(k for ks in KINDS.values() for k in ks)
    if kind not in allowed:
        raise ValueError(f"kind must be one of {', '.join(allowed)}")


def _list(
    bridge: Bridge,
    bucket: str | None,
    kind: str | None,
    include_dead: bool,
    limit: int,
    offset: int,
) -> dict[str, Any]:
    _check_bucket(bucket)
    _check_kind(bucket, kind)
    return call(
        bridge,
        "units.list",
        {
            "bucket": bucket,
            "kind": kind,
            "include_dead": include_dead,
            "limit": limit,
            "offset": offset,
        },
    )


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_units", annotations=READ_ONLY)
    def list_units(
        bucket: str | None = None,
        kind: str | None = None,
        include_dead: bool = False,
        limit: int = 200,
        offset: int = 0,
    ) -> dict[str, Any]:
        """List every unit on the map, optionally filtered to one bucket or kind.

        `bucket` is citizen, domesticated, or other; omit it for everything. `kind` narrows
        further (citizen: citizen, resident; domesticated: pet, war_animal, hunting_animal,
        livestock, stray; other: visitor, merchant, diplomat, invader, undead, wildlife,
        agitated, hostile, other). Results are paged with `limit` and `offset`.
        `counts_by_bucket` and `counts_by_kind` always cover the whole map. Each row has
        `id` (the key every other unit tool takes), `name`, `unit` (the bucket), `kind`,
        `gender`, `creature`, and `mood`, or `owner` for domesticated animals.
        """
        return _list(bridge, bucket, kind, include_dead, limit, offset)

    @mcp.tool(name="list_citizens", annotations=READ_ONLY)
    def list_citizens(
        kind: str | None = None, include_dead: bool = False, limit: int = 200, offset: int = 0
    ) -> dict[str, Any]:
        """List the fort's citizens and long-term residents, the permanent population.

        `kind` may be citizen or resident. Each row has `id` (the key every other unit tool
        takes), `name`, `unit`, `kind`, `gender`, `creature`, and `mood` (miserable,
        unhappy, displeased, content, pleased, happy, ecstatic).
        """
        return _list(bridge, "citizen", kind, include_dead, limit, offset)

    @mcp.tool(name="list_domesticated", annotations=READ_ONLY)
    def list_domesticated(
        kind: str | None = None, include_dead: bool = False, limit: int = 200, offset: int = 0
    ) -> dict[str, Any]:
        """List the fort's animals: pets, livestock, war and hunting animals, strays.

        `kind` may be pet, war_animal, hunting_animal, livestock, or stray. Each row has
        `id` (the key every other unit tool takes), `name`, `unit`, `kind`, `gender`,
        `creature`, and `owner` (the pet owner's name or "None").
        """
        return _list(bridge, "domesticated", kind, include_dead, limit, offset)

    @mcp.tool(name="list_others", annotations=READ_ONLY)
    def list_others(
        kind: str | None = None, include_dead: bool = False, limit: int = 200, offset: int = 0
    ) -> dict[str, Any]:
        """List every unit that is not part of the fort: visitors, merchants, enemies, wildlife.

        `kind` may be visitor, merchant, diplomat, invader, undead, wildlife, agitated,
        hostile, or other. Each row has `id` (the key every other unit tool takes), `name`,
        `unit`, `kind`, `gender`, `creature`, and `mood`.
        """
        return _list(bridge, "other", kind, include_dead, limit, offset)

    @mcp.tool(name="find_unit", annotations=READ_ONLY)
    def find_unit(
        query: str, bucket: str | None = None, limit: int = 20, include_dead: bool = False
    ) -> dict[str, Any]:
        """Find units by name, nickname, or description and get their ids.

        The match is a case-insensitive substring against the unit's native name, English
        name, nickname, creature name, and readable name (which includes the profession, so
        "cat" or "mason" work). Use the returned `id` with `get_unit`.
        """
        if not query or not query.strip():
            raise ValueError("query must be a non-empty string")
        _check_bucket(bucket)
        return call(
            bridge,
            "units.find",
            {"query": query, "bucket": bucket, "limit": limit, "include_dead": include_dead},
        )

    @mcp.tool(name="get_unit", annotations=READ_ONLY)
    def get_unit(unit_id: int) -> dict[str, Any]:
        """Get basic info for one unit by id.

        Returns the list row plus nickname, caste, profession, age, position, current job,
        historical figure id, squad, and flags. Ids come from the list tools or `find_unit`.
        """
        return call(bridge, "units.get", {"id": unit_id})

    @mcp.tool(name="set_unit_nickname", annotations=WRITE_SAFE)
    def set_unit_nickname(unit_id: int, nickname: str) -> dict[str, Any]:
        """Give a unit a nickname, or clear it with an empty string.

        This changes the game. It needs the `units_write` permission, which the player turns
        on in `claude-bridge settings`; it is off by default. Returns the unit's updated name.
        """
        if len(nickname) > 64:
            raise ValueError("nickname is limited to 64 characters")
        return call(bridge, "units.set_nickname", {"id": unit_id, "nickname": nickname})

    @mcp.tool(name="get_unit_sheet", annotations=READ_ONLY)
    def get_unit_sheet(
        unit_id: int, category: str, subcategory: str | None = None, limit: int = 50
    ) -> dict[str, Any]:
        """Read one tab of a unit's in-game profile sheet.

        `category` is one of overview, relations, groups, military, thoughts, personality,
        items, health, skills, rooms, labor. Tabs with sub-tabs take an optional
        `subcategory` (military: squads, uniform, kills; thoughts: recent, memories;
        personality: traits, values, preferences, needs; health: status, wounds, treatment,
        history, description; skills: labor, combat, social, other, knowledge; labor:
        work_details, workshops, locations, work_animals); omit it to get every sub-tab.
        Every list is cut at `limit` entries and reports `total` and `truncated`. The
        response lists which sections hit the cap (`truncated`) and which are incomplete
        reconstructions (`best_effort`).
        """
        if category not in SHEET_CATEGORIES:
            raise ValueError(f"category must be one of {', '.join(SHEET_CATEGORIES)}")
        subs = SHEET_CATEGORIES[category]
        if subcategory is not None:
            if not subs:
                raise ValueError(f"category {category} has no sub-categories")
            if subcategory not in subs:
                raise ValueError(f"subcategory for {category} must be one of {', '.join(subs)}")
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(
            bridge,
            "units.sheet",
            {"id": unit_id, "category": category, "subcategory": subcategory, "limit": limit},
        )

    @mcp.tool(name="get_unit_full_sheet", annotations=READ_ONLY)
    def get_unit_full_sheet(unit_id: int, limit: int = 50) -> dict[str, Any]:
        """Read a unit's whole profile sheet, every tab and sub-tab, in one call.

        Large for a veteran dwarf. Every list is cut at `limit` entries; `truncated` names
        the sections that were cut, so follow up with `get_unit_sheet` on those. `best_effort`
        names sections that are incomplete reconstructions.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(bridge, "units.full_sheet", {"id": unit_id, "limit": limit})
