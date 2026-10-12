"""JSON envelope over DFHack RunLua to the claude-bridge mod. See docs/protocol.md."""

from __future__ import annotations

import json
import logging
import threading
from collections.abc import Callable
from typing import Any

from df_mcp import PROTOCOL_VERSION
from df_mcp.dfhack_rpc import CR_NOT_FOUND, DFHackClient, RpcError

LUA_MODULE = "rpc.claude_bridge"
LUA_FUNCTION = "dispatch"

log = logging.getLogger(__name__)


class BridgeError(Exception):
    """An op failed. ``code`` is one of the protocol error codes or a transport code."""

    def __init__(self, code: str, message: str) -> None:
        self.code = code
        self.message = message
        super().__init__(f"{code}: {message}")


class Bridge:
    """Thread-safe, lazily connected, reconnecting wrapper around one DFHackClient."""

    def __init__(
        self,
        host: str = "127.0.0.1",
        port: int = 5000,
        client_factory: Callable[[str, int], DFHackClient] = DFHackClient,
    ) -> None:
        self.host = host
        self.port = port
        self._client_factory = client_factory
        self._client: DFHackClient | None = None
        self._lock = threading.Lock()
        self._next_id = 0

    def _ensure_client(self) -> DFHackClient:
        if self._client is None:
            client = self._client_factory(self.host, self.port)
            client.connect()
            self._client = client
            log.info("connected to DFHack at %s:%s", self.host, self.port)
        return self._client

    def _drop_client(self) -> None:
        if self._client is not None:
            try:
                self._client.close()
            except Exception:  # noqa: BLE001 - best effort during teardown
                pass
            self._client = None

    def close(self) -> None:
        with self._lock:
            self._drop_client()

    def call(self, op: str, args: dict[str, Any] | None = None) -> Any:
        """Run one op through the mod's dispatcher and return its ``result``."""
        with self._lock:
            self._next_id += 1
            request = json.dumps(
                {"op": op, "args": args or {}, "id": self._next_id, "v": PROTOCOL_VERSION}
            )
            try:
                client = self._ensure_client()
                values = client.run_lua(LUA_MODULE, LUA_FUNCTION, [request])
            except RpcError as exc:
                if exc.code == CR_NOT_FOUND:
                    raise BridgeError(
                        "MOD_NOT_ENABLED",
                        "The claude-bridge mod is not enabled in DFHack. "
                        "Run `enable claude-bridge` in the DFHack console.",
                    ) from exc
                raise BridgeError("RPC_FAILED", str(exc)) from exc
            except OSError as exc:
                self._drop_client()
                raise BridgeError(
                    "DISCONNECTED",
                    f"Could not reach DFHack at {self.host}:{self.port} ({exc}). "
                    "Is Dwarf Fortress running with DFHack?",
                ) from exc

        if not values:
            raise BridgeError("INTERNAL", "empty reply from dispatcher")
        try:
            response = json.loads(values[0])
        except json.JSONDecodeError as exc:
            raise BridgeError("INTERNAL", f"dispatcher returned invalid JSON: {exc}") from exc
        if not isinstance(response, dict):
            raise BridgeError("INTERNAL", "dispatcher returned a non-object response")
        if not response.get("ok"):
            error = response.get("error") or {}
            raise BridgeError(
                str(error.get("code", "INTERNAL")), str(error.get("message", "unknown error"))
            )
        return response.get("result")

    def console(self, command: str) -> Any:
        """Convenience wrapper for the ``console.run`` op."""
        return self.call("console.run", {"command": command})
