"""Exercise every bridge op against a running Dwarf Fortress with the mod enabled.

Run from the repo root: uv run --project server python tools/smoke-test.py [--enable]
"""

from __future__ import annotations

import argparse
import json
import os
import sys

from df_mcp.bridge import Bridge, BridgeError
from df_mcp.dfhack_rpc import DFHackClient, RpcError


def show(label: str, value: object) -> None:
    print(f"== {label}")
    print(json.dumps(value, indent=2, sort_keys=True)[:2000])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=os.environ.get("DFHACK_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("DFHACK_PORT", "5000")))
    parser.add_argument("--enable", action="store_true", help="run 'enable claude-bridge' first")
    args = parser.parse_args()

    client = DFHackClient(args.host, args.port)
    try:
        client.connect()
    except OSError as exc:
        print(f"cannot connect to DFHack at {args.host}:{args.port}: {exc}", file=sys.stderr)
        return 1
    print("DFHack", client.get_version(), "DF", client.get_df_version())
    if args.enable:
        try:
            reply = client.run_command("enable", ["claude-bridge"])
            print(reply.output.strip())
        except RpcError as exc:
            print(exc, file=sys.stderr)
    client.close()

    bridge = Bridge(args.host, args.port)
    failures = 0
    for op, op_args in [
        ("core.ping", {}),
        ("settings.get", {}),
        ("time.now", {}),
        ("time.set_pause", {"paused": True}),
        ("build.materials", {"limit": 5}),
        ("build.plan_construction", {"kind": "wall", "line": {"x1": 2, "y1": 2, "x2": 6, "y2": 2, "z": 0}}),
        ("build.plan_furniture", {"type": "bed", "x": 2, "y": 2, "z": 0}),
        ("build.list", {"limit": 5}),
        ("units.list", {"limit": 5}),
        ("units.list", {"bucket": "citizen", "limit": 3}),
        ("units.list", {"bucket": "domesticated", "limit": 3}),
        ("units.list", {"bucket": "other", "limit": 3}),
        ("units.find", {"query": "cat", "limit": 3}),
        ("console.run", {"command": "ls"}),
        ("nope.nothing", {}),
    ]:
        try:
            result = bridge.call(op, op_args)
            show(f"{op} {op_args}", result)
            if op == "units.list" and result.get("units"):
                first = result["units"][0]["id"]
                show(f"units.get {first}", bridge.call("units.get", {"id": first}))
        except BridgeError as exc:
            expected = op == "nope.nothing" or (
                op in ("console.run", "time.set_pause") and exc.code == "NOT_ALLOWED"
            )
            print(f"== {op} {op_args}\n{'expected ' if expected else ''}error {exc.code}: {exc.message}")
            if not expected:
                failures += 1
    bridge.close()
    print("done,", failures, "unexpected failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
