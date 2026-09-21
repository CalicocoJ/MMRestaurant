extends EntityBase
## 后厨 / 出餐口。
##
## 【它其实是两件东西，但文档只列了一个矩形】
## 文档第一节只给了「后厨出餐口 (420,20) 240×60」这一个物件，
## 但第五节点它要弹后厨 UI，第七节点「出餐口」又要取餐。
## 已与用户确认的做法：**同一个大矩形里嵌一个小的出餐口矩形**，
##   点小矩形     → 取出餐口那份餐
##   点大矩形其余 → 走进去、弹后厨 UI
## 鼠标悬停时高亮当前会命中的那一块，避免玩家点错。

var rect_size: Vector2 = Vector2(240, 60)
var pickup_rect: Rect2 = Rect2()
var pickup_walk: Vector2 = Vector2.ZERO
var kitchen_walk: Vector2 = Vector2.ZERO

var _hover_pickup: bool = false


func setup(p_body_rect: Rect2, p_pickup_rect: Rect2,
		p_kitchen_walk: Vector2, p_pickup_walk: Vector2) -> void:
	kind = Constants.Kind.COUNTER
	label = "后厨"
	display_label = label
	position = p_body_rect.position
	rect_size = p_body_rect.size
	pickup_rect = Rect2(p_pickup_rect.position - p_body_rect.position, p_pickup_rect.size)
	kitchen_walk = p_kitchen_walk
	pickup_walk = p_pickup_walk

	# 碰撞盒只盖上半部分，让服务员能站到大矩形下缘取餐
	var col := Rect2(Vector2.ZERO, Vector2(p_body_rect.size.x, p_body_rect.size.y * 0.72))
	setup_shape(Rect2(Vector2.ZERO, rect_size), col)
	body_color = Constants.COLOR_COUNTER
	label_color = Color(1, 1, 1, 0.75)

	# 【必须订阅出餐口的变化】
	# 这个节点同时画「出餐口里放着什么」和「悬停高亮」。
	# 早先只有 update_hover() 里那一句 queue_redraw()，
	# 于是餐被取走以后方块不消失 —— 得等玩家鼠标动一下、悬停状态变了才重绘，
	# 看起来就是「延迟半秒」。视觉更新绝不能搭在鼠标事件的便车上。
	_rebind_counter()
	# 【还必须监听「后厨被换掉」】开新一局会重建 Kitchen 对象
	# （Game.reset_progress()），旧对象上的订阅就失效了 ——
	# 表现同样是「取走餐后图标不消失，动一下鼠标才更新」。
	# 所以换了 Kitchen 必须重绑，见 Game.kitchen_changed 的说明。
	if not Game.kitchen_changed.is_connected(_rebind_counter):
		Game.kitchen_changed.connect(_rebind_counter)
	queue_redraw()


## 把「出餐口内容变化」的订阅重新挂到**当前**的 Kitchen 上。
## 【为什么要重绑而不是只在 _ready 连一次】Kitchen 是每开一局重建的对象，
## 而出餐口节点是一直活着的 —— 订阅必须跟着对象走。
func _rebind_counter() -> void:
	if Game.kitchen == null:
		return
	if not Game.kitchen.counter_changed.is_connected(_on_counter_changed):
		Game.kitchen.counter_changed.connect(_on_counter_changed)
	queue_redraw()


func _on_counter_changed(_slot: String) -> void:
	queue_redraw()


func click_rect() -> Rect2:
	return Rect2(Vector2.ZERO, rect_size)


# ── 悬停：细分到「会命中哪一块」────────────────────────────────────

func update_hover(world_point: Vector2, enabled: bool) -> void:
	var on_me := enabled and hit_test(world_point)
	var on_pickup := on_me and pickup_rect.has_point(to_local(world_point))
	if on_me != hovered or on_pickup != _hover_pickup:
		hovered = on_me
		_hover_pickup = on_pickup
		queue_redraw()


# ── 点击 ───────────────────────────────────────────────────────────

## 大矩形永远吃点击：取餐和开后厨 UI 都是有效操作
func accepts_click() -> bool:
	return true


func walk_to() -> Vector2:
	return pickup_walk


## 鼠标点在大矩形的哪一块上？由 ClickRouter 用 world_point 判断后调用对应入口。
func is_pickup_point(world_point: Vector2) -> bool:
	return pickup_rect.has_point(to_local(world_point))


