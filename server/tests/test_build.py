import pytest
from test_units import last_request, make, run


def test_place_workshop_sends_args():
    mcp, holder = make()
    run(mcp, "place_workshop", type=" Masons ", x=1, y=2, z=3)
    assert last_request(holder)["op"] == "build.workshop"
    assert last_request(holder)["args"] == {
        "type": "Masons",
        "x": 1,
        "y": 2,
        "z": 3,
        "material": None,
    }
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "place_workshop", type=" ", x=1, y=2, z=3)


def test_remove_building_sends_id():
    mcp, holder = make()
    run(mcp, "remove_building", building_id=3)
    assert last_request(holder)["op"] == "build.remove"
    assert last_request(holder)["args"] == {"id": 3}


def test_list_building_materials_sends_filters():
    mcp, holder = make()
    run(mcp, "list_building_materials", form=" Blocks ", material="any stone", magma_safe=True)
    request = last_request(holder)
    assert request["op"] == "build.materials"
    assert request["args"] == {
        "form": "blocks",
        "material": "any stone",
        "fire_safe": False,
        "magma_safe": True,
        "limit": 25,
    }


def test_list_building_materials_rejects_bad_form():
    mcp, holder = make()
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "list_building_materials", form="planks")
    assert "client" not in holder


def test_list_buildings_filters():
    mcp, holder = make()
    run(mcp, "list_buildings", kind=" Door ", planned_only=True, z=129, limit=5)
    request = last_request(holder)
    assert request["op"] == "build.list"
    assert request["args"] == {
        "kind": "door",
        "planned_only": True,
        "z": 129,
        "limit": 5,
        "offset": 0,
    }
    run(mcp, "list_buildings", x1=1, y1=2, z1=3, x2=4, y2=5, z2=3)
    assert last_request(holder)["args"]["x2"] == 4
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "list_buildings", x1=1)


def test_suspend_and_remove_constructions():
    mcp, holder = make()
    run(mcp, "suspend_building", building_id=58, suspended=False)
    assert last_request(holder) == {
        "op": "build.suspend",
        "args": {"id": 58, "suspended": False},
        "id": last_request(holder)["id"],
        "v": last_request(holder)["v"],
    }
    run(mcp, "remove_constructions", x1=1, y1=1, z1=1, x2=2, y2=2, z2=1)
    request = last_request(holder)
    assert request["op"] == "build.remove_constructions"
    assert request["args"]["dry_run"] is True
    assert request["args"]["limit"] == 25
    run(mcp, "remove_constructions", center_x=5, center_y=5, center_z=1, radius=2, dry_run=False)
    assert last_request(holder)["args"] == {
        "dry_run": False,
        "limit": 25,
        "circle": {"x": 5, "y": 5, "z": 1, "radius": 2},
    }
    run(mcp, "remove_constructions", x1=1, y1=1, z1=1, x2=2, y2=2, z2=1, limit=100)
    assert last_request(holder)["args"]["limit"] == 100
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "remove_constructions", x1=1, y1=1, z1=1, x2=2, y2=2, z2=1, limit=0)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "remove_constructions", x1=1)
