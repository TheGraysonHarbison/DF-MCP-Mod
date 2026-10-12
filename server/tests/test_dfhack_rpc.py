import pytest

from df_mcp import wire
from df_mcp.dfhack_rpc import (
    HEADER,
    ID_BIND_METHOD,
    RPC_REPLY_FAIL,
    RPC_REPLY_RESULT,
    RPC_REPLY_TEXT,
    RPC_REQUEST_QUIT,
    DFHackClient,
    RpcError,
    RpcProtocolError,
)


class FakeSocket:
    """Scripted socket: serves pre-queued bytes, records everything sent."""

    def __init__(self, inbound: bytes = b"") -> None:
        self.inbound = bytearray(inbound)
        self.sent = bytearray()
        self.closed = False
        self.timeout = None

    def settimeout(self, timeout):
        self.timeout = timeout

    def sendall(self, data: bytes) -> None:
        self.sent.extend(data)

    def recv(self, size: int) -> bytes:
        chunk = bytes(self.inbound[:size])
        del self.inbound[:size]
        return chunk

    def close(self) -> None:
        self.closed = True


def frame(reply_id: int, payload: bytes = b"", size: int | None = None) -> bytes:
    return HEADER.pack(reply_id, len(payload) if size is None else size) + payload


HANDSHAKE_OK = b"DFHack!\n" + (1).to_bytes(4, "little")


def make_client(inbound: bytes) -> tuple[DFHackClient, FakeSocket]:
    sock = FakeSocket(inbound)
    client = DFHackClient("h", 1, socket_factory=lambda addr, timeout: sock)
    return client, sock


def test_handshake_bytes() -> None:
    client, sock = make_client(HANDSHAKE_OK)
    client.connect()
    assert bytes(sock.sent) == b"DFHack?\n" + (1).to_bytes(4, "little")
    assert client.connected


def test_bad_handshake_drops_connection() -> None:
    client, sock = make_client(b"Nope!!!!" + (1).to_bytes(4, "little"))
    with pytest.raises(RpcProtocolError):
        client.connect()
    assert not client.connected
    assert sock.closed


def test_run_lua_binds_then_calls_and_collects_text() -> None:
    bind_reply = frame(RPC_REPLY_RESULT, wire.encode_int32(1, 42))
    text = frame(
        RPC_REPLY_TEXT,
        wire.encode_bytes(1, wire.encode_string(1, "log line")),
    )
    result = frame(RPC_REPLY_RESULT, wire.encode_string(1, '{"ok":true}'))
    client, sock = make_client(HANDSHAKE_OK + bind_reply + text + result)

    values = client.run_lua("rpc.claude_bridge", "dispatch", ["{}"])
    assert values == ['{"ok":true}']

    sent = bytes(sock.sent)[12:]  # skip handshake
    bind_id, bind_size = HEADER.unpack(sent[:8])
    assert bind_id == ID_BIND_METHOD
    bind_fields = wire.decode_fields(sent[8 : 8 + bind_size])
    assert bind_fields[1] == [b"RunLua"]
    call_id, call_size = HEADER.unpack(sent[8 + bind_size : 16 + bind_size])
    assert call_id == 42
    call_fields = wire.decode_fields(sent[16 + bind_size :])
    assert call_fields[3] == [b"{}"]

    # second call reuses the bound id without another BindMethod round trip
    sock.inbound.extend(frame(RPC_REPLY_RESULT, wire.encode_string(1, "x")))
    before = len(sock.sent)
    assert client.run_lua("rpc.claude_bridge", "dispatch", ["{}"]) == ["x"]
    new_id, _ = HEADER.unpack(bytes(sock.sent[before : before + 8]))
    assert new_id == 42


def test_fail_reply_raises_with_code_and_text() -> None:
    text = frame(RPC_REPLY_TEXT, wire.encode_bytes(1, wire.encode_string(1, "no such module")))
    client, _ = make_client(HANDSHAKE_OK + text + frame(RPC_REPLY_FAIL, size=3))
    with pytest.raises(RpcError) as info:
        client.run_command("whatever")
    assert info.value.code == 3
    assert "CR_NOT_FOUND" in str(info.value)
    assert "no such module" in str(info.value)


def test_closed_connection_raises_and_drops() -> None:
    client, sock = make_client(HANDSHAKE_OK)
    with pytest.raises(RpcProtocolError):
        client.run_command("ls")
    assert not client.connected
    assert sock.closed


def test_close_sends_quit() -> None:
    client, sock = make_client(HANDSHAKE_OK)
    client.connect()
    client.close()
    assert bytes(sock.sent)[-8:] == HEADER.pack(RPC_REQUEST_QUIT, 0)
    assert sock.closed


def test_get_version() -> None:
    bind_reply = frame(RPC_REPLY_RESULT, wire.encode_int32(1, 5))
    result = frame(RPC_REPLY_RESULT, wire.encode_string(1, "53.16-r2"))
    client, _ = make_client(HANDSHAKE_OK + bind_reply + result)
    assert client.get_version() == "53.16-r2"
