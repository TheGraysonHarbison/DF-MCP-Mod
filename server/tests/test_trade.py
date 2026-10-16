import pytest
from test_units import last_request, make, run


def test_trade_reads():
    mcp, holder = make()
    run(mcp, "list_caravans")
    assert last_request(holder)["op"] == "trade.caravans"
    run(mcp, "get_trade_depot", depot_id=3, limit=5)
    assert last_request(holder)["op"] == "trade.depot"
    assert last_request(holder)["args"] == {"limit": 5, "depot_id": 3}
    run(mcp, "get_broker")
    assert last_request(holder)["op"] == "trade.broker"


def test_trade_writes():
    mcp, holder = make()
    run(mcp, "request_broker", anyone=True)
    assert last_request(holder)["op"] == "trade.request_broker"
    assert last_request(holder)["args"] == {"requested": True, "anyone": True}
    run(mcp, "bring_to_depot", query="crafts", item_type="CRAFTS", limit=10)
    assert last_request(holder)["op"] == "trade.bring"
    assert last_request(holder)["args"] == {"limit": 10, "query": "crafts", "item_type": "CRAFTS"}
    run(mcp, "bring_to_depot", item_ids=[5, 6])
    assert last_request(holder)["args"] == {"limit": 25, "item_ids": [5, 6]}
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "bring_to_depot")
    run(mcp, "cancel_bring", item_ids=[5])
    assert last_request(holder)["op"] == "trade.unbring"
    assert last_request(holder)["args"] == {"item_ids": [5]}
    run(mcp, "offer_trade", give=[1, 2], take=[9])
    assert last_request(holder)["op"] == "trade.offer"
    assert last_request(holder)["args"] == {"give": [1, 2], "take": [9]}
