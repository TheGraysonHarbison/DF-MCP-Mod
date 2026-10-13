import pytest
from test_units import last_request, make, run


def test_workshop_tools_send_args():
    mcp, holder = make()
    run(mcp, "list_workshops", type="Kitchen")
    assert last_request(holder)["op"] == "workshops.list"
    assert last_request(holder)["args"] == {"type": "Kitchen", "limit": 25, "offset": 0}
    run(mcp, "get_workshop", building_id=12, limit=5)
    assert last_request(holder)["op"] == "workshops.get"
    assert last_request(holder)["args"] == {"id": 12, "limit": 5}
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "get_workshop", building_id=12, limit=0)
