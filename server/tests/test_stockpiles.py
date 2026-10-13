import pytest
from test_units import last_request, make, run


def test_stockpile_tools_send_args():
    mcp, holder = make()
    run(mcp, "list_stockpiles", category="food")
    assert last_request(holder)["op"] == "stockpiles.list"
    assert last_request(holder)["args"] == {"category": "food", "limit": 25, "offset": 0}
    run(mcp, "get_stockpile", building_id=9, limit=3)
    assert last_request(holder)["args"] == {"id": 9, "limit": 3}
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "list_stockpiles", category="beer")
