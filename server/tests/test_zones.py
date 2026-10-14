import pytest
from test_units import last_request, make, run


def test_list_zones_filters():
    mcp, holder = make()
    run(mcp, "list_zones", type=" Meeting Area ", query="hall", active=True, limit=5)
    request = last_request(holder)
    assert request["op"] == "zones.list"
    assert request["args"] == {
        "type": "meeting_area",
        "query": "hall",
        "active": True,
        "limit": 5,
        "offset": 0,
    }
    run(mcp, "list_zones")
    assert last_request(holder)["args"]["type"] is None


def test_get_zone_and_bad_args():
    mcp, holder = make()
    run(mcp, "get_zone", zone_id=4, limit=10)
    assert last_request(holder)["op"] == "zones.get"
    assert last_request(holder)["args"] == {"id": 4, "limit": 10}
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "list_zones", type="moat")
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "get_zone", zone_id=4, limit=0)
