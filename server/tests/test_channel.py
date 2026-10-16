import asyncio
import json

from mcp.shared.message import SessionMessage
from mcp_types import JSONRPCRequest
from test_units import last_request, make, run

from df_mcp.bridge import Bridge
from df_mcp.channel import (
    NOTIFICATION_METHOD,
    EventPoller,
    format_batch,
    is_pre_initialize_probe,
    notification,
)


def test_format_batch_lists_events_with_positions_and_ids():
    result = {
        "tick": 1200,
        "events": [
            {"seq": 5, "kind": "mineral_discovered", "text": "You have struck native gold!",
             "pos": {"x": 1, "y": 2, "z": 3}},
            {"seq": 6, "kind": "units_fighting", "text": "A attacks B", "unit_ids": [10, 11]},
            {"seq": 7, "kind": "petition", "text": "A location petition awaits an answer",
             "extra": {"agreement_id": 44}},
        ],
        "remaining": 2,
        "dropped": 0,
    }
    content, meta = format_batch(result)
    lines = content.splitlines()
    assert lines[0].startswith("Dwarf Fortress events: 3 (seq 5-7, game tick 1200).")
    assert lines[1] == "- [mineral_discovered] You have struck native gold! at (1,2,3)"
    assert lines[2] == "- [units_fighting] A attacks B units 10,11"
    assert lines[3] == "- [petition] A location petition awaits an answer agreement 44"
    assert "2 more waiting" in lines[4]
    assert meta == {
        "kind": "events",
        "count": "3",
        "first_seq": "5",
        "last_seq": "7",
        "kinds": "mineral_discovered petition units_fighting",
    }


def test_format_batch_names_migrant_newcomers():
    # Recorded shape of an events.poll batch carrying one migrant wave.
    result = {
        "tick": 40321,
        "events": [
            {"seq": 12, "kind": "migrants_arrived", "tick": 40310,
             "text": "Some migrants have arrived.", "unit_ids": [301, 302],
             "extra": {"announcement": "MIGRANT_ARRIVAL",
                       "new_citizens": [
                           {"id": 301, "name": "Urist McMiner", "profession": "Miner"},
                           {"id": 302, "name": "Doren Ustuthbomrek", "profession": "Peasant"},
                       ],
                       "new_citizens_count": 2, "new_citizens_truncated": False,
                       "note": "a birth in the same hundred ticks would also be listed"}},
        ],
        "remaining": 0,
        "dropped": 0,
    }
    content, meta = format_batch(result)
    lines = content.splitlines()
    assert lines[1] == (
        "- [migrants_arrived] Some migrants have arrived. units 301,302 "
        "newcomers: Urist McMiner (Miner), Doren Ustuthbomrek (Peasant)"
    )
    assert meta["kinds"] == "migrants_arrived"


def test_format_batch_no_migrants_renders_cleanly():
    result = {
        "tick": 80000,
        "events": [
            {"seq": 20, "kind": "migrants_arrived",
             "text": ("No one even considered making the journey to such a cold, "
                      "desolate place this season."),
             "extra": {"announcement": "D_NO_MIGRANT_ARRIVAL", "new_citizens": [],
                       "new_citizens_count": 0, "new_citizens_truncated": False}},
            {"seq": 21, "kind": "migrants_arrived", "text": "Migrants arrived.",
             "extra": {"announcement": "MIGRANT_ARRIVAL", "new_citizens": {},
                       "new_citizens_count": 0}},
        ],
    }
    content, _ = format_batch(result)
    lines = content.splitlines()
    assert lines[1] == (
        "- [migrants_arrived] No one even considered making the journey to such a cold, "
        "desolate place this season."
    )
    assert lines[2] == "- [migrants_arrived] Migrants arrived."
    assert "newcomers" not in content


def test_format_batch_newcomers_truncated():
    people = [{"id": i, "name": f"Dwarf {i}", "profession": None} for i in range(25)]
    result = {"tick": 1, "events": [
        {"seq": 1, "kind": "migrants_arrived", "text": "Migrants",
         "extra": {"new_citizens": people, "new_citizens_count": 30,
                   "new_citizens_truncated": True}},
    ]}
    content, _ = format_batch(result)
    assert content.splitlines()[1].endswith("Dwarf 24 and 5 more")
    assert "Dwarf 0, Dwarf 1," in content


