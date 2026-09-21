extends EntityBase
## 垃圾桶（文档第十一节）。
##
## 只能丢**手上**的餐品；出餐口的餐不能直接扔。
## 手上有餐 → 走过去 → 到达时再检查手上有餐 → 丢掉。
## 手上没餐 → 原地飘字「手上没有餐品」，连走都不走。

var rect_size: Vector2 = Vector2(60, 60)
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
