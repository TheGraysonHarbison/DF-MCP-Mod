import pytest
from test_units import last_request, make, run


def test_send_message_args():
    mcp, holder = make()
    run(mcp, "send_message", text="  The plan is written.  ")
    assert last_request(holder)["op"] == "messages.say"
    assert last_request(holder)["args"] == {"text": "The plan is written.", "badge": "rumor"}
    run(mcp, "send_message", text="Look here", x=1, y=2, z=3, badge="research")
    assert last_request(holder)["args"] == {
        "text": "Look here",
        "badge": "research",
        "x": 1,
        "y": 2,
        "z": 3,
    }
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "send_message", text=" ")
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "send_message", text="x" * 201)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "send_message", text="hi", x=1)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "send_message", text="hi", badge="siren")
    run(mcp, "list_message_badges")
    assert last_request(holder)["op"] == "messages.badges"
