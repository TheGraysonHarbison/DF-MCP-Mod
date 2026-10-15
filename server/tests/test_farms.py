import pytest
from test_units import last_request, make, run


def test_list_and_get_send_args():
    mcp, holder = make()
    run(mcp, "list_farms")
    assert last_request(holder)["op"] == "farms.list"
    assert last_request(holder)["args"] == {"limit": 25}
    run(mcp, "get_farm", farm_id=7, limit=5)
    assert last_request(holder)["op"] == "farms.get"
    assert last_request(holder)["args"] == {"id": 7, "limit": 5}
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "get_farm", farm_id=7, limit=0)


def test_set_crops_builds_crop_map():
    mcp, holder = make()
    run(mcp, "set_farm_crops", farm_id=7, spring="plump helmet", winter="none")
    assert last_request(holder)["op"] == "farms.set_crops"
    assert last_request(holder)["args"] == {
        "id": 7,
        "crops": {"spring": "plump helmet", "winter": "none"},
    }
    run(mcp, "set_farm_crops", farm_id=7, fertilize=True)
    assert last_request(holder)["args"] == {"id": 7, "fertilize": True}
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "set_farm_crops", farm_id=7)


def test_place_farm_plot_passes_fertilize():
    mcp, holder = make()
    run(mcp, "place_furniture", type="farm plot", x=1, y=2, z=3, x2=4, y2=5, fertilize=True)
    assert last_request(holder)["op"] == "build.place"
    assert last_request(holder)["args"] == {
        "type": "farm_plot",
        "material": None,
        "limit": 25,
        "fertilize": True,
        "x1": 1,
        "y1": 2,
        "z1": 3,
        "x2": 4,
        "y2": 5,
        "z2": 3,
    }
    run(mcp, "plan_furniture", type="bed", x=1, y=2, z=3)
    assert "fertilize" not in last_request(holder)["args"]
