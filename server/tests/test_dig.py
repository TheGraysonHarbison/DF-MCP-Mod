import pytest
from test_units import last_request, make, run


def test_plan_and_designate_send_box():
    mcp, holder = make()
    run(mcp, "plan_dig", kind="stairs", x1=21, y1=18, z1=150, x2=21, y2=18, z2=145)
    assert last_request(holder)["op"] == "dig.plan"
    assert last_request(holder)["args"] == {
        "x1": 21,
        "y1": 18,
        "z1": 150,
        "x2": 21,
        "y2": 18,
        "z2": 145,
        "kind": "stairs",
    }
    run(mcp, "designate_dig", kind="mine", x1=0, y1=0, z1=1, x2=4, y2=4, z2=1)
    assert last_request(holder)["op"] == "dig.designate"
    assert last_request(holder)["args"]["kind"] == "mine"
    run(mcp, "designate_dig", kind="smooth", x1=0, y1=0, z1=1, x2=4, y2=4, z2=1)
    assert last_request(holder)["args"]["kind"] == "smooth"
    run(mcp, "plan_dig", kind="engrave", x1=0, y1=0, z1=1, x2=4, y2=4, z2=1)
    assert last_request(holder)["args"]["kind"] == "engrave"
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "plan_dig", kind="tunnel", x1=0, y1=0, z1=0, x2=1, y2=1, z2=1)


def test_erase_sends_optional_kind():
    mcp, holder = make()
    run(mcp, "erase_designations", x1=0, y1=0, z1=1, x2=4, y2=4, z2=1)
    assert last_request(holder)["op"] == "dig.erase"
    assert last_request(holder)["args"]["kind"] is None
    run(mcp, "erase_designations", x1=0, y1=0, z1=1, x2=4, y2=4, z2=1, kind="smooth")
    assert last_request(holder)["args"]["kind"] == "smooth"
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "erase_designations", x1=0, y1=0, z1=1, x2=4, y2=4, z2=1, kind="stairs")
