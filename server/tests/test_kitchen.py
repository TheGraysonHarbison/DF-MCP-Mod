import pytest
from test_units import last_request, make, run


def test_list_kitchen_sends_args():
    mcp, holder = make()
    run(mcp, "list_kitchen")
    assert last_request(holder)["op"] == "kitchen.list"
    assert last_request(holder)["args"] == {
        "category": None,
        "query": None,
        "banned_only": False,
        "limit": 25,
    }
    run(mcp, "list_kitchen", category="seeds", query="plump", banned_only=True, limit=5)
    assert last_request(holder)["args"] == {
        "category": "seeds",
        "query": "plump",
        "banned_only": True,
        "limit": 5,
    }
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "list_kitchen", category="meat")
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "list_kitchen", limit=0)


def test_set_kitchen_by_key_and_by_material():
    mcp, holder = make()
    run(mcp, "set_kitchen", key="PLANT:-1:419:0", cook=False)
    assert last_request(holder)["op"] == "kitchen.set"
    assert last_request(holder)["args"] == {"key": "PLANT:-1:419:0", "cook": False, "brew": None}
    run(mcp, "set_kitchen", item_type="SEEDS", material="plump helmet", brew=True, subtype=2)
    assert last_request(holder)["args"] == {
        "item_type": "SEEDS",
        "material": "plump helmet",
        "subtype": 2,
        "cook": None,
        "brew": True,
    }
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "set_kitchen", key="PLANT:-1:419:0")
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "set_kitchen", item_type="PLANT", cook=True)
