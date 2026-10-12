# 0002: Hand-rolled protobuf codec instead of generated code

Date: 2026-10-12. Status: accepted.

## Context

DFHack's remote protocol uses protobuf messages. The usual route is `protoc` plus the `protobuf` runtime. The dev machine (Bazzite) has no `protoc`, the only existing Python client is unmaintained, and we use five tiny messages with string and int32 fields only.

## Decision

`server/src/df_mcp/wire.py` implements varint and length-delimited encoding by hand and exposes one encode or decode function per message we use. Field numbers are copied from `library/proto/CoreProtocol.proto` and cited in the module docstring.

## Consequences

- Zero build step and one fewer dependency.
- If we ever need a plugin's richer messages (for example `RemoteFortressReader`), revisit and generate code for those.
