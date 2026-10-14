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


def test_map_tools_reject_bad_sizes():
    mcp, holder = make()
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "get_area_map", x=0, y=0, z=0, width=65)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "find_build_space", width=0)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "get_area_map", x=0, y=0, z=0, view="colors")
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "find_exposed_walls", z=0, near_x=1)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "list_designations", x1=0, y1=0, z1=0, x2=1, y2=1, z2=1, kind="dig")
