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
    assert last_request(holder)["args"] == {"x": 1, "y": 2, "z": 3, "width": 10, "height": 5}
    run(mcp, "find_build_space", width=3, height=3)
    assert last_request(holder)["op"] == "map.find_space"
    assert last_request(holder)["args"]["z"] is None


def test_map_tools_reject_bad_sizes():
    mcp, holder = make()
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "get_area_map", x=0, y=0, z=0, width=65)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "find_build_space", width=0)
