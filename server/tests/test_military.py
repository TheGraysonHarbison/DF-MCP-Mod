import asyncio

import pytest
from test_units import last_request, make, run


def call(mcp, tool, **arguments):
    # The shared helper takes `name` positionally, which clashes with the squad name field.
    return asyncio.run(mcp.call_tool(tool, arguments))


def test_reads_send_args():
    mcp, holder = make()
    run(mcp, "list_squads")
    assert last_request(holder)["op"] == "military.list"
    assert last_request(holder)["args"] == {"limit": 25}
    run(mcp, "get_squad", squad_id=3)
    assert last_request(holder)["op"] == "military.get"
    assert last_request(holder)["args"] == {"id": 3}


def test_create_sends_only_given_fields():
    mcp, holder = make()
    run(mcp, "create_squad")
    assert last_request(holder)["op"] == "military.create"
    assert last_request(holder)["args"] == {}
    call(mcp, "create_squad", name="The Axes", kind="crossbow", position="MILITIA_COMMANDER")
    assert last_request(holder)["args"] == {
        "name": "The Axes",
        "kind": "crossbow",
        "position": "MILITIA_COMMANDER",
    }
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "create_squad", kind="archer")


def test_membership_ops():
    mcp, holder = make()
    call(mcp, "rename_squad", squad_id=3, name="The Axes")
    assert last_request(holder)["op"] == "military.rename"
    assert last_request(holder)["args"] == {"id": 3, "name": "The Axes"}
    run(mcp, "set_squad_symbol", squad_id=3, symbol=7, foreground=[255, 200, 0])
    assert last_request(holder)["op"] == "military.set_symbol"
    assert last_request(holder)["args"] == {"id": 3, "symbol": 7, "foreground": [255, 200, 0]}
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "set_squad_symbol", squad_id=3, symbol=40)
    run(mcp, "add_to_squad", squad_id=3, unit_id=842)
    assert last_request(holder)["op"] == "military.add"
    assert last_request(holder)["args"] == {"id": 3, "unit_id": 842}
    run(mcp, "add_to_squad", squad_id=3, unit_id=842, slot=2)
    assert last_request(holder)["args"] == {"id": 3, "unit_id": 842, "slot": 2}
    run(mcp, "remove_from_squad", squad_id=3, unit_id=842)
    assert last_request(holder)["op"] == "military.remove"
    run(mcp, "set_squad_leader", squad_id=3, unit_id=842)
    assert last_request(holder)["op"] == "military.set_leader"
    assert last_request(holder)["args"] == {"id": 3, "unit_id": 842}
    run(mcp, "disband_squad", squad_id=3)
    assert last_request(holder)["op"] == "military.disband"
    assert last_request(holder)["args"] == {"id": 3}
