import asyncio

from df_mcp.bridge import Bridge
from df_mcp.server import build_server


def test_server_registers_expected_tools():
    mcp = build_server(Bridge("h", 1, client_factory=lambda h, p: None))
    tools = asyncio.run(mcp.list_tools())
    names = {t.name for t in tools}
    assert names == {
        "ping",
        "get_permissions",
        "get_time",
        "list_units",
        "list_citizens",
        "list_domesticated",
        "list_others",
        "find_unit",
        "get_unit",
        "get_unit_sheet",
        "get_unit_full_sheet",
        "set_unit_nickname",
        "list_nobles",
        "assign_noble",
        "get_stock_bar",
        "list_stocks",
        "find_items",
        "list_artifacts",
        "get_fort_status",
        "list_work_orders",
        "get_work_order",
        "find_job_types",
        "create_work_order",
        "edit_work_order",
        "delete_work_order",
        "list_workshops",
        "get_workshop",
        "run_console_command",
    }
    by_name = {t.name: t for t in tools}
    assert by_name["list_units"].annotations.read_only_hint is True
    assert by_name["run_console_command"].annotations.destructive_hint is True
    assert "unit_id" in by_name["get_unit"].input_schema["properties"]
    nick = by_name["set_unit_nickname"].annotations
    assert nick.read_only_hint is False
    assert nick.destructive_hint is False
    assert nick.idempotent_hint is True
    assert by_name["assign_noble"].annotations.read_only_hint is False
    assert by_name["list_nobles"].annotations.read_only_hint is True
    assert by_name["delete_work_order"].annotations.destructive_hint is True
    assert by_name["create_work_order"].annotations.destructive_hint is False
