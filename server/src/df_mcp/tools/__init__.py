"""MCP tool modules. Each exposes ``register(mcp, bridge)``."""

from __future__ import annotations

import inspect
from typing import Any

from df_mcp.bridge import Bridge, BridgeError

try:  # the SDK's tool error type, if it exposes one
    from mcp.server.mcpserver.exceptions import ToolError
except ImportError:  # pragma: no cover

    class ToolError(RuntimeError):  # type: ignore[no-redef]
        pass


def call(bridge: Bridge, op: str, args: dict[str, Any] | None = None) -> Any:
    """Run an op and convert bridge failures into tool errors the client can show."""
    try:
        return bridge.call(op, args)
    except BridgeError as exc:
        raise ToolError(f"{exc.code}: {exc.message}") from exc


def tool_doc(*parts: str) -> str:
    """Join docstring-style parts into one tool description.

    A tool whose description is built from shared text must pass it as
    ``@mcp.tool(description=...)``: a string expression such as ``("text" + X)`` in the body
    is not a docstring, and the tool would reach the client without a description.
    """
    return "\n\n".join(inspect.cleandoc(p) for p in parts)
