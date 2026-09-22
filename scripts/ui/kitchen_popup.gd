extends Control
## 后厨 UI（文档第六节 + 第十五节）。
##
## 【布局（2026 改版，玩家指定）】
##
## ```text
##              后厨 · 点餐台
##      点方块加一份，队列里可单独删
##
##    ┌────┐   ┌────┐   ┌────┐
##    │ 🍔 │   │ 🍟 │   │ 🍗 │      ← 96×96 大方块（菜品图标）
##    └────┘   └────┘   └────┘
##    汉堡 15元  薯条 6元  炸鸡块 12元  ← 菜名 + 价格（一行）
##
##    队列： □ □ □ □ □ …             ← 本次已点、待提交，按点击顺序
##
##         [ 完成 ]   [ 取消 ]
## ```
##
## 交互：
##   * **点菜品方块 = 该菜 +1**（没有 −/+ 按钮了）；
##   * 点错了就去**队列**里找那一份：**对着它按鼠标右键**即删掉**这一份**；
##   * 队列**不限个数**，一行放不下自动换行；
##   * 「完成」按点击顺序入队（汉堡、薯条、汉堡 → [burger, fries, burger]）。
##
## 【为什么要改成这样】原来的布局是「一行一个菜：小色块 + 菜名(价格) + −/0/+」，
## 全是代码画的控件，换美术时几乎要重画一遍。现在每个菜品是一个**方块槽位**：
## 往 `assets/items/<id>.png` 放一张图就自动变成图标（`ItemArt` 已经支持），
## 面板本身也不需要改 —— 以后要换成贴图背景时，槽位尺寸和位置都不用动。
##
## 【为什么点方块而不是拖拽】文档要求「只用鼠标左键」，点击最直接；
## 拖拽在窗口化 / 触控板上都不稳。

## 队列小方块的脚本（右键删除交互在它自己身上，见 queue_tile.gd）
const QUEUE_TILE_SCRIPT := preload("res://scripts/ui/queue_tile.gd")

var router: Node = null

## 本次已点的**逐份**顺序（汉堡点两次 → [burger, burger]）。
## 【为什么不再是「种类顺序」】玩家要能删掉**指定那一份**：
## 按种类记数量（旧写法）没法区分「删第 1 个汉堡还是第 2 个」，
## 所以改成逐份列表，删哪份由下标决定。`build_queue()` 因此也变得直白。
var _queue: Array[String] = []
## 菜品方块本身（id -> Button），用来显示「已点 N 份」的小角标
var _slot_buttons: Dictionary = {}
## 队列容器（每次刷新重建里面的小方块）。用 FlowContainer：不限个数、自动换行
var _queue_box: FlowContainer = null
var _warn_label: Label = null

## 菜品方块边长（玩家指定 96×96）
const SLOT_SIZE := 96.0
## 队列小方块边长
const QUEUE_TILE := 46.0
## 队列最多显示几个（再多就换行；这里只是「一行放几个」的参考，实际由容器自动换行）
const QUEUE_WRAP_WIDTH := 380.0


