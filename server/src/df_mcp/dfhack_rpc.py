"""Client for the DFHack remote server (protobuf messages over TCP, default port 5000).

Framing, from https://docs.dfhack.org/en/stable/docs/dev/Remote.html and
``library/include/RemoteClient.h`` (checked 2026-10-12, DFHack 53.16-r2):

* Handshake: client sends ``DFHack?\\n`` + int32 version 1; server answers ``DFHack!\\n`` + version.
* Every message is an 8-byte header ``<int16 id><2 pad><int32 size>`` followed by ``size`` bytes.
* A request is answered by zero or more TEXT messages, then exactly one RESULT or FAIL.
* FAIL carries the ``command_result`` code in the size field and no payload.

Method ids 0 (BindMethod) and 1 (RunCommand) are fixed; all others are obtained via BindMethod.
"""

from __future__ import annotations

import socket
import struct
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field

from df_mcp import wire

HANDSHAKE_REQUEST = b"DFHack?\n"
HANDSHAKE_RESPONSE = b"DFHack!\n"
HANDSHAKE_VERSION = 1

RPC_REPLY_RESULT = -1
RPC_REPLY_FAIL = -2
RPC_REPLY_TEXT = -3
RPC_REQUEST_QUIT = -4

ID_BIND_METHOD = 0
ID_RUN_COMMAND = 1

MAX_MESSAGE_SIZE = 64 * 1048576

HEADER = struct.Struct("<h2xi")
HANDSHAKE = struct.Struct("<8si")

COMMAND_RESULT_NAMES = {
    -3: "CR_LINK_FAILURE",
    -2: "CR_WOULD_BREAK",
    -1: "CR_NOT_IMPLEMENTED",
    0: "CR_OK",
    1: "CR_FAILURE",
    2: "CR_WRONG_USAGE",
    3: "CR_NOT_FOUND",
}
CR_OK = 0
CR_NOT_FOUND = 3


class RpcProtocolError(ConnectionError):
    """The server sent something that does not match the DFHack framing."""


class RpcError(Exception):
    """The server answered a request with a FAIL reply."""

    def __init__(self, code: int, text: Sequence[wire.TextFragment] = (), method: str = ""):
        self.code = code
        self.text = list(text)
        self.method = method
        name = COMMAND_RESULT_NAMES.get(code, str(code))
        output = "".join(f.text for f in self.text).strip()
        detail = f": {output}" if output else ""
        super().__init__(f"{method or 'request'} failed with {name}{detail}")


@dataclass
class Reply:
    payload: bytes
    text: list[wire.TextFragment] = field(default_factory=list)

    @property
    def output(self) -> str:
        return "".join(f.text for f in self.text)


SocketFactory = Callable[[tuple[str, int], float], socket.socket]


