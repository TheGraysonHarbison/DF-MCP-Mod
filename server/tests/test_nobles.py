import pytest
from test_units import last_request, make, run


def test_list_nobles_sends_op():
    mcp, holder = make()
    run(mcp, "list_nobles")
    assert last_request(holder)["op"] == "nobles.list"


def test_assign_noble_sends_position_and_unit():
    mcp, holder = make()
    run(mcp, "assign_noble", position=" manager ", unit_id=310)
    request = last_request(holder)
    assert request["op"] == "nobles.assign"
    assert request["args"] == {"position": "manager", "id": 310, "slot": None}
    run(mcp, "assign_noble", position="MANAGER")
    assert last_request(holder)["args"] == {"position": "MANAGER", "id": None, "slot": None}


def test_assign_noble_rejects_bad_args():
    mcp, holder = make()
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "assign_noble", position="  ")
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "assign_noble", position="MANAGER", slot=0)
    assert "client" not in holder