## 走进去 → 游戏暂停 → 弹后厨 UI（文档第五节第 3 步）
func open_kitchen(router: Node) -> int:
	router.go_then(kitchen_walk, Callable(self, "_do_open_kitchen"), "去后厨")
	return RouterResult.ACCEPTED


func _do_open_kitchen(router: Node) -> bool:
	router.ui.open_kitchen()
	return true


## 取出餐口那份餐（文档第七节）
##
## 【容量】手上最多 2 份（config.hand_capacity）。所以前置条件是
## 「手上还有空位」，不是「手上为空」—— 写错就会变成
## 「拿了 1 份以后再也拿不了第二份」。
##
## 【一次点拿几份】已与玩家确认：**一次把出餐口能拿的都拿走**
## （受手上剩余空位限制）。所以"拿 2 份"这件事只发生在玩家手上是空的时候 ——
## 若手上已有 1 份、出餐口也刚好 2 份，玩家拿到第 2 份就满了，
## 第 3 份会留在出餐口，需要再点一次。这是手上容量的限制，不是取餐逻辑的毛病。
func take_from_counter(router: Node) -> int:
	if Game.hand_is_full():
		router.say(Constants.MSG_HAND_FULL)
		return RouterResult.NO_ACTION
	if Game.kitchen.counter_is_empty():
		router.say(Constants.MSG_COUNTER_EMPTY)
		return RouterResult.NO_ACTION

	router.go_then(pickup_walk, Callable(self, "_do_take"), "取出餐口")
	return RouterResult.ACCEPTED


## 到达时再检查 ①手上还有空位 ②出餐口仍有餐 → 能拿几份拿几份
func _do_take(router: Node) -> bool:
	if Game.hand_is_full():
		router.say(Constants.MSG_HAND_FULL)
		return false
	if Game.kitchen.counter_is_empty():
		router.say(Constants.MSG_COUNTER_EMPTY)
		return false
	# 一次最多拿"手上剩余空位"那么多份
	var taken := 0
	while not Game.hand_is_full() and not Game.kitchen.counter_is_empty():
		var id := Game.kitchen.take_from_counter()
		if id == "":
			break
		if not router.take_into_hand(id):
			break
		taken += 1
	return taken > 0


# ── 画 ─────────────────────────────────────────────────────────────

func _draw() -> void:
	var r := Rect2(Vector2.ZERO, rect_size)
	draw_rect(r, body_color, true)
	draw_rect(r, Color(0, 0, 0, 0.45), false, 2.0)

	# 出餐口小矩形
	draw_rect(pickup_rect, body_color.lightened(0.22), true)
	draw_rect(pickup_rect, Color(0, 0, 0, 0.4), false, 1.5)

	# 出餐口里放着的餐：有 sprite 用 sprite，没有就是色块（见 ItemArt）。
	# 【现在可能有多份】出餐口容量由 counter_capacity 决定（默认 2），
	# 所以按份数横排画 N 个方块；1 份时仍然居中，视觉上和以前一致。
	if Game.kitchen != null and not Game.kitchen.counter_is_empty():
		var items: Array[String] = Game.kitchen.counter_slots()
		var box_size := Vector2(22, 22)
		var gap := 4.0
		var n := items.size()
		var total_w := box_size.x * float(n) + gap * float(maxi(0, n - 1))
		var start_x := pickup_rect.get_center().x - total_w * 0.5
		for i in n:
			var box := Rect2(
				Vector2(start_x + float(i) * (box_size.x + gap),
					pickup_rect.get_center().y - box_size.y * 0.5),
				box_size)
			ItemArt.draw_swatch(self, box, items[i], false)
			draw_rect(box.grow(1.0), Color(1, 1, 1, 0.6), false, 1.5)

	_draw_label("后厨 / 点餐台", Rect2(0, 0, rect_size.x, pickup_rect.position.y),
		Color(1, 1, 1, 0.7))
	_draw_label("出餐口", pickup_rect, Color(1, 1, 1, 0.85))

	# 悬停高亮：明确告诉玩家这一下会命中哪一块
	if hovered:
		if _hover_pickup:
			draw_rect(pickup_rect.grow(2.0), Color(1, 1, 1, 0.85), false, 3.0)
		else:
			draw_rect(r, Color(1, 1, 1, 0.45), false, 3.0)
