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
