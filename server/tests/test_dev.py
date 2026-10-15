import pytest
from test_units import last_request, make, run


def line(holder):
    assert last_request(holder)["op"] == "console.run"
    return last_request(holder)["args"]["command"]


def test_create_item_builds_create_item_line():
    mcp, holder = make()
    run(mcp, "dev_create_item", item="weapon:item_weapon_pick", material="inorganic:copper")
    assert line(holder) == "modtools/create-item -i WEAPON:ITEM_WEAPON_PICK -m INORGANIC:COPPER"
    run(
        mcp,
        "dev_create_item",
        item="BOULDER:NONE",
        material="INORGANIC:GRANITE",
        count=5,
        quality=3,
        x=4,
        y=5,
        z=6,
        unit_id=842,
    )
    assert line(holder) == (
        "modtools/create-item -i BOULDER:NONE -m INORGANIC:GRANITE -c 5 -q 3 -p 4,5,6 -u 842"
    )
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "dev_create_item", item="BOULDER:NONE", material="INORGANIC:GRANITE", x=1)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "dev_create_item", item="BOULDER NONE", material="INORGANIC:GRANITE")
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "dev_create_item", item="BOULDER:NONE", material="INORGANIC:GRANITE", quality=9)


def test_exterminate_builds_line():
    mcp, holder = make()
    run(mcp, "dev_exterminate")
    assert line(holder) == "exterminate list"
    run(mcp, "dev_exterminate", target="goblin", method="magma", only_visible=True, limit=2)
    assert line(holder) == "exterminate GOBLIN --method MAGMA --only-visible --limit 2"
    run(mcp, "dev_exterminate", target="BIRD_RAVEN:male", include_friendly=True)
    assert line(holder) == "exterminate BIRD_RAVEN:MALE --include-friendly"
    run(mcp, "dev_exterminate", target="undead")
    assert line(holder) == "exterminate undead"
    run(mcp, "dev_exterminate", target="all:FEMALE")
    assert line(holder) == "exterminate all:FEMALE"
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "dev_exterminate", target="this")
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "dev_exterminate", target="goblin", method="nuke")


def test_untested_warning_reruns_once():
    import json

    from test_units import run as run_tool

    from df_mcp.bridge import Bridge
    from df_mcp.server import build_server

    class Client:
        def __init__(self, host, port):
            self.requests = []

        def connect(self):
            pass

        def close(self):
            pass

        def run_lua(self, module, function, args):
            self.requests.append(json.loads(args[0]))
            first = len(self.requests) == 1
            result = {
                "ok": not first,
                "result": 1 if first else 0,
                "output": "UNTESTED WARNING: run again" if first else "",
                "command": "x",
            }
            return [json.dumps({"ok": True, "result": result})]

    holder = {}

    def factory(host, port):
        holder["client"] = Client(host, port)
        return holder["client"]

    mcp = build_server(Bridge("h", 1, client_factory=factory))
    out = run_tool(mcp, "dev_create_item", item="BOULDER:NONE", material="INORGANIC:GRANITE")
    assert len(holder["client"].requests) == 2
    assert out.structured_content["untested_warning"].startswith("UNTESTED WARNING")
