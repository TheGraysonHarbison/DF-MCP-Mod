"""Minimal protobuf (proto2) wire codec for the DFHack core messages this project uses.

Only varint (wire type 0) and length-delimited (wire type 2) fields are needed, so this is
hand-rolled: no protoc step and no protobuf runtime dependency. Message layouts come from
``library/proto/CoreProtocol.proto`` in the DFHack repository (checked against ``develop``
on 2026-10-12). See docs/decisions/0002-protobuf-codec.md.
"""

from __future__ import annotations

from dataclasses import dataclass

WIRE_VARINT = 0
WIRE_FIXED64 = 1
WIRE_LENGTH = 2
WIRE_FIXED32 = 5


def encode_varint(value: int) -> bytes:
    """Encode an integer as a protobuf varint. Negative values are sign-extended to 64 bits."""
    if value < 0:
        value += 1 << 64
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def decode_varint(data: bytes, pos: int) -> tuple[int, int]:
    """Decode a varint starting at ``pos``. Returns (value, new_pos)."""
    result = 0
    shift = 0
    while True:
        if pos >= len(data):
            raise ValueError("truncated varint")
        byte = data[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7
        if shift > 70:
            raise ValueError("varint too long")


def to_int32(value: int) -> int:
    """Reinterpret a decoded varint as a signed 32-bit integer."""
    value &= 0xFFFFFFFF
    return value - (1 << 32) if value & 0x80000000 else value


def _tag(field_number: int, wire_type: int) -> bytes:
    return encode_varint((field_number << 3) | wire_type)


def encode_int32(field_number: int, value: int) -> bytes:
    return _tag(field_number, WIRE_VARINT) + encode_varint(value)


def encode_bytes(field_number: int, value: bytes) -> bytes:
    return _tag(field_number, WIRE_LENGTH) + encode_varint(len(value)) + value


def encode_string(field_number: int, value: str) -> bytes:
    return encode_bytes(field_number, value.encode("utf-8"))


def decode_fields(data: bytes) -> dict[int, list[int | bytes]]:
    """Split a message into ``{field_number: [values...]}``.

    Varints come back as ``int``; length-delimited and fixed-width fields come back as ``bytes``.
    """
    fields: dict[int, list[int | bytes]] = {}
    pos = 0
    end = len(data)
    while pos < end:
        key, pos = decode_varint(data, pos)
        field_number, wire_type = key >> 3, key & 7
        value: int | bytes
        if wire_type == WIRE_VARINT:
            value, pos = decode_varint(data, pos)
        elif wire_type == WIRE_LENGTH:
            length, pos = decode_varint(data, pos)
            if pos + length > end:
                raise ValueError("truncated length-delimited field")
            value = data[pos : pos + length]
            pos += length
        elif wire_type == WIRE_FIXED64:
            value = data[pos : pos + 8]
            pos += 8
        elif wire_type == WIRE_FIXED32:
            value = data[pos : pos + 4]
            pos += 4
        else:
            raise ValueError(f"unsupported wire type {wire_type}")
        if pos > end:
            raise ValueError("truncated fixed-width field")
        fields.setdefault(field_number, []).append(value)
    return fields


def _strings(fields: dict[int, list[int | bytes]], field_number: int) -> list[str]:
    return [bytes(v).decode("utf-8", errors="replace") for v in fields.get(field_number, [])]


# --- dfproto messages -------------------------------------------------------------------------


def encode_bind_request(
    method: str, input_msg: str, output_msg: str, plugin: str | None = None
) -> bytes:
    """dfproto.CoreBindRequest"""
    out = encode_string(1, method) + encode_string(2, input_msg) + encode_string(3, output_msg)
    if plugin:
        out += encode_string(4, plugin)
    return out


def decode_bind_reply(data: bytes) -> int:
    """dfproto.CoreBindReply -> assigned_id"""
    fields = decode_fields(data)
    values = fields.get(1)
    if not values:
        raise ValueError("CoreBindReply missing assigned_id")
    return to_int32(int(values[-1]))


def encode_run_command_request(command: str, arguments: list[str] | tuple[str, ...] = ()) -> bytes:
    """dfproto.CoreRunCommandRequest"""
    out = encode_string(1, command)
    for arg in arguments:
        out += encode_string(2, arg)
    return out


def encode_run_lua_request(
    module: str, function: str, arguments: list[str] | tuple[str, ...] = ()
) -> bytes:
    """dfproto.CoreRunLuaRequest"""
    out = encode_string(1, module) + encode_string(2, function)
    for arg in arguments:
        out += encode_string(3, arg)
    return out


def decode_string_list(data: bytes) -> list[str]:
    """dfproto.StringListMessage -> value[]"""
    return _strings(decode_fields(data), 1)


def decode_string_message(data: bytes) -> str:
    """dfproto.StringMessage -> value"""
    values = _strings(decode_fields(data), 1)
    return values[-1] if values else ""


def decode_int_message(data: bytes) -> int:
    """dfproto.IntMessage -> value"""
    values = decode_fields(data).get(1)
    return to_int32(int(values[-1])) if values else 0


@dataclass(frozen=True)
class TextFragment:
    text: str
    color: int | None = None


def decode_text_notification(data: bytes) -> list[TextFragment]:
    """dfproto.CoreTextNotification -> fragments[]"""
    fragments: list[TextFragment] = []
    for raw in decode_fields(data).get(1, []):
        inner = decode_fields(bytes(raw))
        text = _strings(inner, 1)
        color_values = inner.get(2)
        color = to_int32(int(color_values[-1])) if color_values else None
        fragments.append(TextFragment(text=text[-1] if text else "", color=color))
    return fragments
