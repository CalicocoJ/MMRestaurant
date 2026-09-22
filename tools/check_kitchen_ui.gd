extends Node
## 后厨点单弹窗（2026 改版）体检：方块布局、点方块 +1、队列 ❌ 删指定那份。
##
## 用法：
##   godot --headless --path <project> res://tools/check_kitchen_ui.tscn
##
## 【为什么要单独一套】这段是**纯 UI 行为**：点方块累加、队列逐份可删、
## 提交顺序。它不属于「后厨做菜流程」（那是 check_kitchen_flow），
## 而 UI 改动最容易悄悄改坏的就是「点了没反应」和「删错那一份」。

var _ok := 0
var _bad := 0


func _ready() -> void:
	await get_tree().process_frame
	var lv: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(lv)
	lv.get_node("CustomerSpawner").set_process(false)
	await get_tree().physics_frame
	await get_tree().physics_frame

	print("")
	print("======== 后厨点单弹窗（方块版）========")
	var popup: Control = UI.kitchen_popup()
	_check(popup != null, "拿到后厨弹窗节点")
	if popup == null:
		_finish()
		return

	# 打开一次（走真实入口：点后厨大矩形会弹它，这里直接调 API 更稳）
	UI.open_kitchen()
	await get_tree().physics_frame
	_check(UI.is_any_popup_open(), "后厨弹窗已打开")

	# ── 1. 布局：每个后厨菜品一个 96×96 方块 ──
	var slots := _find_by_prefix(popup, "Slot_")
	var kinds := Config.kitchen_items.size()
	_check(slots.size() == kinds,
		"每个后厨菜品一个方块（期望 %d，实际 %d）" % [kinds, slots.size()])
	for s in slots:
		var b: Button = s
		_check(b.custom_minimum_size.y >= 96.0 and b.custom_minimum_size.x >= 96.0,
			"%s 方块尺寸够大（%.0f×%.0f）" % [b.name, b.custom_minimum_size.x, b.custom_minimum_size.y])

	# ── 2. 菜名 + 价格合并成一行（画在方块下面的 Caption 上，不在 Button.text）──
	var first: Button = slots[0]
	var dish_id := String(Config.kitchen_items[0]["id"])
	var cap := first.find_child("Caption", true, false) as Label
	_check(cap != null, "方块下面有菜名标签（Caption）")
	if cap != null:
		_check(cap.text.contains(Config.item_name(dish_id)) and cap.text.contains("元"),
			"菜名与价格合并成一行：%s" % cap.text)

	# ── 3. 点方块 = +1（点两次 = 两份，顺序保留）──
	popup.call("_add_one", "burger")
	popup.call("_add_one", "fries")
	popup.call("_add_one", "burger")
	await get_tree().physics_frame
	eq(int(popup.call("total_count")), 3, "点三次共 3 份")
	eq(popup.call("build_queue"), ["burger", "fries", "burger"] as Array[String],
		"提交顺序 = 点击顺序（汉堡、薯条、汉堡）")

	# ── 4/5. 队列小方块 + 右键删「指定的那一份」──
	#
	# 【交互改成右键了】原来做的「悬停浮现红 ✕」被玩家否掉：✕ 闪、输入延迟、
	# 最后甚至点不动（根因是用 `visible` 切换浮现造成每帧鼠标进出的死循环）。
	# 现在：左键点上面的菜品方块加一份；**对着队列小方块按右键**删掉那一份。
	# 所以断言也改成投递**右键按下**事件给方块自己。
	var tiles := _find_queue_tiles(popup)
	eq(tiles.size(), 3, "队列里有 3 个小方块")

	# 4a. 方块不再有任何子控件拦鼠标（否则右键落在贴图上时方块收不到事件）
	var has_blocking_child := false
	for c in (tiles[0] as Control).get_children():
		if (c as Control).mouse_filter != Control.MOUSE_FILTER_IGNORE:
			has_blocking_child = true
	_check(not has_blocking_child, "队列小方块的子节点都不拦鼠标（右键才能落到方块上）")

	# 4b. 悬停提示：告诉玩家「右键可删」
	_check(String((tiles[0] as Control).tooltip_text).contains("右键"),
		"方块自带悬停提示：%s" % (tiles[0] as Control).tooltip_text)

	# 4c. 左键不应删除（避免误触）
	var t0 := tiles[0] as Control
	t0.call("_gui_input", _mouse(MOUSE_BUTTON_LEFT))
	await get_tree().process_frame
	eq(popup.call("build_queue"), ["burger", "fries", "burger"] as Array[String],
		"左键点队列小方块 → 什么也不做（不会误删）")

	# 4d. 右键删掉「被点的那一份」
	var before: Array = popup.call("build_queue")
	# 【headless 下的取巧】脚本里试过 `gui_input.emit()`，但引擎并不把
	# 「手动 emit 这个内置信号」当成一次真实 GUI 输入（`_gui_input` 根本不被调）。
	# 而注入真实鼠标事件在无窗口模式下也进不了控件树（前面验证过）。
	# 所以这里直接调控件自己的 `_gui_input(event)` —— 走的正是真实点击时
	# 引擎会走的那段**游戏逻辑**（区别只是「谁来调用它」）。
	t0.call("_gui_input", _mouse(MOUSE_BUTTON_RIGHT))
	await get_tree().process_frame
	print("     [探针] 右键前后：%s → %s" % [str(before), str(popup.call("build_queue"))])
	eq(popup.call("build_queue"), ["fries", "burger"] as Array[String],
		"右键第 1 个小方块 → 只删掉那一份（剩薯条+汉堡）")
	eq(int(popup.call("total_count")), 2, "总数同步减少")

	# 4e. 再右键一份，证明删的是「那一份」而不是「该菜减一」
	# 【必须重新取引用】删除会 `_refresh()` 重建所有小方块，旧节点已释放
	var tiles_mid := _find_queue_tiles(popup)
	(tiles_mid[0] as Control).call("_gui_input", _mouse(MOUSE_BUTTON_RIGHT))
	await get_tree().process_frame
	eq(popup.call("build_queue"), ["burger"] as Array[String],
		"再右键第 1 个 → 只剩 1 份（证明删的是那一份，而不是该菜减一）")

	# ── 6. 空队列点「完成」→ 只提示、不关 UI ──
	# 【用「取消」清空而不是直接关掉】队列是**跨开关保留**的（防止误关丢单），
	# 所以要先走一次正规的「取消」把计数清零，再打开。
	popup.call("_on_cancel")
	await get_tree().physics_frame
	UI.open_kitchen()
	await get_tree().physics_frame
	eq(int(popup.call("total_count")), 0, "「取消」之后重新打开，队列是空的（不残留）")
	popup.call("_on_confirm")
	await get_tree().physics_frame
	_check(UI.is_any_popup_open(), "队列为空时点「完成」不关 UI")
	eq(String(popup.get("_warn_label").text), Constants.MSG_PICK_DISH_FIRST,
		"并提示「%s」" % Constants.MSG_PICK_DISH_FIRST)

	# ── 7. 取消会清空队列 ──
	popup.call("_add_one", "fries")
	await get_tree().physics_frame
	popup.call("_on_cancel")
	await get_tree().physics_frame
	_check(not UI.is_any_popup_open(), "点「取消」关掉 UI")
	eq(int(popup.call("total_count")), 0, "取消后队列清零（下次打开不残留）")
	_finish()


