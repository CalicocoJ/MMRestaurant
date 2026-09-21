extends Control
## 后厨 UI（文档第六节 + 第十五节）。
##
## 动态读取 data/menu.json 的 kitchen_items 生成按钮 + 计数。
##   点餐品按钮  → 该餐品计数 +1
##   点「完成」   → 全为 0 则提示「请先点菜」；否则按点击顺序入队、关 UI、恢复游戏
##   点「取消」   → 关 UI、恢复游戏、计数清零
##   点 UI 外面   → 无反应（由全屏遮罩吃掉点击实现）
##
## 【为什么要记住点击顺序】
## 文档说「按点击顺序加入 KitchenQueue」。所以除了计数，
## 还维护一个 _order 列表：第一次点某道菜时才把 id 追加进去。
## 这样点「汉堡 → 薯条 → 汉堡」出来的是 [burger, fries, burger] 的
## 制作顺序语义（数量对得上，顺序也说得通）。

var router: Node = null

var _counts: Dictionary = {}
var _order: Array[String] = []
var _labels: Dictionary = {}      ## id -> Label（显示数量）
var _rows: VBoxContainer = null
var _warn_label: Label = null


func build(p_router: Node) -> void:
	router = p_router
	_build_ui()
	_reset_counts()


func _build_ui() -> void:
	# 全屏遮罩：点 UI 外面无反应。
	# 它会随弹窗根节点一起被撑满（见 UiManager._sync_root_size），
	# 这里不需要设锚点 —— CanvasLayer 下的 Control 锚点算不准。
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0, 0, 0, 0.55)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(420, 0)
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
	title.text = "后厨 · 点餐台"
	title.add_theme_font_size_override("font_size", 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)

	var hint := Label.new()
	hint.text = "点餐品加数量，点「完成」按顺序下单给后厨"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Constants.COLOR_TEXT_DIM)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(hint)

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 8)
	col.add_child(_rows)

	for it in Config.kitchen_items:
		_add_dish_row(String(it["id"]))

	# 底部提示（「请先点菜」显示在这里，不关 UI）
	var warn := Label.new()
	warn.text = ""
	warn.add_theme_font_size_override("font_size", 14)
	warn.add_theme_color_override("font_color", Color("ff8b7a"))
	warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(warn)
	_warn_label = warn

	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	btns.add_theme_constant_override("separation", 16)
	col.add_child(btns)

	var ok := Button.new()
	ok.text = "完成"
	ok.custom_minimum_size = Vector2(130, 42)
	ok.pressed.connect(_on_confirm)
	btns.add_child(ok)

	var cancel := Button.new()
	cancel.text = "取消"
	cancel.custom_minimum_size = Vector2(130, 42)
	cancel.pressed.connect(_on_cancel)
	btns.add_child(cancel)


func _add_dish_row(id: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_rows.add_child(row)

	# 菜品小图：走 ItemArt —— 以后往 assets/items/ 放图片就自动变成 sprite，
	# 不用改这里（原来写死了一个 ColorRect）。
	var swatch := ItemArt.make_node(id, Vector2(18, 18))
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(swatch)

	var name_label := Label.new()
	name_label.text = "%s（%d 元）" % [Config.item_name(id), Config.item_price(id)]
	name_label.custom_minimum_size = Vector2(150, 0)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	var minus := Button.new()
	minus.text = "−"
	minus.custom_minimum_size = Vector2(40, 34)
	minus.pressed.connect(_bump.bind(id, -1))
	row.add_child(minus)

	var count := Label.new()
	count.text = "0"
	count.custom_minimum_size = Vector2(44, 0)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_labels[id] = count
	row.add_child(count)

	var plus := Button.new()
	plus.text = "+"
	plus.custom_minimum_size = Vector2(40, 34)
	plus.pressed.connect(_bump.bind(id, 1))
	row.add_child(plus)


# ── 交互 ───────────────────────────────────────────────────────────

func _bump(id: String, amount: int) -> void:
	var n := int(_counts.get(id, 0)) + amount
	if n < 0:
		n = 0
	_counts[id] = n
	if amount > 0 and n == 1:
		# 第一次点这道菜 → 记下它在厨房队列里的先后
		_order.append(id)
	if n == 0:
		_order.erase(id)
	_refresh()
	_clear_warn()


func _refresh() -> void:
	for id in _labels:
		var l: Label = _labels[id]
		l.text = str(int(_counts.get(id, 0)))


func _reset_counts() -> void:
	_counts.clear()
	_order.clear()
	for it in Config.kitchen_items:
		_counts[String(it["id"])] = 0
	_refresh()
	_clear_warn()


func _warn() -> Label:
	return _warn_label


func _clear_warn() -> void:
	if _warn_label != null:
		_warn_label.text = ""


func total_count() -> int:
	var n := 0
	for id in _counts:
		n += int(_counts[id])
	return n


## 按点击顺序展开成餐品 id 列表：汉堡×2、薯条×1 → [burger, burger, fries]
func build_queue() -> Array[String]:
	var out: Array[String] = []
	for id in _order:
		for i in int(_counts.get(id, 0)):
			out.append(id)
	return out


func _on_confirm() -> void:
	if total_count() <= 0:
		if _warn_label != null:
			_warn_label.text = Constants.MSG_PICK_DISH_FIRST
		return
	var items := build_queue()
	var n := items.size()
	Game.enqueue_kitchen(items)
	Stickers.push(get_viewport().get_visible_rect().size * Vector2(0.5, 0.28),
		"后厨下单 %d 道" % n, Constants.COLOR_TEXT_DIM)
	router.ui.close_popups()
	_reset_counts()


func _on_cancel() -> void:
	_reset_counts()
	router.ui.close_popups()
