import pytest
from test_units import last_request, make, run


def test_trap_types_and_plate_settings():
    mcp, holder = make()
    run(mcp, "plan_furniture", type="lever", x=1, y=2, z=3)
    assert last_request(holder)["op"] == "build.plan_furniture"
    assert last_request(holder)["args"]["type"] == "lever"
    run(mcp, "place_furniture", type="trade depot", x=5, y=6, z=7)
    assert last_request(holder)["args"]["type"] == "trade_depot"
    run(
        mcp,
        "place_furniture",
        type="pressure_plate",
        x=1,
        y=2,
        z=3,
        plate_triggers=["units", "water"],
        plate_citizens=False,
        plate_resets=True,
        plate_min=4,
        plate_max=7,
    )
    assert last_request(holder)["args"]["plate"] == {
        "triggers": ["units", "water"],
        "citizens": False,
        "resets": True,
        "water_min": 4,
        "magma_min": 4,
        "water_max": 7,
        "magma_max": 7,
    }
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "place_furniture", type="lever", x=1, y=2, z=3, plate_citizens=True)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "place_furniture", type="pressure_plate", x=1, y=2, z=3, plate_triggers=["lava"])
