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
