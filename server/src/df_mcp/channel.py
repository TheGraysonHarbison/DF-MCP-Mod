"""Claude Code channel: polls the mod's event queue and pushes batches as notifications.

Claude Code treats an MCP server that declares the experimental ``claude/channel``
capability as a channel and starts a turn (or queues until the current one ends) for every
``notifications/claude/channel`` notification it receives
(https://code.claude.com/docs/en/channels-reference, checked 2026-10-15). The session must
be started with ``claude --dangerously-load-development-channels server:dfhack`` while
custom channels are in research preview. The server keeps no buffer: it forwards each batch
the moment a poll returns one.
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from typing import Any

import anyio
from mcp.server import MCPServer
from mcp.server.stdio import stdio_server
from mcp.shared.message import SessionMessage
from mcp_types import METHOD_NOT_FOUND, ErrorData, JSONRPCError, JSONRPCNotification, JSONRPCRequest

from df_mcp.bridge import Bridge, BridgeError

log = logging.getLogger(__name__)

CHANNEL_CAPABILITY = {"claude/channel": {}}
NOTIFICATION_METHOD = "notifications/claude/channel"
POLL_SECONDS = 2.0
BACKOFF_SECONDS = 10.0
STARTUP_DELAY_SECONDS = 3.0
TEXT_LIMIT = 300


def format_batch(result: dict[str, Any]) -> tuple[str, dict[str, str]]:
    """Turn one ``events.poll`` result into channel content and meta attributes."""
    events: list[dict[str, Any]] = result.get("events") or []
    first = events[0]["seq"] if events else 0
    last = events[-1]["seq"] if events else 0
    kinds = sorted({str(e.get("kind")) for e in events})
    lines = [
        f"Dwarf Fortress events: {len(events)} (seq {first}-{last}, "
        f"game tick {result.get('tick')}). Read what matters with the dfhack tools, "
        "then act or note it in your plan."
    ]
    for e in events:
        text = str(e.get("text") or e.get("kind") or "").strip()
        if len(text) > TEXT_LIMIT:
            text = text[: TEXT_LIMIT - 3] + "..."
        parts = [f"- [{e.get('kind')}] {text}"]
        pos = e.get("pos")
        if isinstance(pos, dict) and "x" in pos:
            parts.append(f"at ({pos.get('x')},{pos.get('y')},{pos.get('z')})")
        units = e.get("unit_ids")
        if units:
            parts.append("units " + ",".join(str(u) for u in units))
        if e.get("item_id") is not None:
            parts.append(f"item {e['item_id']}")
        extra = e.get("extra")
        if isinstance(extra, dict) and extra.get("agreement_id") is not None:
            parts.append(f"agreement {extra['agreement_id']}")
        lines.append(" ".join(parts))
    remaining = result.get("remaining") or 0
    if remaining:
        lines.append(f"({remaining} more waiting; they follow in the next message.)")
    dropped = result.get("dropped") or 0
    if dropped:
        lines.append(f"(The mod's queue overflowed earlier; {dropped} events were lost.)")
    meta = {
        "kind": "events",
        "count": str(len(events)),
        "first_seq": str(first),
        "last_seq": str(last),
        "kinds": " ".join(kinds),
    }
    return "\n".join(lines), meta


def notification(content: str, meta: dict[str, str]) -> SessionMessage:
    return SessionMessage(
        JSONRPCNotification(
            jsonrpc="2.0", method=NOTIFICATION_METHOD, params={"content": content, "meta": meta}
        )
    )


class EventPoller:
    """Polls ``events.poll`` every few seconds and sends each ready batch as a notification."""

    def __init__(
        self,
        bridge: Bridge,
        send: Callable[[SessionMessage], Any],
        poll_seconds: float = POLL_SECONDS,
        startup_delay: float = STARTUP_DELAY_SECONDS,
    ) -> None:
        self.bridge = bridge
        self.send = send
        self.poll_seconds = poll_seconds
        self.startup_delay = startup_delay
        self.after_seq: int | None = None
        self.sent = 0

    def step(self) -> dict[str, Any] | None:
        """One poll in the calling thread; returns the result when a batch was ready."""
        if self.after_seq is None:
            result = self.bridge.call("events.poll", {})
            self.after_seq = int(result.get("next_seq", 1)) - 1
            return None
        result = self.bridge.call("events.poll", {"after_seq": self.after_seq})
        events = result.get("events") or []
        if not events:
            return None
        self.after_seq = int(result.get("last_seq", events[-1]["seq"]))
        return result

    async def run(self) -> None:
        await anyio.sleep(self.startup_delay)
        while True:
            delay = self.poll_seconds
            try:
                result = await anyio.to_thread.run_sync(self.step)
                if result is not None:
                    content, meta = format_batch(result)
                    await self.send(notification(content, meta))
                    self.sent += 1
                    log.info("channel: sent %s events (seq to %s)", meta["count"], meta["last_seq"])
                    if result.get("remaining"):
                        delay = 0.2
            except BridgeError as exc:
                log.debug("channel poll skipped: %s", exc)
                delay = BACKOFF_SECONDS
                if exc.code in ("MOD_NOT_ENABLED", "DISCONNECTED"):
                    self.after_seq = None
            except Exception:  # noqa: BLE001 - keep the poller alive whatever happens
                log.exception("channel poll failed")
                delay = BACKOFF_SECONDS
            await anyio.sleep(delay)


def is_pre_initialize_probe(item: Any, initialized: bool) -> JSONRPCRequest | None:
    """The request to refuse, if ``item`` is a non-initialize request before the handshake."""
    if initialized or not isinstance(item, SessionMessage):
        return None
    message = item.message
    if isinstance(message, JSONRPCRequest) and message.method != "initialize":
        return message
    return None


async def legacy_only(read_stream, write_stream, forward) -> None:
    """Relay ``read_stream`` into ``forward``, refusing modern-era probes before initialize.

    Claude Code opens with the 2026-07-28 ``server/discover`` probe when the server's SDK
    supports it, and a channel server that negotiates that revision is not registered as a
    channel (channels reference, checked 2026-10-15). Answering the probe with METHOD_NOT_FOUND,
    as a pre-2026 server would, makes the client fall back to the ``initialize`` handshake,
    which carries the capability and gives us the classic session.
    """
    initialized = False
    async with forward:
        async for item in read_stream:
            probe = is_pre_initialize_probe(item, initialized)
            if probe is not None:
                await write_stream.send(
                    SessionMessage(
                        JSONRPCError(
                            jsonrpc="2.0",
                            id=probe.id,
                            error=ErrorData(
                                code=METHOD_NOT_FOUND,
                                message=f"Method not found: {probe.method} (initialize first)",
                            ),
                        )
                    )
                )
                continue
            if isinstance(item, SessionMessage) and isinstance(item.message, JSONRPCRequest):
                if item.message.method == "initialize":
                    initialized = True
            await forward.send(item)


async def run_stdio_with_channel(mcp: MCPServer, bridge: Bridge) -> None:
    """Serve over stdio with the channel capability declared and the poller running."""
    lowlevel = mcp._lowlevel_server  # noqa: SLF001 - the SDK exposes no public hook for capabilities
    options = lowlevel.create_initialization_options(experimental_capabilities=CHANNEL_CAPABILITY)
    async with stdio_server() as (read_stream, write_stream):
        forward_send, forward_receive = anyio.create_memory_object_stream[Any](0)
        poller = EventPoller(bridge, write_stream.send)
        async with anyio.create_task_group() as tg:
            tg.start_soon(legacy_only, read_stream, write_stream, forward_send)
            tg.start_soon(poller.run)
            try:
                await lowlevel.run(forward_receive, write_stream, options)
            finally:
                tg.cancel_scope.cancel()
