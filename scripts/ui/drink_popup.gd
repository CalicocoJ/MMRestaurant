extends Control
## 饮料机 UI（文档第十五节）。
##
## 动态读取 data/menu.json 的 drink_items 生成按钮。
##   点饮品   → 关 UI、恢复游戏、PlayerHand = 该饮品 id
##   点「取消」→ 关 UI、恢复游戏
##   点 UI 外面 → 无反应
##
## 【为什么没有「完成」】
## 文档给后厨 UI 配了「完成」，给饮料机 UI 只配了「取消」——
## 因为选一杯饮品本身就是最终决定，不需要再确认一次。

var router: Node = null

## 放饮品按钮的那一列（每次打开时按当前关卡重建，见 refresh_menu）
var _rows: VBoxContainer = null


func build(p_router: Node) -> void:
	router = p_router
	_build_ui()
	refresh_menu()


## 按**当前关卡**重建饮品按钮。
##
## 【必须在每次打开弹窗时调用，不能只在 build 时建一次】
## 菜单里有 start_level 解锁的饮品（柠檬水从第 3 关才有），
## 而同一个弹窗节点要跨关卡复用 —— 只建一次的话，第 3 关弹出时
## 还是第 1 关的菜单（少了柠檬水），玩家就永远买不到本关该有的饮品。
func refresh_menu() -> void:
	if _rows == null:
		return
	for c in _rows.get_children():
		_rows.remove_child(c)
		c.queue_free()
	for it in Config.drink_items_at(Game.level_index):
		var id := String(it["id"])
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(0, 46)
		btn.text = "  %s    %d 元" % [Config.item_name(id), Config.item_price(id)]
		btn.pressed.connect(_on_pick.bind(id))
		_rows.add_child(btn)


func _build_ui() -> void:
	# 全屏遮罩：点 UI 外面无反应。
	# 它会随弹窗根节点一起被撑满（见 UiManager._sync_root_size）。
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0, 0, 0, 0.55)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(340, 0)
	add_child(panel)
	PopupLayout.center_in_parent(panel, self)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	panel.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	margin.add_child(col)

	var title := Label.new()
	title.text = "饮料机"
	title.add_theme_font_size_override("font_size", 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)

	var hint := Label.new()
	hint.text = "选一杯，服务员会端着它去上菜"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Constants.COLOR_TEXT_DIM)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(hint)

	var rows := VBoxContainer.new()
	rows.name = "DrinkRows"
	rows.add_theme_constant_override("separation", 8)
	col.add_child(rows)
	_rows = rows

	var cancel := Button.new()
	cancel.text = "取消"
	cancel.custom_minimum_size = Vector2(0, 42)
	cancel.pressed.connect(_on_cancel)
	col.add_child(cancel)


func _on_pick(id: String) -> void:
	# 【到达时再检查】弹窗期间手上不会变，但容量判断只留这一个入口，
	# 避免以后容量改了漏改这里。
	if not Game.hand_has_room():
		Stickers.push(get_viewport().get_visible_rect().size * 0.5,
			Constants.MSG_HANDS_FULL, Constants.COLOR_TEXT)
		return
	router.ui.close_popups()
	router.take_into_hand(id)


func _on_cancel() -> void:
	router.ui.close_popups()
