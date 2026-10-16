import pytest
from test_units import last_request, make, run


def test_list_popups_sends_limit():
    mcp, holder = make()
    run(mcp, "list_popups")
    assert last_request(holder)["op"] == "popups.list"
    assert last_request(holder)["args"] == {"limit": 25}
    run(mcp, "list_popups", limit=3)
    assert last_request(holder)["args"] == {"limit": 3}


def test_list_popups_refuses_bad_limit():
    mcp, holder = make()
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "list_popups", limit=0)


def test_close_popup_sends_unpause():
    mcp, holder = make()
    run(mcp, "close_popup")
    assert last_request(holder)["op"] == "popups.close"
    assert last_request(holder)["args"] == {"unpause": False}
    run(mcp, "close_popup", unpause=True)
    assert last_request(holder)["args"] == {"unpause": True}


def test_close_popup_refuses_bad_unpause():
    mcp, holder = make()
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "close_popup", unpause="later")
