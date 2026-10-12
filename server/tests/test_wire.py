import pytest

from df_mcp import wire


@pytest.mark.parametrize("value", [0, 1, 127, 128, 300, 2**31 - 1, -1, -2, -(2**31)])
def test_varint_roundtrip(value: int) -> None:
    encoded = wire.encode_varint(value)
    decoded, pos = wire.decode_varint(encoded, 0)
    assert pos == len(encoded)
    assert wire.to_int32(decoded) == value


def test_negative_int32_is_ten_bytes() -> None:
    # protobuf sign-extends negative int32 to 64 bits
    assert len(wire.encode_varint(-1)) == 10


def test_bind_request_fields() -> None:
    data = wire.encode_bind_request(
        "RunLua", "dfproto.CoreRunLuaRequest", "dfproto.StringListMessage"
    )
    fields = wire.decode_fields(data)
    assert fields[1] == [b"RunLua"]
    assert fields[2] == [b"dfproto.CoreRunLuaRequest"]
    assert fields[3] == [b"dfproto.StringListMessage"]
    assert 4 not in fields


def test_bind_request_with_plugin() -> None:
    fields = wire.decode_fields(wire.encode_bind_request("m", "i", "o", plugin="rename"))
    assert fields[4] == [b"rename"]


def test_bind_reply() -> None:
    assert wire.decode_bind_reply(wire.encode_int32(1, 17)) == 17


def test_run_lua_request_repeated_arguments() -> None:
    data = wire.encode_run_lua_request("rpc.claude_bridge", "dispatch", ["{}", "x"])
    fields = wire.decode_fields(data)
    assert fields[1] == [b"rpc.claude_bridge"]
    assert fields[2] == [b"dispatch"]
    assert fields[3] == [b"{}", b"x"]


def test_run_command_request() -> None:
    fields = wire.decode_fields(wire.encode_run_command_request("enable", ["claude-bridge"]))
    assert fields[1] == [b"enable"]
    assert fields[2] == [b"claude-bridge"]


def test_string_list_and_message() -> None:
    data = wire.encode_string(1, "a") + wire.encode_string(1, "bé")
    assert wire.decode_string_list(data) == ["a", "bé"]
    assert wire.decode_string_message(wire.encode_string(1, "v")) == "v"
    assert wire.decode_string_message(b"") == ""


def test_text_notification() -> None:
    frag1 = wire.encode_string(1, "hello ") + wire.encode_int32(2, 14)
    frag2 = wire.encode_string(1, "world")
    data = wire.encode_bytes(1, frag1) + wire.encode_bytes(1, frag2)
    frags = wire.decode_text_notification(data)
    assert frags == [wire.TextFragment("hello ", 14), wire.TextFragment("world", None)]


def test_decode_skips_fixed_width_fields() -> None:
    data = wire._tag(9, wire.WIRE_FIXED64) + b"\x00" * 8
    data += wire._tag(10, wire.WIRE_FIXED32) + b"\x00" * 4
    data += wire.encode_string(1, "ok")
    assert wire.decode_fields(data)[1] == [b"ok"]


def test_truncated_input_raises() -> None:
    with pytest.raises(ValueError):
        wire.decode_fields(wire.encode_string(1, "abc")[:-1])
    with pytest.raises(ValueError):
        wire.decode_varint(b"\x80", 0)
