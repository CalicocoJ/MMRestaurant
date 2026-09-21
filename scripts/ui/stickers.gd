extends CanvasLayer
## 飘字提示（autoload 名 = Stickers）。
##
## 文档第十四节：飘字最多 5 条；第十七节：暂停期间飘字不消失。
##
## 【为什么是 CanvasLayer 而不是 Control】
## 飘字要被屏幕坐标定位（"+15 元 · 结账"跟着桌子走），
## 用 CanvasLayer 画在最上层最省事，也天生不受世界坐标缩放影响。
##
## 【暂停时为什么不消失】
## 本节点 process_mode = ALWAYS，所以 get_tree().paused 拦不住它。
## 但那样它就会在弹窗期间自己飘完消失 —— 文档说「不消失」，
## 所以暂停时把生命周期计时也冻住，恢复后再继续飘。

const LIFETIME := 1.5
const RISE := 46.0

class Sticker extends RefCounted:
	var text: String
	var color: Color
	var pos: Vector2
	var age: float = 0.0


var _items: Array[Sticker] = []
var _font: Font = null
var _max: int = 5

var _layer: Control = null


func _ready() -> void:
	layer = 20
	_max = Constants.MAX_STICKERS
	# 暂停时也要继续处理，否则「飘字不消失」无法实现
	process_mode = Node.PROCESS_MODE_ALWAYS

	_layer = Control.new()
	_layer.name = "StickerLayer"
	_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_layer.draw.connect(_draw_all)
	add_child(_layer)


func _process(delta: float) -> void:
	if get_tree().paused:
		# 冻结生命周期，也不重绘
		return
	if _items.is_empty():
		return
	for s in _items:
		s.age += delta
	# 从后往前删，避免下标错位
	for i in range(_items.size() - 1, -1, -1):
		if _items[i].age >= LIFETIME:
			_items.remove_at(i)
	_layer.queue_redraw()


## 在屏幕坐标处推一条飘字
func push(screen_pos: Vector2, text: String, color: Color = Constants.COLOR_TEXT) -> void:
	# 同类提示叠太多会糊成一片：同文本时只刷新最上面那条
	if not _items.is_empty() and _items[_items.size() - 1].text == text:
		var top: Sticker = _items[_items.size() - 1]
		top.age = 0.0
		top.pos = screen_pos
		top.color = color
		_layer.queue_redraw()
		return

	var s := Sticker.new()
	s.text = text
	s.color = color
	s.pos = screen_pos
	_items.append(s)
	while _items.size() > _max:
		_items.pop_front()
	_layer.queue_redraw()


## 世界坐标 → 屏幕坐标
func push_world(world_pos: Vector2, text: String, color: Color = Constants.COLOR_TEXT) -> void:
	var vp := _layer.get_viewport()
	if vp == null:
		push(world_pos, text, color)
		return
	push(vp.get_canvas_transform() * world_pos, text, color)


func clear() -> void:
	_items.clear()
	if _layer != null:
		_layer.queue_redraw()


func count() -> int:
	return _items.size()


## 最近一条飘字的文本（没有则空串）。给测试断言提示文案用。
func last_text() -> String:
	if _items.is_empty():
		return ""
	return _items[_items.size() - 1].text


func _draw_all() -> void:
	var f := _project_font()
	if f == null:
		return
	var fs := 16
	# 从旧到新依次向下错开，避免完全重叠
	var slot := 0
	for i in range(_items.size() - 1, -1, -1):
		var s: Sticker = _items[i]
		var t := clampf(s.age / LIFETIME, 0.0, 1.0)
		var alpha := 1.0 if t < 0.6 else (1.0 - (t - 0.6) / 0.4)
		var pos := s.pos + Vector2(0, -RISE * t + slot * 20.0)
		var size := f.get_string_size(s.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		var at := pos - Vector2(size.x * 0.5, 0)
		var c := s.color
		c.a *= alpha
		_layer.draw_string_outline(f, at, s.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4,
			Color(0, 0, 0, 0.75 * alpha))
		_layer.draw_string(f, at, s.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, c)
		slot += 1


func _project_font() -> Font:
	if _font == null:
		_font = UiFont.get_font()
	return _font
