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


def test_orders_and_routes():
    mcp, holder = make()
    run(mcp, "order_squad", squad_id=3, kind="station", x=10, y=11, z=12)
    assert last_request(holder)["op"] == "military.order"
    assert last_request(holder)["args"] == {"id": 3, "kind": "station", "x": 10, "y": 11, "z": 12}
    run(mcp, "order_squad", squad_id=3, kind="kill", unit_ids=[900, 901], title="Goblins")
    assert last_request(holder)["args"] == {
        "id": 3,
        "kind": "kill",
        "unit_ids": [900, 901],
        "title": "Goblins",
    }
    run(mcp, "order_squad", squad_id=3, kind="patrol", route_id=2)
    assert last_request(holder)["args"] == {"id": 3, "kind": "patrol", "route_id": 2}
    run(mcp, "order_squad", squad_id=3, kind="cancel")
    assert last_request(holder)["args"] == {"id": 3, "kind": "cancel"}
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "order_squad", squad_id=3, kind="station", x=1)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "order_squad", squad_id=3, kind="kill")
    run(mcp, "set_squad_routine", squad_id=3, routine="Ready")
    assert last_request(holder)["args"] == {"id": 3, "routine": "Ready"}
    run(mcp, "list_routes")
    assert last_request(holder)["op"] == "military.routes"
    call(mcp, "create_route", name="Walls", points=[[1, 2, 3], [4, 5, 3]])
    assert last_request(holder)["op"] == "military.create_route"
    assert last_request(holder)["args"] == {
        "name": "Walls",
        "points": [{"x": 1, "y": 2, "z": 3}, {"x": 4, "y": 5, "z": 3}],
    }
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "create_route", points=[[1, 2, 3]])


def test_equipment_ops():
    mcp, holder = make()
    run(mcp, "get_squad_equipment", squad_id=3)
    assert last_request(holder)["op"] == "military.equipment"
    assert last_request(holder)["args"] == {"id": 3}
    run(
        mcp,
        "set_squad_uniform",
        squad_id=3,
        category="body",
        item="breastplate",
        material_class="metal",
    )
    assert last_request(holder)["op"] == "military.set_uniform"
    assert last_request(holder)["args"] == {
        "id": 3,
        "category": "body",
        "item": "breastplate",
        "material_class": "metal",
    }
    run(
        mcp,
        "set_squad_uniform",
        squad_id=3,
        category="weapon",
        clear=True,
        exact_matches=True,
        position=2,
    )
    assert last_request(holder)["args"] == {
        "id": 3,
        "category": "weapon",
        "clear": True,
        "exact_matches": True,
        "position": 2,
    }
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "set_squad_uniform", squad_id=3, category="hat", item="helm")
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "set_squad_uniform", squad_id=3, category="head")
    run(mcp, "set_squad_ammo", squad_id=3, item="bolts", amount=50, training=False)
    assert last_request(holder)["op"] == "military.set_ammo"
    assert last_request(holder)["args"] == {
        "id": 3,
        "item": "bolts",
        "amount": 50,
        "material_class": "any",
        "combat": True,
        "training": False,
    }
    run(mcp, "set_squad_ammo", squad_id=3, clear=True)
    assert last_request(holder)["args"] == {"id": 3, "clear": True}
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "set_squad_ammo", squad_id=3)
