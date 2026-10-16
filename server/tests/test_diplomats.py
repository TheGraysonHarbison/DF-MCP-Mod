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
