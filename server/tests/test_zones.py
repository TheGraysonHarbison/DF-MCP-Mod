import asyncio

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


def test_create_zone_box_and_circle():
    mcp, holder = make()
    asyncio.run(
        mcp.call_tool(
            "create_zone",
            {
                "type": "office",
                "x1": 20,
                "y1": 35,
                "x2": 22,
                "y2": 37,
                "z": 129,
                "name": "Manager's Office",
            },
        )
    )
    request = last_request(holder)
    assert request["op"] == "zones.create"
    assert request["args"] == {
        "type": "office",
        "name": "Manager's Office",
        "active": True,
        "x1": 20,
        "y1": 35,
        "x2": 22,
        "y2": 37,
        "z": 129,
    }
    run(mcp, "create_zone", type="pit", center_x=5, center_y=6, radius=2, z=129, keep_filled=False)
    assert last_request(holder)["args"]["circle"] == {"x": 5, "y": 6, "z": 129, "radius": 2}
    assert last_request(holder)["args"]["keep_filled"] is False
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "create_zone", type="pit", x1=1, y1=1, x2=2, y2=2)


def test_edit_assign_unassign_delete():
    mcp, holder = make()
    run(mcp, "edit_zone", zone_id=9, add_box=[1, 2, 3, 4], remove_circle=[5, 5, 1], active=False)
    request = last_request(holder)
    assert request["op"] == "zones.edit"
    assert request["args"]["add"] == {"x1": 1, "y1": 2, "x2": 3, "y2": 4}
    assert request["args"]["remove"] == {"x": 5, "y": 5, "radius": 1}
    assert request["args"]["active"] is False
    run(mcp, "assign_zone", zone_id=9, unit_id=7747)
    assert last_request(holder)["args"] == {"id": 9, "unit_id": 7747}
    run(mcp, "unassign_zone", zone_id=9)
    assert last_request(holder)["args"] == {"id": 9, "unit_id": None}
    run(mcp, "delete_zone", zone_id=9)
    assert last_request(holder)["op"] == "zones.delete"
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "edit_zone", zone_id=9, add_box=[1, 2, 3])
