import pytest
from test_units import last_request, make, run


def test_list_work_details_sends_op():
    mcp, holder = make()
    run(mcp, "list_work_details")
    request = last_request(holder)
    assert request["op"] == "labor.details"
    assert request["args"] == {"limit": 25}
    run(mcp, "list_work_details", detail=" Miners ", limit=50)
    assert last_request(holder)["args"] == {"detail": "Miners", "limit": 50}


def test_list_work_details_rejects_bad_limit():
    mcp, holder = make()
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "list_work_details", limit=0)
    assert "client" not in holder


def test_assign_work_detail_sends_ids():
    mcp, holder = make()
    run(mcp, "assign_work_detail", detail="Woodcutters", add=[310, 312])
    request = last_request(holder)
    assert request["op"] == "labor.assign"
    assert request["args"] == {"detail": "Woodcutters", "add": [310, 312], "remove": []}
    run(mcp, "assign_work_detail", detail="1", remove=[7])
    assert last_request(holder)["args"] == {"detail": "1", "add": [], "remove": [7]}


def test_assign_work_detail_rejects_bad_args():
    mcp, holder = make()
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "assign_work_detail", detail="Miners")
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "assign_work_detail", detail="Miners", add=[], remove=[])
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "assign_work_detail", detail="  ", add=[1])
    assert "client" not in holder


def test_set_work_detail_mode_sends_mode():
    mcp, holder = make()
    run(mcp, "set_work_detail_mode", detail="Haulers", mode=" Nobody ")
    request = last_request(holder)
    assert request["op"] == "labor.set_mode"
    assert request["args"] == {"detail": "Haulers", "mode": "nobody"}


def test_set_work_detail_mode_rejects_unknown_mode():
    mcp, holder = make()
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "set_work_detail_mode", detail="Haulers", mode="default")
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "set_work_detail_mode", detail="Haulers", mode="sometimes")
    assert "client" not in holder
