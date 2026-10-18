import pytest
from test_units import last_request, make, run

from df_mcp.channel import format_batch


def test_plan_tools_send_args():
    mcp, holder = make()
    run(mcp, "get_plan_info")
    assert last_request(holder)["op"] == "plan.info"
    run(mcp, "read_plan")
    assert last_request(holder)["op"] == "plan.read"
    run(mcp, "write_plan", text="# Plan\n")
    assert last_request(holder)["op"] == "plan.write"
    assert last_request(holder)["args"] == {"text": "# Plan\n"}
    run(mcp, "append_plan", text="- note")
    assert last_request(holder)["op"] == "plan.append"
    assert last_request(holder)["args"] == {"text": "- note"}
    run(mcp, "read_goals")
    assert last_request(holder)["op"] == "goals.read"
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "write_plan")


def test_goals_batch_is_delivered_whole():
    result = {
        "events": [{"seq": 3, "kind": "goals", "text": "Here are the goals:\n- dig deeper\n"}]
    }
    content, meta = format_batch(result)
    assert content == "Here are the goals:\n- dig deeper\n"
    assert meta["kind"] == "goals"
    assert meta["count"] == "1"
    mixed = {
        "events": [
            {"seq": 4, "kind": "goals", "text": "g"},
            {"seq": 5, "kind": "petition", "text": "p"},
        ]
    }
    content, meta = format_batch(mixed)
    assert content.startswith("Dwarf Fortress events: 2")


PLAN_INFO_FIXTURE = {
    "storage": "site data",
    "folder": "save/region1/claude-df/",
    "save_folder": "region1",
    "plan": {
        "name": "plan.md",
        "stored": True,
        "bytes": 65536,
        "mirror_exists": True,
        "mirror_bytes": 65536,
        "mirror_current": True,
    },
    "goals": {
        "name": "goals.md",
        "stored": False,
        "bytes": 0,
        "mirror_exists": False,
        "mirror_bytes": 0,
        "mirror_current": False,
    },
    "mirror_current": False,
    "max_bytes": 65536,
    "goal_prompt": "Goals:\n{Put Goals Here}\n",
}


def make_fixture(result):
    import json

    from df_mcp.bridge import Bridge
    from df_mcp.server import build_server

    class Client:
        def __init__(self, host, port):
            self.requests = []

        def connect(self):
            pass

        def close(self):
            pass

        def run_lua(self, module, function, args):
            self.requests.append(json.loads(args[0]))
            return [json.dumps({"ok": True, "result": result})]

    holder = {}

    def factory(host, port):
        holder["client"] = Client(host, port)
        return holder["client"]

    return build_server(Bridge("h", 1, client_factory=factory)), holder


def test_get_plan_info_passes_the_site_data_shape():
    mcp, holder = make_fixture(PLAN_INFO_FIXTURE)
    out = run(mcp, "get_plan_info").structured_content
    assert last_request(holder)["op"] == "plan.info"
    assert out["storage"] == "site data"
    assert out["folder"].endswith("claude-df/")
    for key in ("plan", "goals"):
        assert set(out[key]) == {
            "name",
            "stored",
            "bytes",
            "mirror_exists",
            "mirror_bytes",
            "mirror_current",
        }
    assert out["plan"]["bytes"] == out["max_bytes"] == 65536
    assert out["goals"]["stored"] is False
    assert out["mirror_current"] is False


def test_write_plan_passes_the_mirror_note():
    note = "saved; the mirror file was not written: cannot write x: denied"
    mcp, holder = make_fixture({"file": "plan.md", "bytes": 7, "replaced": True, "note": note})
    out = run(mcp, "write_plan", text="# Plan\n").structured_content
    assert out["replaced"] is True
    assert out["note"] == note
