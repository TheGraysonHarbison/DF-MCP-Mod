import pytest
from test_units import last_request, make, run


def test_list_plants_box_and_circle():
    mcp, holder = make()
    run(mcp, "list_plants", x1=0, y1=0, z1=5, x2=9, y2=9, z2=5, kind="tree", query="oak")
    assert last_request(holder)["op"] == "map.plants"
    assert last_request(holder)["args"] == {
        "kind": "tree",
        "query": "oak",
        "marked_only": False,
        "limit": 25,
        "x1": 0,
        "y1": 0,
        "z1": 5,
        "x2": 9,
        "y2": 9,
        "z2": 5,
    }
    run(mcp, "list_plants", center_x=4, center_y=4, center_z=5, radius=3, marked_only=True)
    assert last_request(holder)["args"]["circle"] == {"x": 4, "y": 4, "z": 5, "radius": 3}
    assert last_request(holder)["args"]["marked_only"] is True
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "list_plants", x1=0, y1=0, z1=5, x2=9, y2=9, z2=5, kind="bush")
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "list_plants", x1=0, y1=0, z1=5)


def test_chop_and_gather_go_through_dig():
    mcp, holder = make()
    run(mcp, "designate_dig", kind="chop", x1=0, y1=0, z1=5, x2=9, y2=9, z2=5)
    assert last_request(holder)["op"] == "dig.designate"
    assert last_request(holder)["args"]["kind"] == "chop"
    run(mcp, "plan_dig", kind="gather", center_x=4, center_y=4, center_z=5, radius=3)
    assert last_request(holder)["op"] == "dig.plan"
    assert last_request(holder)["args"]["kind"] == "gather"
    run(mcp, "erase_designations", x1=0, y1=0, z1=5, x2=9, y2=9, z2=5, kind="chop")
    assert last_request(holder)["args"]["kind"] == "chop"
    run(mcp, "list_designations", x1=0, y1=0, z1=5, x2=9, y2=9, z2=5, kind="gather")
    assert last_request(holder)["args"]["kind"] == "gather"