func _finish() -> void:
	print("--------------------------------")
	print("通过 %d / 失败 %d" % [_ok, _bad])
	print("================================")
	get_tree().quit(1 if _bad > 0 else 0)


## 造一个「鼠标按下」事件（默认左键）
func _mouse(button: int = MOUSE_BUTTON_LEFT) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = true
	return e


func _check(cond: bool, what: String) -> void:
	if cond:
		_ok += 1
		print("  [OK]   " + what)
	else:
		_bad += 1
		print("  [FAIL] " + what)


func eq(got: Variant, want: Variant, what: String) -> void:
	if got == want:
		_ok += 1
		print("  [OK]   " + what)
	else:
		_bad += 1
		print("  [FAIL] %s（期望 %s，实际 %s）" % [what, str(want), str(got)])


func _find_by_prefix(root: Node, prefix: String, out: Array = []) -> Array:
	for c in root.get_children():
		if String(c.name).begins_with(prefix):
			out.append(c)
		_find_by_prefix(c, prefix, out)
	return out


## 队列小方块 = QueueFlow 下的直接子节点
func _find_queue_tiles(popup: Control) -> Array:
	var flow := _find_by_prefix(popup, "QueueFlow")
	if flow.is_empty():
		return []
	return (flow[0] as Node).get_children()
