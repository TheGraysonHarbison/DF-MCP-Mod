import pytest
from test_units import last_request, make, run


def test_map_tools_send_args():
    mcp, holder = make()
    run(mcp, "get_map_bounds")
    assert last_request(holder)["op"] == "map.bounds"
    run(mcp, "get_wagon")
    assert last_request(holder)["op"] == "map.wagon"
    run(mcp, "get_tile", x=1, y=2, z=3)
    assert last_request(holder)["args"] == {"x": 1, "y": 2, "z": 3, "limit": 25}
    run(mcp, "get_area_map", x=1, y=2, z=3, width=10, height=5)
    assert last_request(holder)["args"] == {
        "x": 1,
        "y": 2,
        "z": 3,
        "width": 10,
        "height": 5,
        "view": "shape",
    }
    run(mcp, "get_area_map", x=1, y=2, z=3, view="material")
    assert last_request(holder)["args"]["view"] == "material"
    run(mcp, "find_exposed_walls", z=100, near_x=5, near_y=6, radius=10, material="granite")
    assert last_request(holder)["op"] == "map.exposed_walls"
    assert last_request(holder)["args"] == {
        "z": 100,
        "near_x": 5,
        "near_y": 6,
        "radius": 10,
        "material": "granite",
        "limit": 25,
    }
    run(mcp, "list_designations", x1=5, y1=5, z1=10, x2=1, y2=1, z2=12, kind="mine")
    assert last_request(holder)["op"] == "map.designations"
    assert last_request(holder)["args"]["kind"] == "mine"
    assert last_request(holder)["args"]["assigned_only"] is False
    run(mcp, "find_build_space", width=3, height=3)
    assert last_request(holder)["op"] == "map.find_space"
    assert last_request(holder)["args"]["z"] is None
    assert last_request(holder)["args"]["whole_map"] is False
    assert last_request(holder)["args"]["max_radius"] == 30


def test_map_tools_have_no_size_cap_of_their_own():
    # P2-4.0: the map's bounds are the only limit, and the mod checks them.
    mcp, holder = make()
    run(mcp, "get_area_map", x=0, y=0, z=0, width=192, height=192)
    assert last_request(holder)["args"]["width"] == 192
    run(mcp, "find_build_space", width=40, height=50, max_radius=500)
    assert last_request(holder)["args"]["width"] == 40
    assert last_request(holder)["args"]["max_radius"] == 500
    run(mcp, "find_build_space", near_x=10, near_y=20, z=150, whole_map=True)
    assert last_request(holder)["args"]["whole_map"] is True
    run(mcp, "list_designations", x1=0, y1=0, z1=0, x2=191, y2=191, z2=150)
    assert last_request(holder)["args"]["x2"] == 191
    run(mcp, "plan_dig", kind="mine", x1=0, y1=0, z1=0, x2=191, y2=191, z2=100)
    assert last_request(holder)["args"]["z2"] == 100
    run(mcp, "plan_dig", kind="mine", center_x=96, center_y=96, center_z=100, radius=90)
    assert last_request(holder)["args"]["circle"]["radius"] == 90


def test_map_tools_reject_bad_sizes():
    mcp, holder = make()
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "get_area_map", x=0, y=0, z=0, width=0)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "find_build_space", max_radius=-1)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "find_build_space", width=0)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "get_area_map", x=0, y=0, z=0, view="colors")
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "find_exposed_walls", z=0, near_x=1)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "list_designations", x1=0, y1=0, z1=0, x2=1, y2=1, z2=1, kind="dig")
