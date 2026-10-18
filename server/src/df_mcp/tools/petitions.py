"""Petitions (Patch 2 item P2-6.0): list pending petitions and accept or deny one."""

from __future__ import annotations

import time
from typing import Any

from mcp.server import MCPServer

from df_mcp.bridge import Bridge
from df_mcp.tools import call
from df_mcp.tools.core import READ_ONLY, WRITE_SAFE

# `petitions.answer` drives the game's petitions screen in stages (open, select, press,
# verify): the screen text is read from the last frame the game drew, so the op returns
# `done: false` until the game has drawn the next stage and the tool calls it again.
STEP_DELAY_S = 0.25
MAX_STEPS = 24


def register(mcp: MCPServer, bridge: Bridge) -> None:
    @mcp.tool(name="list_petitions", annotations=READ_ONLY)
    def list_petitions(limit: int = 25, include_resolved: bool = False) -> dict[str, Any]:
        """List the petitions waiting for an answer, plus the fort's temples and guildhalls.

        Petitions are residency requests (monster hunters, mercenaries, scholars,
        performers, refugees seeking sanctuary), citizenship requests, and requests to
        establish a temple or guildhall. A `petition` event announces each new one. Each row:
        `id` (pass it to `answer_petition`), `kind` (residency, citizenship, location),
        `status` (pending; with `include_resolved` also accepted, denied, satisfied,
        expired), `summary`, `applicant` (`name`, `figures` with `hist_figure_id`,
        `unit_id` and `on_map` when the petitioner is on the map, `profession`; `entities`
        for a religion, guild, or troupe), `reason` (residency: eradicate_beasts,
        make_a_living_as_a_warrior, study, entertain_people, seek_sanctuary, ...),
        `location` (`type` temple or guildhall, `tier` 1 or 2, `name`, `deity` or
        `profession`), `made` (year, tick), `age_days`, `days_left_estimate` (one-year rule
        of DFHack's list-agreements; the game's own timeout is not verified),
        `standing_order` (the game's automatic answer for this group, meaning unverified).
        Also `standing_orders`, `locations` (the fort's temples and guildhalls with deity or
        profession and tier) so you can tell whether a request is already met, `count`,
        `truncated`, and `resolved`, `resolved_count`, `resolved_truncated` with
        `include_resolved`. Needs `units`.
        """
        if limit < 1:
            raise ValueError("limit must be at least 1")
        return call(
            bridge,
            "petitions.list",
            {"limit": limit, "include_resolved": bool(include_resolved)},
        )

    @mcp.tool(name="answer_petition", annotations=WRITE_SAFE)
    def answer_petition(
        id: int,
        accept: bool,
        unpause: bool = False,
        dry_run: bool = False,
        screen_check: bool = False,
    ) -> dict[str, Any]:
        """Accept or deny one pending petition (`id` from `list_petitions`).

        Needs `units_write` and `screens_write`: the bridge answers through the game's own
        petitions screen (clicks PETITIONS on the main screen, selects the petition, presses
        Approve or Deny, checks the agreement, closes the screen), so the game does its own
        bookkeeping. Accepting a residency keeps the visitor as a resident, citizenship
        makes them a citizen, a location request promises a temple or guildhall to build.
        This path is not yet verified in a live game: read `verified` and `reason`, and
        tell the player when `verified` is false. `dry_run=True` only describes what would
        happen and what blocks it, touching nothing; add `screen_check=True` to also open
        the screen, find the button, and close it without pressing. Pass `unpause=True`
        with `pause_write` to let the game run afterwards. Errors: `NOT_FOUND` for an id
        that is not pending, no PETITIONS button, or no one to hear petitions (appoint the
        noble first); `SCREEN_BUSY` when the player has a menu or the petitions screen
        open; `NOT_ALLOWED` without `screens_write`. Returns `answered`, `verified`,
        `outcome` (accepted, denied, gone, pending), `petition`, `effects`, `clicked`,
        `in_continuing`, `screen_closed`, `unpaused`, `paused`, `note`.
        """
        if isinstance(id, bool) or not isinstance(id, int):
            raise ValueError("id must be an integer petition id")
        if not isinstance(accept, bool):
            raise ValueError("accept must be true or false")
        args: dict[str, Any] = {
            "id": id,
            "accept": accept,
            "unpause": bool(unpause),
            "dry_run": bool(dry_run or screen_check),
            "screen": bool(screen_check),
        }
        result = call(bridge, "petitions.answer", args)
        steps = 0
        while isinstance(result, dict) and result.get("done") is False:
            if steps >= MAX_STEPS:
                ended = call(bridge, "petitions.answer", {"cancel": True})
                pressed = isinstance(ended, dict) and ended.get("answered") is True
                return {
                    "done": True,
                    "answered": pressed,
                    "verified": False,
                    "id": id,
                    "accept": accept,
                    "reason": f"the petitions screen did not reach the answer after {steps} steps "
                    f"(last stage {result.get('stage')}); the bridge's screen was closed",
                    "cancel": ended,
                }
            steps += 1
            time.sleep(STEP_DELAY_S)
            result = call(bridge, "petitions.answer", {**args, "continue": True})
        return result
