import pytest
from test_units import last_request, make, run


def test_list_and_get():
    mcp, holder = make()
    run(mcp, "list_work_orders", query="chair", approved=True)
    assert last_request(holder)["op"] == "orders.list"
    assert last_request(holder)["args"] == {
        "query": "chair",
        "approved": True,
        "limit": 25,
        "offset": 0,
    }
    run(mcp, "get_work_order", order_id=3)
    assert last_request(holder)["args"] == {"id": 3}
    run(mcp, "find_job_types", query="brew")
    assert last_request(holder)["op"] == "orders.jobs"


def test_create_requires_exactly_one_of_job_or_reaction():
    mcp, holder = make()
    run(mcp, "create_work_order", job="ConstructThrone", amount=2, material="any stone")
    args = last_request(holder)["args"]
    assert args["job"] == "ConstructThrone"
    assert args["reaction"] is None
    assert args["amount"] == 2
    assert args["material"] == "any stone"
    assert args["material_category"] is None
    assert args["item_type"] is None
    assert args["frequency"] == "OneTime"
    for kwargs in [
        {},
        {"job": "x", "reaction": "y"},
        {"job": "x", "frequency": "Hourly"},
        {"job": "x", "amount": -1},
    ]:
        with pytest.raises(Exception):  # noqa: B017
            run(mcp, "create_work_order", **kwargs)


def test_edit_and_delete():
    mcp, holder = make()
    run(mcp, "edit_work_order", order_id=3, amount=5)
    assert last_request(holder)["op"] == "orders.edit"
    assert last_request(holder)["args"]["amount"] == 5
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "edit_work_order", order_id=3)
    run(mcp, "delete_work_order", order_id=3)
    assert last_request(holder)["op"] == "orders.delete"
