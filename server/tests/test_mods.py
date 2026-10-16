import pytest
from test_units import last_request, make, run


def test_list_mods_sends_args():
    mcp, holder = make()
    run(mcp, "list_mods")
    assert last_request(holder)["op"] == "settings.mods"
    assert last_request(holder)["args"] == {"limit": 25, "only_enabled": False}
    run(mcp, "list_mods", limit=60, only_enabled=True)
    assert last_request(holder)["args"] == {"limit": 60, "only_enabled": True}
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "list_mods", limit=0)
