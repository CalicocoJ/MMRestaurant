extends SceneTree
## 只用来体检：把每个脚本单独 load 一遍，谁坏了就直接报出来。
## 用法： godot --headless --path <project> --script res://tools/check_scripts.gd

const FILES := [
	"res://scripts/core/constants.gd",
	"res://scripts/core/game_config.gd",
	"res://scripts/core/game_state.gd",
	"res://scripts/core/order.gd",
	"res://scripts/core/order_lines.gd",
	"res://scripts/core/kitchen.gd",
	"res://scripts/core/table_rules.gd",
	"res://scripts/core/click_router.gd",
	"res://scripts/world/world_object.gd",
	"res://scripts/world/entity_base.gd",
	"res://scripts/world/table.gd",
	"res://scripts/world/kitchen_window.gd",
	"res://scripts/world/drink_machine.gd",
	"res://scripts/world/trash.gd",
	"res://scripts/world/door.gd",
	"res://scripts/actors/waiter.gd",
	"res://scripts/actors/customer.gd",
	"res://scripts/ui/stickers.gd",
	"res://scripts/ui/hud.gd",
	"res://scripts/ui/order_panel.gd",
	"res://scripts/ui/kitchen_popup.gd",
	"res://scripts/ui/drink_popup.gd",
	"res://scripts/ui/ui_manager.gd",
	"res://scripts/ui/start_screen.gd",
	"res://scripts/ui/result_panel.gd",
	"res://scripts/ui/star_icon.gd",
	"res://scripts/level/customer_manager.gd",
	"res://scripts/level/floor_art.gd",
	"res://scripts/level/level.gd",
	# 测试与工具脚本也要体检。
	# 【为什么】run_tests.gd 曾经编译不过，导致整个测试**什么都不打印就挂住**，
	# 看起来像引擎卡死，实际是脚本没跑起来。少了这几行就查不到。
	"res://tools/run_tests.gd",
	"res://tools/screenshot.gd",
	"res://tools/dump_ui.gd",
	"res://tools/check_counter.gd",
	"res://tools/check_dim.gd",
	"res://tools/check_start.gd",
	"res://tools/check_order_rule.gd",
	"res://tools/check_clean_seat.gd",
	"res://tools/check_serve_hand.gd",
	"res://tools/check_level_mode.gd",
	"res://tools/check_kitchen_flow.gd",
	"res://tools/compare_pixels.gd",
]


func _initialize() -> void:
	var bad := 0
	for f in FILES:
		var res := ResourceLoader.load(f)
		if res == null:
			print("BAD   ", f)
			bad += 1
		else:
			print("ok    ", f)
	print("--- %d / %d ok ---" % [FILES.size() - bad, FILES.size()])
	quit(1 if bad > 0 else 0)
