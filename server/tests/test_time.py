from test_units import last_request, make, run


def test_get_time_sends_op():
    mcp, holder = make()
    run(mcp, "get_time")
    assert last_request(holder)["op"] == "time.now"


def test_set_paused_sends_boolean():
    mcp, holder = make()
    run(mcp, "set_paused", paused=True)
    request = last_request(holder)
    assert request["op"] == "time.set_pause"
    assert request["args"] == {"paused": True}
    run(mcp, "set_paused", paused=False)
    assert last_request(holder)["args"] == {"paused": False}
