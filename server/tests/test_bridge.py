import json

import pytest

from df_mcp import PROTOCOL_VERSION
from df_mcp.bridge import Bridge, BridgeError
from df_mcp.dfhack_rpc import RpcError


class FakeClient:
    def __init__(self, host, port, replies=None, error=None):
        self.host, self.port = host, port
        self.replies = list(replies or [])
        self.error = error
        self.calls = []
        self.connected = False
        self.closed = False

    def connect(self):
        self.connected = True

    def close(self):
        self.closed = True

    def run_lua(self, module, function, args):
        self.calls.append((module, function, list(args)))
        if self.error:
            raise self.error
        return self.replies.pop(0)


def make_bridge(replies=None, error=None):
    holder = {}

    def factory(host, port):
        holder["client"] = FakeClient(host, port, replies, error)
        return holder["client"]

    return Bridge("h", 1, client_factory=factory), holder


def test_call_sends_envelope_and_unwraps_result():
    bridge, holder = make_bridge([[json.dumps({"ok": True, "result": {"a": 1}, "id": 1})]])
    assert bridge.call("core.ping") == {"a": 1}
    module, function, args = holder["client"].calls[0]
    assert (module, function) == ("rpc.claude_bridge", "dispatch")
    request = json.loads(args[0])
    assert request["op"] == "core.ping"
    assert request["args"] == {}
    assert request["id"] == 1
    assert request["v"] == PROTOCOL_VERSION


def test_error_response_becomes_bridge_error():
    reply = json.dumps({"ok": False, "error": {"code": "NO_MAP", "message": "x"}})
    bridge, _ = make_bridge([[reply]])
    with pytest.raises(BridgeError) as info:
        bridge.call("time.now")
    assert info.value.code == "NO_MAP"


def test_not_found_maps_to_mod_not_enabled():
    bridge, _ = make_bridge(error=RpcError(3, method="RunLua"))
    with pytest.raises(BridgeError) as info:
        bridge.call("core.ping")
    assert info.value.code == "MOD_NOT_ENABLED"


def test_os_error_drops_client_and_reports_disconnected():
    bridge, holder = make_bridge(error=ConnectionResetError("gone"))
    with pytest.raises(BridgeError) as info:
        bridge.call("core.ping")
    assert info.value.code == "DISCONNECTED"
    assert holder["client"].closed
    assert bridge._client is None


def test_bad_json_from_dispatcher():
    bridge, _ = make_bridge([["not json"]])
    with pytest.raises(BridgeError) as info:
        bridge.call("core.ping")
    assert info.value.code == "INTERNAL"
