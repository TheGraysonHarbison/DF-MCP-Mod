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
        "list_hotkeys",
        "set_hotkey",
        "clear_hotkey",
        "get_time",
        "set_paused",
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
        "list_work_details",
        "assign_work_detail",
        "set_work_detail_mode",
        "list_squads",
        "get_squad",
        "create_squad",
        "rename_squad",
        "set_squad_symbol",
        "add_to_squad",
        "remove_from_squad",
        "set_squad_leader",
        "disband_squad",
        "order_squad",
        "set_squad_routine",
        "list_routes",
        "create_route",
        "get_squad_equipment",
        "set_squad_uniform",
        "set_squad_ammo",
        "get_stock_bar",
        "list_stocks",
        "find_items",
        "list_artifacts",
        "get_fort_status",
        "list_kitchen",
        "list_farms",
        "get_farm",
        "set_farm_crops",
        "set_kitchen",
        "list_work_orders",
        "get_work_order",
        "find_job_types",
        "create_work_order",
        "edit_work_order",
        "delete_work_order",
        "list_workshops",
        "get_workshop",
        "list_workshop_tasks",
        "add_workshop_job",
        "set_workshop_job",
        "cancel_workshop_job",
        "get_map_bounds",
        "get_wagon",
        "get_tile",
        "get_area_map",
        "find_build_space",
        "find_exposed_walls",
        "list_designations",
        "list_plants",
        "plan_dig",
        "designate_dig",
        "erase_designations",
        "place_workshop",
        "list_building_materials",
        "plan_construction",
        "place_construction",
        "list_buildings",
        "suspend_building",
        "remove_constructions",
        "list_zones",
        "get_zone",
        "create_zone",
        "edit_zone",
        "assign_zone",
        "unassign_zone",
        "delete_zone",
        "plan_furniture",
        "place_furniture",
        "remove_building",
        "list_stockpiles",
        "get_stockpile",
        "list_stockpile_presets",
        "create_stockpile",
        "configure_stockpile",
        "rename_stockpile",
        "delete_stockpile",
        "run_console_command",
        "list_event_kinds",
        "poll_events",
        "list_popups",
        "close_popup",
        "get_plan_info",
        "read_plan",
        "write_plan",
        "append_plan",
        "read_goals",
        "send_message",
        "list_message_badges",
        "get_timer_status",
        "list_caravans",
        "get_trade_depot",
        "get_broker",
        "request_broker",
        "bring_to_depot",
        "cancel_bring",
        "offer_trade",
        "get_trade_screen",
        "select_trade_goods",
        "open_trade_screen",
        "press_trade",
        "list_diplomats",
        "get_trade_request_options",
        "set_trade_requests",
        "get_meeting_dialog",
        "open_meeting_dialog",
        "step_meeting_dialog",
        "list_mods",
        "dev_create_item",
        "dev_exterminate",
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
    assert by_name["list_work_details"].annotations.read_only_hint is True
    assert by_name["assign_work_detail"].annotations.read_only_hint is False
    assert by_name["delete_work_order"].annotations.destructive_hint is True
    assert by_name["create_work_order"].annotations.destructive_hint is False


def test_every_tool_has_a_description():
    # A description built as ("text" + SHARED) in the function body is an expression,
    # not a docstring, and the tool reaches the client with none (P2-4.0).
    mcp = build_server(Bridge("h", 1, client_factory=lambda h, p: None))
    tools = asyncio.run(mcp.list_tools())
    missing = [t.name for t in tools if not (t.description or "").strip()]
    assert missing == []


def test_shared_doc_text_reaches_the_tools():
    from df_mcp.tools.construct import SHAPE_DOC
    from df_mcp.tools.dig import BOX_DOC
    from df_mcp.tools.furniture import DOC
    from df_mcp.tools.zones import SETTINGS_DOC

    mcp = build_server(Bridge("h", 1, client_factory=lambda h, p: None))
    by_name = {t.name: t.description or "" for t in asyncio.run(mcp.list_tools())}

    def first_line(text: str) -> str:
        return text.splitlines()[0].strip()

    for names, shared in (
        (("plan_dig", "designate_dig"), BOX_DOC),
        (("plan_furniture", "place_furniture"), DOC),
        (("plan_construction", "place_construction"), SHAPE_DOC),
        (("create_zone", "edit_zone"), SETTINGS_DOC),
    ):
        for name in names:
            assert first_line(shared) in by_name[name], name
    assert "whole map" in by_name["plan_dig"]
    assert "64 by 64" not in by_name["designate_dig"]
