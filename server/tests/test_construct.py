import pytest
from test_units import last_request, make, run


def test_place_construction_box_sends_corners_and_options():
    mcp, holder = make()
    run(
        mcp,
        "place_construction",
        kind="wall",
        x1=5,
        y1=5,
        z1=129,
        x2=9,
        y2=9,
        z2=129,
        hollow=True,
        material="any wood",
    )
    request = last_request(holder)
    assert request["op"] == "build.construct"
    assert request["args"] == {
        "kind": "wall",
        "hollow": True,
        "thick": True,
        "material": "any wood",
        "direction": None,
        "x1": 5,
        "y1": 5,
        "z1": 129,
        "x2": 9,
        "y2": 9,
        "z2": 129,
    }


def test_plan_construction_line_and_circle():
    mcp, holder = make()
    run(
        mcp,
        "plan_construction",
        kind="floor",
        shape="line",
        x1=1,
        y1=1,
        z1=10,
        x2=8,
        y2=4,
        thick=False,
    )
    request = last_request(holder)
    assert request["op"] == "build.plan_construction"
    assert request["args"]["line"] == {"x1": 1, "y1": 1, "x2": 8, "y2": 4, "z": 10}
    assert request["args"]["thick"] is False
    run(
        mcp,
        "plan_construction",
        kind="wall",
        shape="circle",
        center_x=3,
        center_y=4,
        center_z=5,
        radius=2,
        hollow=True,
    )
    assert last_request(holder)["args"]["circle"] == {"x": 3, "y": 4, "z": 5, "radius": 2}


def test_construction_rejects_bad_combinations():
    mcp, holder = make()
    for kwargs in (
        {"kind": "bridge", "x1": 1, "y1": 1, "z1": 1, "x2": 3, "y2": 3, "z2": 1},
        {
            "kind": "bridge",
            "shape": "circle",
            "center_x": 1,
            "center_y": 1,
            "center_z": 1,
            "radius": 2,
            "direction": "retracting",
        },
        {"kind": "wall", "shape": "line", "x1": 1, "y1": 1, "z1": 1, "x2": 3, "y2": 3, "z2": 2},
        {"kind": "tower", "x1": 1, "y1": 1, "z1": 1, "x2": 3, "y2": 3, "z2": 1},
        {"kind": "wall", "x1": 1, "y1": 1, "z1": 1},
    ):
        with pytest.raises(Exception):  # noqa: B017
            run(mcp, "place_construction", **kwargs)
    assert "client" not in holder
