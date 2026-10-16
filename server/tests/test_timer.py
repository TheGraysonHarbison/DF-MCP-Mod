from test_units import last_request, make, run

from df_mcp.channel import format_batch


def test_timer_status_tool():
    mcp, holder = make()
    run(mcp, "get_timer_status")
    assert last_request(holder)["op"] == "timer.status"


def test_timer_batch_is_the_prompt():
    content, meta = format_batch(
        {"events": [{"seq": 9, "kind": "timer", "text": "# Update\nTime has passed."}]}
    )
    assert content == "# Update\nTime has passed."
    assert meta["kind"] == "timer"
