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
