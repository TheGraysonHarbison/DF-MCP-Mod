import pytest
from test_units import last_request, make, run


def test_diplomat_tools_send_args():
    mcp, holder = make()
    run(mcp, "list_diplomats")
    assert last_request(holder)["op"] == "trade.diplomats"
    run(mcp, "get_trade_request_options", category="MetalBars", limit=5)
    assert last_request(holder)["op"] == "trade.request_options"
    assert last_request(holder)["args"] == {"limit": 5, "category": "MetalBars"}
    reqs = [{"category": "MetalBars", "item": "steel", "priority": 4}]
    run(mcp, "set_trade_requests", requests=reqs, civ_id=29)
    assert last_request(holder)["op"] == "trade.set_requests"
    assert last_request(holder)["args"] == {"requests": reqs, "civ_id": 29}
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "set_trade_requests", requests=[])
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "set_trade_requests", requests=[{"item": "steel"}])


def test_meeting_dialog_tools_send_args():
    mcp, holder = make()
    run(mcp, "get_meeting_dialog", limit=5)
    assert last_request(holder)["op"] == "trade.dialog"
    assert last_request(holder)["args"] == {"limit": 5}
    run(mcp, "open_meeting_dialog")
    assert last_request(holder)["op"] == "trade.open_dialog"
    assert last_request(holder)["args"] == {}
    run(mcp, "step_meeting_dialog", action="done")
    assert last_request(holder)["op"] == "trade.dialog_step"
    assert last_request(holder)["args"] == {"action": "done"}
    run(mcp, "step_meeting_dialog", action="choose", choice=2)
    assert last_request(holder)["args"] == {"action": "choose", "choice": 2}
    run(mcp, "step_meeting_dialog", action="land_holder", hf_id=812, position_index=1)
    assert last_request(holder)["args"] == {
        "action": "land_holder",
        "hf_id": 812,
        "position_index": 1,
    }
    run(mcp, "step_meeting_dialog", action="close", unpause=True)
    assert last_request(holder)["args"] == {"action": "close", "unpause": True}


def test_meeting_dialog_tools_refuse_bad_args():
    mcp, holder = make()
    run(mcp, "get_meeting_dialog")
    sent = len(holder["client"].requests)
    for kwargs in [
        {"action": "skip"},
        {"action": "choose"},
        {"action": "choose", "choice": -1},
        {"action": "land_holder"},
        {"action": "land_holder", "hf_id": 3, "position_index": -1},
    ]:
        with pytest.raises(Exception):  # noqa: B017
            run(mcp, "step_meeting_dialog", **kwargs)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "get_meeting_dialog", limit=0)
    assert len(holder["client"].requests) == sent
