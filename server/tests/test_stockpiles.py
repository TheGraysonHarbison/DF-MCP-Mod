import asyncio

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


def test_stockpile_write_tools_send_args():
    mcp, holder = make()
    asyncio.run(
        mcp.call_tool(
            "create_stockpile",
            {"x1": 1, "y1": 2, "x2": 3, "y2": 4, "z": 5, "name": "Rocks", "categories": ["stone"]},
        )
    )
    args = last_request(holder)["args"]
    assert last_request(holder)["op"] == "stockpiles.create"
    assert args["x1"] == 1 and args["y2"] == 4 and args["categories"] == ["stone"]
    assert args["preset_mode"] == "set"
    run(mcp, "configure_stockpile", building_id=7, disable=["wood"])
    assert last_request(holder)["args"]["disable"] == ["wood"]
    asyncio.run(mcp.call_tool("rename_stockpile", {"building_id": 7, "name": "Pile"}))
    assert last_request(holder)["op"] == "stockpiles.rename"
    run(mcp, "delete_stockpile", building_id=7)
    assert last_request(holder)["op"] == "stockpiles.delete"
    run(mcp, "list_stockpile_presets", query="stone")
    assert last_request(holder)["op"] == "stockpiles.presets"
    for kwargs in [{"categories": ["beer"]}, {"preset_mode": "replace"}]:
        with pytest.raises(Exception):  # noqa: B017
            run(mcp, "create_stockpile", x1=1, y1=2, x2=3, y2=4, z=5, **kwargs)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "configure_stockpile", building_id=7)


def test_create_stockpile_circle():
    mcp, holder = make()
    run(mcp, "create_stockpile", center_x=16, center_y=18, z=145, radius=2)
    args = last_request(holder)["args"]
    assert args["circle"] == {"x": 16, "y": 18, "z": 145, "radius": 2}
    assert args["x1"] is None
    for kwargs in [
        {"center_x": 1, "z": 1, "radius": 2},
        {"x1": 1, "y1": 1, "x2": 2, "y2": 2, "z": 1, "center_x": 1, "center_y": 1, "radius": 1},
        {"x1": 1, "y1": 1, "z": 1},
    ]:
        with pytest.raises(Exception):  # noqa: B017
            run(mcp, "create_stockpile", **kwargs)
