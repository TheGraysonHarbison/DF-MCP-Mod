import asyncio

import pytest
from test_units import last_request, make, run


def call(mcp, tool, **arguments):
    # run() takes the tool as `name`, which clashes with set_hotkey's own `name` argument.
    return asyncio.run(mcp.call_tool(tool, arguments))


def test_list_hotkeys_sends_op():
    mcp, holder = make()
    run(mcp, "list_hotkeys")
    request = last_request(holder)
    assert request["op"] == "hotkeys.list"
    assert request.get("args", {}) in ({}, None)


def test_set_hotkey_sends_args():
    mcp, holder = make()
    call(mcp, "set_hotkey", name="  Depot ", x=10, y=20, z=150)
    request = last_request(holder)
    assert request["op"] == "hotkeys.set"
    assert request["args"] == {
        "name": "Depot",
        "x": 10,
        "y": 20,
        "z": 150,
        "slot": None,
        "overwrite": False,
    }
    call(mcp, "set_hotkey", name="Farms", x=1, y=2, z=3, slot=16, overwrite=True)
    assert last_request(holder)["args"] == {
        "name": "Farms",
        "x": 1,
        "y": 2,
        "z": 3,
        "slot": 16,
        "overwrite": True,
    }


def test_set_hotkey_rejects_bad_args():
    mcp, holder = make()
    with pytest.raises(Exception):  # noqa: B017
        call(mcp, "set_hotkey", name="   ", x=1, y=2, z=3)
    with pytest.raises(Exception):  # noqa: B017
        call(mcp, "set_hotkey", name="Depot", x=1, y=2, z=3, slot=0)
    with pytest.raises(Exception):  # noqa: B017
        call(mcp, "set_hotkey", name="Depot", x=1, y=2, z=3, slot=17)
    assert "client" not in holder


def test_clear_hotkey_sends_slot():
    mcp, holder = make()
    run(mcp, "clear_hotkey", slot=4)
    request = last_request(holder)
    assert request["op"] == "hotkeys.clear"
    assert request["args"] == {"slot": 4}


def test_clear_hotkey_rejects_bad_slot():
    mcp, holder = make()
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "clear_hotkey", slot=0)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "clear_hotkey", slot=17)
    assert "client" not in holder