func build(p_router: Node) -> void:
	router = p_router
	_build_ui()
	_reset()


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
	panel.custom_minimum_size = Vector2(460, 0)
	add_child(panel)
	PopupLayout.center_in_parent(panel, self)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	panel.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	margin.add_child(col)

	var title := Label.new()
	title.text = "后厨 · 点餐台"
	title.add_theme_font_size_override("font_size", 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)

	var hint := Label.new()
	# 玩家指定的提示文案（左键加、右键删都要说清楚）
	hint.text = "左键点击餐品加入制作队列；右键点击队列中的菜品可将其删除"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Constants.COLOR_TEXT_DIM)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(hint)

	# ── 菜品方块区 ──
	var dishes := HBoxContainer.new()
	dishes.name = "Dishes"
	dishes.alignment = BoxContainer.ALIGNMENT_CENTER
	dishes.add_theme_constant_override("separation", 14)
	col.add_child(dishes)

	for it in Config.kitchen_items:
		var id := String(it["id"])
		dishes.add_child(_make_dish_slot(id))

	# ── 队列区 ──
	var queue_wrap := PanelContainer.new()
	var qs := StyleBoxFlat.new()
	qs.bg_color = Color(0, 0, 0, 0.35)
	qs.corner_radius_top_left = 8
	qs.corner_radius_top_right = 8
	qs.corner_radius_bottom_left = 8
	qs.corner_radius_bottom_right = 8
	qs.content_margin_left = 10.0
	qs.content_margin_right = 10.0
	qs.content_margin_top = 6.0
	qs.content_margin_bottom = 6.0
	queue_wrap.add_theme_stylebox_override("panel", qs)
	col.add_child(queue_wrap)

	var qrow := HBoxContainer.new()
	qrow.add_theme_constant_override("separation", 10)
	queue_wrap.add_child(qrow)

	var qtitle := Label.new()
	qtitle.text = "队列："
	qtitle.add_theme_font_size_override("font_size", 16)
	qtitle.add_theme_color_override("font_color", Constants.COLOR_TEXT_DIM)
	qtitle.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	qtitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	qrow.add_child(qtitle)

	# 用一个 FlowContainer：不限个数，一行放不下自动换行（玩家要求）
	var flow := FlowContainer.new()
	flow.name = "QueueFlow"
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 6)
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flow.custom_minimum_size = Vector2(QUEUE_WRAP_WIDTH, QUEUE_TILE)
	# 【必须关掉裁剪】隐藏状态下容器被算过一次空布局，clip_contents 会在
	# 那个旧尺寸上留一块深色矩形伪影，正好压在队列那一行下面（截图确认过）。
	flow.clip_contents = false
	qrow.add_child(flow)
	_queue_box = flow

	# 队列容器的尺寸变化时重排一次，避免「看不见的旧尺寸」残留
	flow.resized.connect(func() -> void: flow.queue_sort())

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

	# 重新显示时重排一次：FlowContainer 的布局在隐藏状态下算过一次会留下
	# 一个「看不见的黑色矩形」，打开时正好压在队列那一行上（截图确认过）。
	visibility_changed.connect(_on_visibility_changed)


func _on_visibility_changed() -> void:
	if visible:
		_refresh()


## 一个菜品方块：96×96 图标槽 + 下方「菜名 价格」，整块可点（点一下 +1）
##
## 【为什么不用 Button 的 icon + text 直接做】
## `Button.expand_icon` 会把图标塞进「文字之外剩下的高度」——
## 实测 96px 高的按钮里图标只剩几个像素，方块根本看不见（截图确认过）。
## 所以改成：**自绘一个 96×96 的槽位面板**（里面放 ItemArt 的图标/占位色块），
## 下面单独一行标签，两者装进一个可点击的 Button 里。
## 这样槽位尺寸永远精确等于 96×96，换美术时只需往 assets/items/ 放图。
func _make_dish_slot(id: String) -> Control:
	var slot := Button.new()
	slot.name = "Slot_" + id
	slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE + 28.0)
	slot.tooltip_text = "%s %d元：点一下加一份" % [Config.item_name(id), Config.item_price(id)]
	slot.flat = true
	slot.focus_mode = Control.FOCUS_NONE

	var col := VBoxContainer.new()
	# 鼠标事件交给外层 Button（否则点在图标上不算点到按钮）
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 4)
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	slot.add_child(col)

	# 96×96 的槽位：固定尺寸的容器 + 裁剪（防止图标/角标溢出压到菜名上）
	var art_box := Control.new()
	art_box.name = "ArtBox"
	art_box.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	art_box.size = Vector2(SLOT_SIZE, SLOT_SIZE)
	art_box.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	art_box.clip_contents = true
	art_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(art_box)

	var art_panel := Panel.new()
	art_panel.name = "Art"
	art_panel.size = Vector2(SLOT_SIZE, SLOT_SIZE)
	art_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ps := StyleBoxFlat.new()
	ps.bg_color = Color(0, 0, 0, 0.30)
	ps.border_color = Color(1, 1, 1, 0.22)
	ps.set_border_width_all(2)
	ps.corner_radius_top_left = 8
	ps.corner_radius_top_right = 8
	ps.corner_radius_bottom_left = 8
	ps.corner_radius_bottom_right = 8
	art_panel.add_theme_stylebox_override("panel", ps)
	art_box.add_child(art_panel)

	# 图标画在槽位正中（留 8px 边距）。没美术时是 menu.json 里的占位色块。
	var art := ItemArt.make_node(id, Vector2(SLOT_SIZE - 16.0, SLOT_SIZE - 16.0))
	art.name = "Icon"
	art.size = Vector2(SLOT_SIZE - 16.0, SLOT_SIZE - 16.0)
	art.position = Vector2(8.0, 8.0)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art_panel.add_child(art)

	# 「已点 N 份」角标：0 份时隐藏（点一下就出现，一眼看出这一格选了几份）
	var badge := Label.new()
	badge.name = "Badge"
	badge.visible = false
	badge.custom_minimum_size = Vector2(22, 22)
	badge.size = Vector2(22, 22)
	badge.position = Vector2(SLOT_SIZE - 22.0, 0.0)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_theme_font_size_override("font_size", 13)
	badge.add_theme_color_override("font_color", Color(1, 1, 1))
	var bs := StyleBoxFlat.new()
	bs.bg_color = Color("2f7d4f")
	bs.corner_radius_top_left = 8
	bs.corner_radius_top_right = 8
	bs.corner_radius_bottom_left = 8
	bs.corner_radius_bottom_right = 8
	badge.add_theme_stylebox_override("normal", bs)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art_box.add_child(badge)

	# 菜名 + 价格合并成一行（玩家要求）
	var cap := Label.new()
	cap.name = "Caption"
	cap.text = "%s %d元" % [Config.item_name(id), Config.item_price(id)]
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.add_theme_font_size_override("font_size", 14)
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(cap)

	slot.pressed.connect(_add_one.bind(id))
	_slot_buttons[id] = slot
	return slot


