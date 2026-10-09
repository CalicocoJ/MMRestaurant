@tool
extends EntityBase
## 垃圾桶（文档第十一节）。
##
## 只能丢**手上**的餐品；出餐口的餐不能直接扔。
## 手上有餐 → 走过去 → 到达时再检查手上有餐 → 丢掉。
## 手上没餐 → 原地飘字「手上没有餐品」，连走都不走。

## 站位点相对**节点原点（家具左上角）**的偏移。
##
## 【为什么存偏移而不是世界坐标】家具可以被你拖到任意位置，
## 存世界坐标的话一拖动就失效（而且不报错，只是服务员走到老地方去）。
## 存偏移就自动跟着家具走。
@export var walk_offset: Vector2 = Vector2(90, 20)

## 服务员该站哪（世界坐标）。由 setup / setup_from_editor 填好，walk_to() 读它。
var _walk: Vector2 = Vector2.ZERO


func setup(p_rect: Rect2, p_walk: Vector2) -> void:
	kind = Constants.Kind.TRASH
	label = "垃圾桶"
	display_label = label
	position = p_rect.position
	rect_size = p_rect.size
	var col := Rect2(Vector2(0, p_rect.size.y * 0.15),
		Vector2(p_rect.size.x, p_rect.size.y * 0.85))
	setup_shape(Rect2(Vector2.ZERO, rect_size), col)
	body_color = Constants.COLOR_TRASH
	_walk = p_walk


## 碰撞盒：下部 85%（上部 15% 留空，让服务员能贴到桶身边上）。
func collision_box_local() -> Rect2:
	return Rect2(Vector2(0, rect_size.y * 0.15),
		Vector2(rect_size.x, rect_size.y * 0.85))


## 编辑器摆放后的自绑定：位置用节点自己的，尺寸和站位点用导出的。
func setup_from_editor() -> void:
	kind = Constants.Kind.TRASH
	label = "垃圾桶"
	display_label = label
	_clear_body_shapes()
	fit_rect_size_to_sprite()
	setup_shape(Rect2(Vector2.ZERO, rect_size), collision_box_local())
	body_color = Constants.COLOR_TRASH
	_walk = global_position + walk_offset


func walk_to() -> Vector2:
	return _walk


func accepts_click() -> bool:
	# 手上没餐也让它吃掉点击并飘字（文档：无反应，飘字「手上没有餐品」）
	return true


func interact(router: Node) -> int:
	if Game.hand_is_empty():
		router.say(Constants.MSG_HAND_EMPTY)
		return RouterResult.NO_ACTION
	router.go_then(_walk, Callable(self, "_do_trash"), "去垃圾桶")
	return RouterResult.ACCEPTED


## 到达时再检查手上有餐
func _do_trash(router: Node) -> bool:
	if Game.hand_is_empty():
		router.say(Constants.MSG_HAND_EMPTY)
		return false
	router.clear_hand()
	return true


func _draw() -> void:
	# 【编辑器里只画参考线】见 entity_base.gd 顶部「编辑器可视化」那一节。
	# 不画占位色块，免得盖住你自己贴的 Sprite2D。
	if Engine.is_editor_hint():
		_draw_gizmo_walk(walk_offset)
		return
	super._draw()
	var r := Rect2(Vector2.ZERO, rect_size)
	var cx := r.size.x * 0.5
	# 桶盖
	draw_rect(Rect2(cx - r.size.x * 0.42, r.size.y * 0.16, r.size.x * 0.84, 5),
		Color(1, 1, 1, 0.4))
	# 桶身竖纹
	for i in 3:
		var x := cx - 12.0 + 12.0 * float(i)
		draw_line(Vector2(x, r.size.y * 0.34), Vector2(x, r.size.y * 0.78),
			Color(1, 1, 1, 0.22), 2.0)
