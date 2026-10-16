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
    run(mcp, "get_trade_screen")
    assert last_request(holder)["op"] == "trade.screen"
    run(mcp, "select_trade_goods", give=[1], take=[9], clear=False)
    assert last_request(holder)["op"] == "trade.select"
    assert last_request(holder)["args"] == {"give": [1], "take": [9], "clear": False}
    run(mcp, "offer_trade", give=[1, 2], take=[9])
    assert last_request(holder)["op"] == "trade.offer"
    assert last_request(holder)["args"] == {"give": [1, 2], "take": [9]}


def test_trade_screen_counter_offer_limit():
    mcp, holder = make()
    run(mcp, "get_trade_screen")
    assert last_request(holder)["args"] == {"limit": 25}
    run(mcp, "get_trade_screen", limit=5)
    assert last_request(holder)["args"] == {"limit": 5}
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "get_trade_screen", limit=0)


def test_open_trade_screen():
    mcp, holder = make()
    run(mcp, "open_trade_screen")
    assert last_request(holder)["op"] == "trade.open_screen"
    assert last_request(holder)["args"] == {}
    run(mcp, "open_trade_screen", depot_id=4, caravan_index=1)
    assert last_request(holder)["args"] == {"depot_id": 4, "caravan_index": 1}


@pytest.mark.parametrize(
    "action", ["trade", "offer", "seize", "accept_counter", "decline_counter", "close"]
)
def test_press_trade_actions(action):
    mcp, holder = make()
    run(mcp, "press_trade", action=action)
    assert last_request(holder)["op"] == "trade.press"
    assert last_request(holder)["args"] == {"action": action, "unpause": False, "limit": 25}


def test_press_trade_unpause_and_refusals():
    mcp, holder = make()
    run(mcp, "press_trade", action="close", unpause=True)
    assert last_request(holder)["args"] == {"action": "close", "unpause": True, "limit": 25}
    sent = len(holder["client"].requests)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "press_trade", action="buy")
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "press_trade", action="trade", limit=0)
    assert len(holder["client"].requests) == sent