class DFHackClient:
    """One blocking connection to a DFHack remote server. Not thread-safe; callers serialise."""

    def __init__(
        self,
        host: str = "127.0.0.1",
        port: int = 5000,
        timeout: float = 30.0,
        socket_factory: SocketFactory = socket.create_connection,
    ) -> None:
        self.host = host
        self.port = port
        self.timeout = timeout
        self._socket_factory = socket_factory
        self._sock: socket.socket | None = None
        self._bound: dict[tuple[str, str, str, str | None], int] = {}

    # --- connection ---------------------------------------------------------------------------

    @property
    def connected(self) -> bool:
        return self._sock is not None

    def connect(self) -> None:
        if self._sock is not None:
            return
        sock = self._socket_factory((self.host, self.port), self.timeout)
        sock.settimeout(self.timeout)
        self._sock = sock
        try:
            self._send(HANDSHAKE.pack(HANDSHAKE_REQUEST, HANDSHAKE_VERSION))
            magic, version = HANDSHAKE.unpack(self._recv_exact(HANDSHAKE.size))
            if magic != HANDSHAKE_RESPONSE:
                raise RpcProtocolError(f"bad handshake magic {magic!r}")
            if version != HANDSHAKE_VERSION:
                raise RpcProtocolError(f"unsupported remote protocol version {version}")
        except Exception:
            self._drop()
            raise

    def close(self) -> None:
        if self._sock is None:
            return
        try:
            self._send(HEADER.pack(RPC_REQUEST_QUIT, 0))
        except OSError:
            pass
        self._drop()

    def _drop(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            finally:
                self._sock = None
        self._bound.clear()

    def __enter__(self) -> DFHackClient:
        self.connect()
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # --- raw io -------------------------------------------------------------------------------

    def _send(self, data: bytes) -> None:
        assert self._sock is not None
        self._sock.sendall(data)

    def _recv_exact(self, size: int) -> bytes:
        assert self._sock is not None
        chunks = bytearray()
        while len(chunks) < size:
            chunk = self._sock.recv(size - len(chunks))
            if not chunk:
                raise RpcProtocolError("connection closed by DFHack")
            chunks.extend(chunk)
        return bytes(chunks)

    # --- rpc ----------------------------------------------------------------------------------

    def call(self, method_id: int, payload: bytes = b"", method: str = "") -> Reply:
        """Send one request and collect its TEXT messages and RESULT payload."""
        self.connect()
        if len(payload) > MAX_MESSAGE_SIZE:
            raise ValueError("payload exceeds DFHack's 64 MiB message limit")
        try:
            self._send(HEADER.pack(method_id, len(payload)) + payload)
            text: list[wire.TextFragment] = []
            while True:
                reply_id, size = HEADER.unpack(self._recv_exact(HEADER.size))
                if reply_id == RPC_REPLY_TEXT:
                    text.extend(wire.decode_text_notification(self._recv_exact(size)))
                elif reply_id == RPC_REPLY_RESULT:
                    return Reply(payload=self._recv_exact(size), text=text)
                elif reply_id == RPC_REPLY_FAIL:
                    raise RpcError(size, text, method)
                else:
                    raise RpcProtocolError(f"unexpected reply id {reply_id}")
        except (OSError, RpcProtocolError):
            self._drop()
            raise

    def bind(self, method: str, input_msg: str, output_msg: str, plugin: str | None = None) -> int:
        key = (method, input_msg, output_msg, plugin)
        if key in self._bound:
            return self._bound[key]
        reply = self.call(
            ID_BIND_METHOD,
            wire.encode_bind_request(method, input_msg, output_msg, plugin),
            method="BindMethod",
        )
        assigned = wire.decode_bind_reply(reply.payload)
        self._bound[key] = assigned
        return assigned

    def run_command(self, command: str, arguments: Sequence[str] = ()) -> Reply:
        """Run a DFHack console command. Console output comes back in ``Reply.text``."""
        return self.call(
            ID_RUN_COMMAND,
            wire.encode_run_command_request(command, list(arguments)),
            method=f"RunCommand {command}",
        )

    def run_lua(self, module: str, function: str, arguments: Sequence[str] = ()) -> list[str]:
        """Call ``module.function(*arguments)`` in DFHack's Lua. Strings in, strings out."""
        method_id = self.bind("RunLua", "dfproto.CoreRunLuaRequest", "dfproto.StringListMessage")
        reply = self.call(
            method_id,
            wire.encode_run_lua_request(module, function, list(arguments)),
            method=f"RunLua {module}.{function}",
        )
        return wire.decode_string_list(reply.payload)

    def get_version(self) -> str:
        method_id = self.bind("GetVersion", "dfproto.EmptyMessage", "dfproto.StringMessage")
        return wire.decode_string_message(self.call(method_id, method="GetVersion").payload)

    def get_df_version(self) -> str:
        method_id = self.bind("GetDFVersion", "dfproto.EmptyMessage", "dfproto.StringMessage")
        return wire.decode_string_message(self.call(method_id, method="GetDFVersion").payload)
