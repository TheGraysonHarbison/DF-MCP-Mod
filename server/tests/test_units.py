import asyncio
import json

import pytest

from df_mcp.bridge import Bridge
from df_mcp.server import build_server


class FakeClient:
    def __init__(self, host, port):
        self.requests = []

    def connect(self):
        pass

    def close(self):
        pass

    def run_lua(self, module, function, args):
        self.requests.append(json.loads(args[0]))
        return [json.dumps({"ok": True, "result": {"echo": True}})]


def make():
    holder = {}

    def factory(host, port):
        holder["client"] = FakeClient(host, port)
        return holder["client"]

    return build_server(Bridge("h", 1, client_factory=factory)), holder


def run(mcp, name, **arguments):
    return asyncio.run(mcp.call_tool(name, arguments))


def last_request(holder):
    return holder["client"].requests[-1]


def test_bucket_tools_send_their_bucket():
    mcp, holder = make()
    for tool, bucket in [
        ("list_citizens", "citizen"),
        ("list_domesticated", "domesticated"),
        ("list_others", "other"),
    ]:
        run(mcp, tool)
        request = last_request(holder)
        assert request["op"] == "units.list"
        assert request["args"]["bucket"] == bucket
        assert request["args"]["limit"] == 200


def test_list_units_without_bucket_sends_null():
    mcp, holder = make()
    run(mcp, "list_units", kind="invader", limit=5)
    args = last_request(holder)["args"]
    assert args["bucket"] is None
    assert args["kind"] == "invader"
    assert args["limit"] == 5


def test_list_units_rejects_bad_bucket_and_kind():
    # The SDK masks validation messages, so check that nothing reached the bridge.
    mcp, holder = make()
    with pytest.raises(Exception):  # noqa: B017 - the SDK's ToolError wraps ValueError
        run(mcp, "list_units", bucket="animals")
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "list_citizens", kind="pet")
    assert "client" not in holder


def test_find_unit_sends_query():
    mcp, holder = make()
    run(mcp, "find_unit", query="Urist", bucket="citizen")
    request = last_request(holder)
    assert request["op"] == "units.find"
    assert request["args"] == {
        "query": "Urist",
        "bucket": "citizen",
        "limit": 20,
        "include_dead": False,
    }
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "find_unit", query="  ")
    assert len(holder["client"].requests) == 1


def test_get_unit_sends_id():
    mcp, holder = make()
    run(mcp, "get_unit", unit_id=42)
    request = last_request(holder)
    assert request["op"] == "units.get"
    assert request["args"] == {"id": 42}
    assert request["v"] == 2


def test_sheet_tools_send_category_and_limit():
    mcp, holder = make()
    run(mcp, "get_unit_sheet", unit_id=7, category="skills", subcategory="combat")
    request = last_request(holder)
    assert request["op"] == "units.sheet"
    assert request["args"] == {"id": 7, "category": "skills", "subcategory": "combat", "limit": 25}
    run(mcp, "get_unit_full_sheet", unit_id=7, limit=10)
    request = last_request(holder)
    assert request["op"] == "units.full_sheet"
    assert request["args"] == {"id": 7, "limit": 10}


def test_sheet_tool_rejects_bad_category_and_subcategory():
    mcp, holder = make()
    for kwargs in [
        {"category": "stuff"},
        {"category": "overview", "subcategory": "x"},
        {"category": "skills", "subcategory": "cooking"},
        {"category": "skills", "limit": 0},
    ]:
        with pytest.raises(Exception):  # noqa: B017
            run(mcp, "get_unit_sheet", unit_id=7, **kwargs)
    assert "client" not in holder


def test_set_nickname_sends_id_and_nickname():
    mcp, holder = make()
    run(mcp, "set_unit_nickname", unit_id=310, nickname="Digger")
    request = last_request(holder)
    assert request["op"] == "units.set_nickname"
    assert request["args"] == {"id": 310, "nickname": "Digger"}
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "set_unit_nickname", unit_id=310, nickname="x" * 65)
