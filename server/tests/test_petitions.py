import asyncio
import json

import pytest
from test_units import last_request, make, run

from df_mcp.bridge import Bridge
from df_mcp.server import build_server
from df_mcp.tools import petitions


class ScriptedClient:
    """Answers each request with the next scripted result (the last one repeats)."""

    def __init__(self, results):
        self.results = list(results)
        self.requests = []

    def connect(self):
        pass

    def close(self):
        pass

    def run_lua(self, module, function, args):
        self.requests.append(json.loads(args[0]))
        item = self.results.pop(0) if len(self.results) > 1 else self.results[0]
        if isinstance(item, tuple):
            return [json.dumps({"ok": False, "error": {"code": item[0], "message": item[1]}})]
        return [json.dumps({"ok": True, "result": item})]


def scripted(results):
    holder = {}

    def factory(host, port):
        holder["client"] = ScriptedClient(results)
        return holder["client"]

    return build_server(Bridge("h", 1, client_factory=factory)), holder


def result_of(output):
    return output.structured_content


@pytest.fixture(autouse=True)
def no_delay(monkeypatch):
    monkeypatch.setattr(petitions, "STEP_DELAY_S", 0)


def test_list_petitions_sends_limit_and_resolved():
    mcp, holder = make()
    run(mcp, "list_petitions")
    assert last_request(holder)["op"] == "petitions.list"
    assert last_request(holder)["args"] == {"limit": 25, "include_resolved": False}
    run(mcp, "list_petitions", limit=3, include_resolved=True)
    assert last_request(holder)["args"] == {"limit": 3, "include_resolved": True}


def test_list_petitions_refuses_bad_limit():
    mcp, holder = make()
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "list_petitions", limit=0)
    assert "client" not in holder


def test_answer_petition_single_call_when_done():
    mcp, holder = scripted(
        [{"done": True, "answered": True, "verified": True, "outcome": "accepted"}]
    )
    out = result_of(run(mcp, "answer_petition", id=7, accept=True))
    requests = holder["client"].requests
    assert len(requests) == 1
    assert requests[0]["op"] == "petitions.answer"
    assert requests[0]["args"] == {
        "id": 7,
        "accept": True,
        "unpause": False,
        "dry_run": False,
        "screen": False,
    }
    assert out["verified"] is True


def test_answer_petition_follows_stages_with_continue():
    mcp, holder = scripted(
        [
            {"done": False, "stage": "opening"},
            {"done": False, "stage": "ready"},
            {"done": False, "stage": "ready"},
            {"done": True, "answered": True, "verified": False, "outcome": "denied", "reason": "x"},
        ]
    )
    out = result_of(run(mcp, "answer_petition", id=9, accept=False, unpause=True))
    requests = holder["client"].requests
    assert len(requests) == 4
    assert "continue" not in requests[0]["args"]
    for req in requests[1:]:
        assert req["args"]["continue"] is True
        assert req["args"]["id"] == 9
        assert req["args"]["accept"] is False
        assert req["args"]["unpause"] is True
    assert out["verified"] is False
    assert out["outcome"] == "denied"


def test_answer_petition_cancels_after_max_steps(monkeypatch):
    monkeypatch.setattr(petitions, "MAX_STEPS", 3)
    mcp, holder = scripted(
        [
            {"done": False, "stage": "ready"},
            {"done": False, "stage": "ready"},
            {"done": False, "stage": "ready"},
            {"done": False, "stage": "ready"},
            {"done": True, "cancelled": True, "answered": False, "verified": False},
        ]
    )
    out = result_of(run(mcp, "answer_petition", id=9, accept=True))
    requests = holder["client"].requests
    assert requests[-1]["args"] == {"cancel": True}
    assert out["answered"] is False
    assert out["verified"] is False
    assert "did not reach the answer" in out["reason"]


def test_answer_petition_dry_run_and_screen_check():
    mcp, holder = scripted([{"done": True, "dry_run": True}])
    run(mcp, "answer_petition", id=7, accept=True, dry_run=True)
    args = holder["client"].requests[-1]["args"]
    assert args["dry_run"] is True and args["screen"] is False
    run(mcp, "answer_petition", id=7, accept=False, screen_check=True)
    args = holder["client"].requests[-1]["args"]
    assert args["dry_run"] is True and args["screen"] is True


def test_answer_petition_passes_errors_through():
    mcp, holder = scripted([("NOT_FOUND", "no pending petition has id 99; see list_petitions")])
    with pytest.raises(Exception, match="NOT_FOUND"):
        asyncio.run(mcp.call_tool("answer_petition", {"id": 99, "accept": True}))
    assert len(holder["client"].requests) == 1


def test_answer_petition_refuses_bad_args():
    mcp, holder = make()
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "answer_petition", id="seven", accept=True)
    with pytest.raises(Exception):  # noqa: B017
        run(mcp, "answer_petition", id=7, accept="maybe")
    assert "client" not in holder
