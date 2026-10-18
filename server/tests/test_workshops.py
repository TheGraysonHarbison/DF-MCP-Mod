import asyncio

import pytest
from test_units import last_request, make, run


def test_workshop_tools_send_args():
    mcp, holder = make()
    run(mcp, "list_workshops", type="Kitchen")
    assert last_request(holder)["op"] == "workshops.list"
    assert last_request(holder)["args"] == {"type": "Kitchen", "limit": 25, "offset": 0}
    run(mcp, "get_workshop", building_id=12, limit=5)
    assert last_request(holder)["op"] == "workshops.get"
    assert last_request(holder)["args"] == {"id": 12, "limit": 5}
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "get_workshop", building_id=12, limit=0)


def test_list_workshop_tasks_sends_args():
    mcp, holder = make()
    run(mcp, "list_workshop_tasks", building_id=7, query="bed")
    assert last_request(holder)["op"] == "workshops.tasks"
    assert last_request(holder)["args"] == {"id": 7, "query": "bed", "limit": 25, "offset": 0}
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "list_workshop_tasks", building_id=7, limit=0)


def test_add_workshop_job_sends_args():
    mcp, holder = make()
    run(mcp, "add_workshop_job", building_id=7, job="bed", material="any wood", repeat=True)
    assert last_request(holder)["op"] == "workshops.add_job"
    assert last_request(holder)["args"] == {
        "id": 7,
        "job": "bed",
        "reaction": None,
        "item": None,
        "material": "any wood",
        "repeat": True,
        "do_now": False,
    }
    run(mcp, "add_workshop_job", building_id=9, reaction="BREW_DRINK_FROM_PLANT")
    assert last_request(holder)["args"]["reaction"] == "BREW_DRINK_FROM_PLANT"
    assert last_request(holder)["args"]["job"] is None
    for kwargs in [{}, {"job": "bed", "reaction": "TAN_A_HIDE"}]:
        with pytest.raises(Exception):  # noqa: B017
            run(mcp, "add_workshop_job", building_id=7, **kwargs)


def test_set_and_cancel_workshop_job():
    mcp, holder = make()
    run(mcp, "set_workshop_job", building_id=7, job_id=301, suspend=True)
    assert last_request(holder)["op"] == "workshops.set_job"
    assert last_request(holder)["args"] == {
        "id": 7,
        "job_id": 301,
        "suspend": True,
        "repeat": None,
        "do_now": None,
    }
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "set_workshop_job", building_id=7, job_id=301)
    run(mcp, "cancel_workshop_job", building_id=7, job_id=301)
    assert last_request(holder)["op"] == "workshops.cancel_job"
    assert last_request(holder)["args"] == {"id": 7, "job_id": 301}


def test_workshop_job_tool_annotations():
    mcp, _ = make()
    tools = {t.name: t for t in asyncio.run(mcp.list_tools())}
    assert tools["list_workshop_tasks"].annotations.read_only_hint is True
    assert tools["add_workshop_job"].annotations.read_only_hint is False
    assert tools["cancel_workshop_job"].annotations.destructive_hint is True
    assert "manager" in tools["add_workshop_job"].description
