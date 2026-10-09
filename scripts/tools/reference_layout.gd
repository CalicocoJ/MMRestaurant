@tool
extends Node2D
## 【临时参考工具】把**旧场景的布局**画成半透明平面图，供你在编辑器里对照摆家具。
##
## 【它解决什么问题】
## 原来地板/墙/家具都是 `floor_art.gd` + `layout.json` **用代码画**出来的：
## 色块地板、96px 高的墙、每件家具一个带文字的方块。
## 改成「你自己摆」之后，那些参考物**全都没有了** —— 于是你在编辑器里
## 面对一片空白，不知道房间该多大、家具该摆哪、占多大比例。
## 这个节点就是那层「消失的参考线」。
##
## 【怎么用】
##   1. 在 `Level` 下加一个 `Node2D`，挂上本脚本（名字随意，比如 `Reference`）
##   2. 勾选 `visible` 就看得到；取消勾选就隐藏
##   3. 摆好真家具后，**把这个节点整个删掉**（它只是脚手架，不参与游戏逻辑）
##
## 【为什么可以随时删】它不注册任何东西、不改任何状态、不参与点击与寻路 ——
## 纯粹是画在编辑器视口里的参考方块。
##
## 【注意：单位是旧世界的 1280×720】这些框的坐标来自 data/layout.json，
## 所以它们对得上「旧布局」的比例。你决定缩小世界时，这些框会整体偏大，
## 那时应该把它们当成「按比例参考」而不是「精确目标位置」。

const LAYOUT_PATH := "res://data/layout.json"

## 是否显示：**直接用 Node2D 的原生 `visible`**，不再自己定义。
##
## 【为什么这里删掉了原来的 `@export var visible`】
## `visible` 是 `Node2D` 的原生属性，重新定义它会直接解析失败：
##   `Member "visible" redefined (original in native class 'Node2D')`
## 而且用原生属性反而更好 —— 编辑器里节点旁边那个「眼睛」图标
## 就能直接开关它，比自己加一个布尔值顺手。
##
## 【注意】`_draw()` 里不需要 `if not visible: return` —— 引擎在节点不可见时
## 根本不会调用 `_draw()`，那种检查是多余的。

## 是否显示每件家具的文字标签（中文名 + 尺寸）。
@export var show_labels: bool = true:
	set(v):
		show_labels = v
		queue_redraw()

## 家具框的颜色。
@export var furniture_color: Color = Color(0.42, 0.78, 1.0, 0.20)
## 框线的颜色。
@export var outline_color: Color = Color(0.42, 0.78, 1.0, 0.75)
## 与旧地板网格一致的网格间距（旧视觉网格是 80px 一条）。
@export var grid_step: float = 80.0
## 是否画这个网格（帮你判断间距和对齐）。
@export var show_grid: bool = true

var _layout: Dictionary = {}
var _font: Font = null


func _ready() -> void:
	z_index = -50          # 画在家具下面，但在地板 TileMap(-100) 上面
	_load_layout()
	queue_redraw()


func _load_layout() -> void:
	if not FileAccess.file_exists(LAYOUT_PATH):
		return
	var txt := FileAccess.get_file_as_string(LAYOUT_PATH)
	var data: Variant = JSON.parse_string(txt)
	if typeof(data) == TYPE_DICTIONARY:
		_layout = data


func _get_font() -> Font:
	if _font == null:
		_font = UiFont.get_font()
	return _font


func _draw() -> void:
	var view := _view_size()

	if show_grid:
		_draw_grid(view)

	# 桌子（每张一个框）
	for entry in _layout.get("tables", []):
		_draw_box(_rect_of(entry.get("rect", [])), "桌%d" % int(entry.get("id", 0)))

	# 其余家具：rect 是主体，再补它的附属小矩形（出餐口 / 点餐铃 / 站位点）
	_draw_box(_rect_of(_layout.get("kitchen_window", {}).get("rect", [])), "后厨/点餐台")
	for key in ["pickup_rect", "bell_rect"]:
		var r := _rect_of(_layout.get("kitchen_window", {}).get(key, []))
		if r.size.x > 0.0:
			draw_rect(r, Color(1.0, 0.85, 0.3, 0.35), true)
			draw_rect(r, Color(1.0, 0.85, 0.3, 0.9), false, 1.0)

	_draw_box(_rect_of(_layout.get("drink_machine", {}).get("rect", [])), "饮料机")
	_draw_box(_rect_of(_layout.get("trash", {}).get("rect", [])), "垃圾桶")
	_draw_box(_rect_of(_layout.get("door", {}).get("rect", [])), "门口")

	# 站位点（服务员该站的地方）—— 绿色十字，帮你判断「有没有地方站」
	for key in ["kitchen_window", "drink_machine", "trash", "door"]:
		var d: Dictionary = _layout.get(key, {})
		for wk in ["walk", "pickup_walk", "spawn"]:
			var p := _point_of(d.get(wk, []))
			if p != Vector2.ZERO:
				_draw_marker(p)
	# 服务员出生点
	_draw_marker(_point_of(_layout.get("waiter_spawn", [])), Color(1.0, 0.5, 0.5, 0.95))


## 画地板网格（对应旧实现的每 80px 一条线）。
func _draw_grid(view: Vector2) -> void:
	var c := Color(0.55, 0.65, 0.8, 0.16)
	var x := 0.0
	while x <= view.x:
		draw_line(Vector2(x, 0), Vector2(x, view.y), c, 1.0)
		x += grid_step
	var y := 0.0
	while y <= view.y:
		draw_line(Vector2(0, y), Vector2(view.x, y), c, 1.0)
		y += grid_step


func _draw_box(r: Rect2, label: String) -> void:
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	draw_rect(r, furniture_color, true)
	draw_rect(r, outline_color, false, 1.5)
	if not show_labels:
		return
	var f := _get_font()
	if f == null:
		return
	var txt := "%s  %d×%d" % [label, int(r.size.x), int(r.size.y)]
	draw_string_outline(f, r.position + Vector2(4, 14), txt,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 3, Color(0, 0, 0, 0.8))
	draw_string(f, r.position + Vector2(4, 14), txt,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.95))


func _draw_marker(p: Vector2, col: Color = Color(0.5, 1.0, 0.5, 0.95)) -> void:
	draw_line(p - Vector2(7, 0), p + Vector2(7, 0), col, 2.0)
	draw_line(p - Vector2(0, 7), p + Vector2(0, 7), col, 2.0)
	draw_arc(p, 5.0, 0, TAU, 16, col, 1.5)


## 视口尺寸（兜底 1280×720，与工程视口一致）。grid 用它决定画多大范围。
func _view_size() -> Vector2:
	var vp := get_viewport()
	if vp != null:
		var s := vp.get_visible_rect().size
		if s.x > 0.0 and s.y > 0.0:
			return s
	return Vector2(1280, 720)


static func _rect_of(a: Variant) -> Rect2:
	if typeof(a) != TYPE_ARRAY or (a as Array).size() < 4:
		return Rect2()
	var arr: Array = a
	return Rect2(float(arr[0]), float(arr[1]), float(arr[2]), float(arr[3]))


static func _point_of(a: Variant) -> Vector2:
	if typeof(a) != TYPE_ARRAY or (a as Array).size() < 2:
		return Vector2.ZERO
	var arr: Array = a
	return Vector2(float(arr[0]), float(arr[1]))
