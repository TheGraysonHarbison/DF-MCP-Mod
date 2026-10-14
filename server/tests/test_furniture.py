import pytest
from test_units import last_request, make, run


def test_place_furniture_single_tile():
    mcp, holder = make()
    run(mcp, "place_furniture", type=" Door ", x=16, y=38, z=129, material="plum wood")
    request = last_request(holder)
    assert request["op"] == "build.place"
    assert request["args"] == {
        "type": "door",
        "material": "plum wood",
        "limit": 25,
        "x": 16,
        "y": 38,
        "z": 129,
    }


def test_plan_furniture_box():
    mcp, holder = make()
    run(mcp, "plan_furniture", type="armor stand", x=1, y=2, z=3, x2=4, y2=5, limit=3)
    request = last_request(holder)
    assert request["op"] == "build.plan_furniture"
    assert request["args"] == {
        "type": "armor_stand",
        "material": None,
        "limit": 3,
        "x1": 1,
        "y1": 2,
        "z1": 3,
        "x2": 4,
        "y2": 5,
        "z2": 3,
    }


def test_place_furniture_rejects_half_box_and_bad_limit():
    mcp, holder = make()
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "place_furniture", type="bed", x=1, y=2, z=3, x2=4)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "place_furniture", type="bed", x=1, y=2, z=3, limit=0)
    assert "client" not in holder
