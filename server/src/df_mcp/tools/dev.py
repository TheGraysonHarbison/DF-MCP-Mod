"""Dev-testing tools (plan section 13, Phase 12): create items, exterminate.

Each builds one DFHack console line and runs it through the console op, so the player's
console allowlist decides (`modtools/create-item`, `exterminate`). Nothing here bypasses the
bridge (CLAUDE.md rule 3). Unit spawning is not offered: `modtools/create-unit` (and the
`spawnunit` wrapper) fail on DFHack 53.16-r2 with "Cannot read field world.arena_spawn"
(seen live 2026-10-15), so it is a README open issue.
"""

from __future__ import annotations

import re
from typing import Any

from mcp.server import MCPServer
from mcp.types import ToolAnnotations

from df_mcp.bridge import Bridge
from df_mcp.tools import call

DEV = ToolAnnotations(read_only_hint=False, destructive_hint=True, open_world_hint=False)

METHODS = (
    "instant",
    "butcher",
    "magma",
    "drown",
    "vaporize",
    "disintegrate",
    "knockout",
    "traumatize",
)
TOKEN = re.compile(r"^[A-Za-z0-9_]+$")
ITEM_TOKEN = re.compile(r"^[A-Za-z0-9_]+(:[A-Za-z0-9_]+)*$")


def _token(value: str, what: str) -> str:
    value = value.strip().upper()
    if not TOKEN.match(value):
        raise ValueError(f"{what} must be a raw token such as DWARF or ITEM_WEAPON_PICK")
    return value


def _quote(text: str) -> str:
    cleaned = text.replace('"', "").replace("\n", " ").strip()
    if not cleaned:
        raise ValueError("text must not be empty")
    return f'"{cleaned}"'


def _run(bridge: Bridge, line: str) -> dict[str, Any]:
    result = call(bridge, "console.run", {"command": line})
    # DFHack guards scripts it has not validated for this DF version ("UNTESTED WARNING")
    # and asks for the same command again to proceed; do that once.
    if not result.get("ok") and "UNTESTED WARNING" in str(result.get("output", "")):
        warning = result["output"]
        result = call(bridge, "console.run", {"command": line})
        result["untested_warning"] = warning.strip()
    result["note"] = (
        "ran through the console allowlist; most of these commands print nothing on success, "
        "so check with list_units or find_items"
    )
    return result


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="dev_create_item", annotations=DEV)
    def dev_create_item(
        item: str,
        material: str,
        count: int = 1,
        quality: int = 0,
        x: int | None = None,
        y: int | None = None,
        z: int | None = None,
        unit_id: int | None = None,
    ) -> dict[str, Any]:
        """Dev testing only: create items with `modtools/create-item` (the player must have
        allowlisted that command). `item` is an item def such as WEAPON:ITEM_WEAPON_PICK,
        BOULDER:NONE, BAR:NONE, DRINK:NONE, TRAPPARTS:NONE; `material` a material def such
        as INORGANIC:IRON, INORGANIC:GRANITE, PLANT:OAK:WOOD, CREATURE:DWARF:BONE. `count`
        makes that many (a stack for stackable items), `quality` 0 (ordinary) to 5
        (masterwork). Items land at (x, y, z) when given, else at the creator's feet (the
        first citizen, or `unit_id`).
        """
        if not ITEM_TOKEN.match(item.strip()):
            raise ValueError("item must be an item def such as WEAPON:ITEM_WEAPON_PICK")
        if not ITEM_TOKEN.match(material.strip()):
            raise ValueError("material must be a material def such as INORGANIC:IRON")
        if count < 1 or count > 1000:
            raise ValueError("count must be 1 to 1000")
        if quality < 0 or quality > 5:
            raise ValueError("quality must be 0 to 5")
        pos = [x, y, z]
        if any(v is not None for v in pos) and any(v is None for v in pos):
            raise ValueError("give x, y, and z together")
        parts = ["modtools/create-item", "-i", item.strip().upper(), "-m", material.strip().upper()]
        if count != 1:
            parts += ["-c", str(count)]
        if quality:
            parts += ["-q", str(quality)]
        if x is not None:
            parts += ["-p", f"{x},{y},{z}"]
        if unit_id is not None:
            parts += ["-u", str(unit_id)]
        return _run(bridge, " ".join(parts))

    @mcp.tool(name="dev_exterminate", annotations=DEV)
    def dev_exterminate(
        target: str = "list",
        method: str = "instant",
        include_friendly: bool = False,
        only_visible: bool = False,
        limit: int | None = None,
    ) -> dict[str, Any]:
        """Dev testing only: kill units with `exterminate` (the player must have
        allowlisted it). `target` is "list" (just report what is on the map, the default),
        "undead", "all" (every non-friendly creature), or a race token with an optional
        caste (GOBLIN, BIRD_RAVEN:MALE). Only hostile and wild units die unless
        `include_friendly` is true, which also kills citizens and pets of that race, so
        leave it false unless the test needs it. `method` is instant, butcher, magma,
        drown, vaporize, disintegrate, knockout, or traumatize; `only_visible` skips hidden
        units; `limit` caps the kills.
        """
        target = target.strip()
        if target.lower() not in ("list", "undead", "all") and not ITEM_TOKEN.match(target):
            raise ValueError("target must be list, undead, all, or RACE[:CASTE]")
        if target.lower() == "this":
            raise ValueError("'this' needs an in-game selection; name a race instead")
        if method.lower() not in METHODS:
            raise ValueError(f"method must be one of {', '.join(METHODS)}")
        if limit is not None and limit < 1:
            raise ValueError("limit must be positive")
        if target.lower() == "list":
            return _run(bridge, "exterminate list")
        lowered = target.lower()
        if lowered == "undead":
            parts = ["exterminate", "undead"]
        elif lowered.startswith("all"):
            parts = ["exterminate", "all" + target[3:].upper()]
        else:
            parts = ["exterminate", target.upper()]
        if method.lower() != "instant":
            parts += ["--method", method.upper()]
        if include_friendly:
            parts.append("--include-friendly")
        if only_visible:
            parts.append("--only-visible")
        if limit is not None:
            parts += ["--limit", str(limit)]
        return _run(bridge, " ".join(parts))
