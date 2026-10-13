import pytest
from test_units import last_request, make, run


def test_stock_bar_sends_category():
    mcp, holder = make()
    run(mcp, "get_stock_bar")
    assert last_request(holder)["args"] == {"category": None}
    run(mcp, "get_stock_bar", category="meat")
    assert last_request(holder)["op"] == "stocks.bar"
    assert last_request(holder)["args"] == {"category": "meat"}
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "get_stock_bar", category="beer")


def test_list_and_find_send_args():
    mcp, holder = make()
    run(mcp, "list_stocks", category="weapon", query="copper", limit=5)
    assert last_request(holder)["op"] == "stocks.list"
    assert last_request(holder)["args"] == {"category": "weapon", "query": "copper", "limit": 5}
    run(mcp, "find_items", query="plump")
    assert last_request(holder)["op"] == "stocks.find"
    assert last_request(holder)["args"] == {"query": "plump", "limit": 25}
    run(mcp, "list_artifacts")
    assert last_request(holder)["op"] == "stocks.artifacts"
    run(mcp, "get_fort_status")
    assert last_request(holder)["op"] == "stocks.status"
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "find_items", query=" ")