## 队列里的一份：一个小方块，**右键点它删掉这一份**（详见 queue_tile.gd）
##
## 【为什么不做悬停 ✕ 了】做过两版都翻车：✕ 越界被邻居盖住；改用
## `visible` 切换浮现后，✕ 恰在鼠标下方 → 每帧「出现/消失」死循环 →
## 红叉闪烁 + 输入延迟，最后一版甚至点不动。右键删除不需要额外控件，
## 也不改变命中结果，是这里最稳的做法（玩家指定）。
func _make_queue_tile(index: int, id: String) -> Control:
	var tile: Control = Control.new()
	tile.set_script(QUEUE_TILE_SCRIPT)
	tile.name = "Tile"
	tile.set("box", Vector2(QUEUE_TILE, QUEUE_TILE))

	# 注意：子节点必须 IGNORE 鼠标，否则右键落在贴图上时方块收不到事件
	var art := ItemArt.make_node(id, Vector2(QUEUE_TILE, QUEUE_TILE))
	art.name = "Art"
	art.size = Vector2(QUEUE_TILE, QUEUE_TILE)
	art.position = Vector2.ZERO
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(art)

	tile.connect("remove_requested", func() -> void: _remove_at(index))
	return tile


# ── 交互 ───────────────────────────────────────────────────────────

## 点菜品方块：加一份（追加到队尾，保持「按点击顺序」）
func _add_one(id: String) -> void:
	_queue.append(id)
	_refresh()
	_clear_warn()


## 右键点了队列里某个小方块：删掉**那一份**
func _remove_at(index: int) -> void:
	if index < 0 or index >= _queue.size():
		return
	_queue.remove_at(index)
	_refresh()
	_clear_warn()


## 重建队列小方块 + 刷新菜品方块上的「已点 N 份」角标
func _refresh() -> void:
	# 菜品方块：角标显示已点份数（0 份隐藏）
	for id in _slot_buttons:
		var n := _count_of(String(id))
		var b: Button = _slot_buttons[id]
		b.tooltip_text = "%s %d元：点一下加一份（已点 %d 份）" % [
			Config.item_name(String(id)), Config.item_price(String(id)), n]
		var badge := b.find_child("Badge", true, false) as Label
		if badge != null:
			badge.text = str(n)
			badge.visible = n > 0

	if _queue_box == null:
		return
	for c in _queue_box.get_children():
		_queue_box.remove_child(c)
		c.queue_free()
	for i in _queue.size():
		_queue_box.add_child(_make_queue_tile(i, _queue[i]))


func _count_of(id: String) -> int:
	var n := 0
	for q in _queue:
		if q == id:
			n += 1
	return n


func _reset() -> void:
	_queue.clear()
	_refresh()
	_clear_warn()


func _clear_warn() -> void:
	if _warn_label != null:
		_warn_label.text = ""


func total_count() -> int:
	return _queue.size()


## 队列内容就是逐份列表本身（按点击顺序）
func build_queue() -> Array[String]:
	return _queue.duplicate()


func _on_confirm() -> void:
	if _queue.is_empty():
		if _warn_label != null:
			_warn_label.text = Constants.MSG_PICK_DISH_FIRST
		return
	var items := build_queue()
	var n := items.size()
	Game.enqueue_kitchen(items)
	Stickers.push(get_viewport().get_visible_rect().size * Vector2(0.5, 0.28),
		"后厨下单 %d 道" % n, Constants.COLOR_TEXT_DIM)
	router.ui.close_popups()
	_reset()


func _on_cancel() -> void:
	_reset()
	router.ui.close_popups()