def test_notification_shape():
    msg = notification("hello", {"kind": "events"})
    data = msg.message.model_dump(by_alias=True, exclude_none=True)
    assert data == {
        "jsonrpc": "2.0",
        "method": NOTIFICATION_METHOD,
        "params": {"content": "hello", "meta": {"kind": "events"}},
    }


class ScriptedClient:
    def __init__(self, host, port):
        self.requests = []
        self.replies = []

    def connect(self):
        pass

    def close(self):
        pass

    def run_lua(self, module, function, args):
        self.requests.append(json.loads(args[0]))
        return [json.dumps({"ok": True, "result": self.replies.pop(0)})]


def test_poller_establishes_sequence_then_sends_batches():
    holder = {}

    def factory(host, port):
        holder["client"] = ScriptedClient(host, port)
        return holder["client"]

    bridge = Bridge("h", 1, client_factory=factory)
    sent = []

    async def send(msg):
        sent.append(msg)

    poller = EventPoller(bridge, send, poll_seconds=0, startup_delay=0)
    bridge._ensure_client()  # noqa: SLF001
    client = holder["client"]
    client.replies = [
        {"next_seq": 8, "events": [], "waiting": 0},
        {"next_seq": 8, "events": [], "waiting": 0},
        {"next_seq": 10, "events": [{"seq": 8, "kind": "petition", "text": "p"},
                                    {"seq": 9, "kind": "sparring", "text": "s"}],
         "last_seq": 9, "remaining": 0, "tick": 5},
    ]
    assert poller.step() is None
    assert client.requests[-1]["args"] == {}
    assert poller.after_seq == 7
    assert poller.step() is None
    assert client.requests[-1]["args"] == {"after_seq": 7}
    result = poller.step()
    assert result is not None and poller.after_seq == 9
    content, meta = format_batch(result)
    asyncio.run(send(notification(content, meta)))
    assert sent[0].message.params["meta"]["count"] == "2"


def test_poller_rewinds_when_sequence_restarts():
    holder = {}

    def factory(host, port):
        holder["client"] = ScriptedClient(host, port)
        return holder["client"]

    bridge = Bridge("h", 1, client_factory=factory)
    poller = EventPoller(bridge, lambda m: None, poll_seconds=0, startup_delay=0)
    bridge._ensure_client()  # noqa: SLF001
    client = holder["client"]
    poller.after_seq = 40
    client.replies = [
        {"next_seq": 3, "events": [], "waiting": 0},
        {"next_seq": 3, "events": [{"seq": 1, "kind": "timer", "text": "t"},
                                   {"seq": 2, "kind": "petition", "text": "p"}],
         "last_seq": 2, "remaining": 0, "tick": 1},
    ]
    result = poller.step()
    assert client.requests[-1]["args"] == {"after_seq": 0}
    assert result is not None and poller.after_seq == 2


def test_event_tools_send_args():
    mcp, holder = make()
    run(mcp, "list_event_kinds")
    assert last_request(holder)["op"] == "events.kinds"
    run(mcp, "poll_events")
    assert last_request(holder)["args"] == {"limit": 50, "force": False}
    run(mcp, "poll_events", after_seq=12, limit=10, force=True)
    assert last_request(holder)["args"] == {"after_seq": 12, "limit": 10, "force": True}


def test_probe_before_initialize_is_refused_but_initialize_passes():
    probe = SessionMessage(
        JSONRPCRequest(
            jsonrpc="2.0", id=1, method="server/discover",
            params={"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}},
        )
    )
    init = SessionMessage(JSONRPCRequest(jsonrpc="2.0", id=2, method="initialize", params={}))
    assert is_pre_initialize_probe(probe, False) is probe.message
    assert is_pre_initialize_probe(init, False) is None
    assert is_pre_initialize_probe(probe, True) is None
