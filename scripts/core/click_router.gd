extends Node
class_name ClickRouter
## 点击路由：把「鼠标左键点了一下」翻译成「服务员走过去，到达后做事」。
##
## 【这个文件是文档第十五、十八节的直译】
## 第十五节把所有可点对象列了一遍；第十八节规定了一条铁律：
##   「所有动作在到达目标点时，必须重新检查条件是否满足。」
## 所以每个动作都被拆成两半：
##   interact()  —— 点击瞬间的检查（够不够格下单）
##   _do_xxx()   —— 到达瞬间的再检查（这段时间里世界可能变了）
## 只要 _do_xxx 返回 false，动作就算取消，服务员停在原地。
##
## 【为什么不直接在点击时执行】
## 因为「跑腿」就是这个游戏的压力来源。点击立刻生效 = 游戏没有难度。

var waiter: Node = null
var world: Node = null       ## 所有可点击物件的父节点
var ui: Node = null          ## UIManager
var customers: Node = null   ## 客人容器

## 鼠标当前世界坐标（给悬停高亮用）
var mouse_world: Vector2 = Vector2.ZERO


func _ready() -> void:
	# 用 _unhandled_input：Control（UI）会先吃掉自己范围内的点击，
	# 所以「点 UI 外面无反应」这条天然成立，不需要额外判断坐标。
	set_process_unhandled_input(true)


## 由 Level 在接好 waiter 之后调用：把「走路失败」统一接过来提示玩家。
##
## 【为什么集中在这里，而不是各物件自己订阅】
## 服务员走不过去时原先**什么都不发生** —— 玩家只看到「点了没反应」，
## 完全不知道为什么。这正是反复踩到的坑。
## 在路由器里接一次，所有指令（接单 / 收拾 / 取餐 / 去后厨 …）自动都有提示，
## 不用每个物件各写一遍（写漏一个就又是静默失败）。
func watch_waiter() -> void:
	if waiter == null:
		return
	if not waiter.command_cancelled.is_connected(_on_walk_cancelled):
		waiter.command_cancelled.connect(_on_walk_cancelled)


func _on_walk_cancelled(reason: String) -> void:
	if reason == "":
		return
	Stickers.push_world(waiter.global_position + Vector2(0, -40), reason, Constants.COLOR_TEXT)


# ── 对外 API（世界里各物件调用）─────────────────────────────────────

## 只是走过去，到了什么也不做
func walk_to_only(point: Vector2) -> void:
	if waiter.is_locked():
		return
	waiter.command_move(point, Callable(), "走过去")


## 走过去，到达后调用 handler(router) -> bool。
## handler 返回 false 表示「到达时再检查失败了」，动作取消。
##
## touch_target 不为 null 时，到达判据是「身体碰到它」，
## 而不是「走到那个精确坐标」—— 从哪一侧贴上都能触发。
func go_then(point: Vector2, handler: Callable, desc: String = "",
		touch_target: Node = null) -> bool:
	if waiter.is_locked():
		return false
	return waiter.command_move(point, handler.bind(self), desc, touch_target)


## 原地飘字（服务员头顶）
func say(text: String, color: Color = Constants.COLOR_TEXT) -> void:
	if waiter != null and is_instance_valid(waiter):
		Stickers.push_world(waiter.global_position + Vector2(0, -34), text, color)
	else:
		Stickers.push(get_viewport().get_visible_rect().size * 0.5, text, color)


## 在某个位置飘字
func say_at(pos: Vector2, text: String, color: Color = Constants.COLOR_TEXT) -> void:
	Stickers.push_world(pos, text, color)


## 玩家手上有餐了吗（统一入口，方便以后加「双手」）
func hand_is_empty() -> bool:
	return Game.hand_is_empty()


## 把手上的餐同步到服务员身上的视觉标记。
## 现在手上可能有多份，所以传整个列表。
func _sync_carried() -> void:
	if waiter != null and is_instance_valid(waiter):
		waiter.call("set_carried_list", Game.hand_items())


## 往手上加一份（取餐 / 拿饮品）。返回是否成功。
func take_into_hand(item_id: String) -> bool:
	var ok := Game.hand_take(item_id)
	if ok:
		_sync_carried()
	return ok


## 从手上拿走一份（送达）
func remove_from_hand(item_id: String) -> bool:
	var ok := Game.hand_remove(item_id)
	if ok:
		_sync_carried()
	return ok


## 兼容旧名：设置成「只有这一份」
func set_hand(item_id: String) -> void:
	Game.set_hand(item_id)
	_sync_carried()


func clear_hand() -> void:
	Game.clear_hand()
	_sync_carried()


# ── 输入 ───────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_world = _to_world(event.position)
		return

	if event is InputEventMouseButton:
		if event.button_index != MOUSE_BUTTON_LEFT or not event.pressed:
			return
		mouse_world = _to_world(event.position)
		handle_click(mouse_world)
		get_viewport().set_input_as_handled()


func _to_world(screen_pos: Vector2) -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return screen_pos
	return vp.get_canvas_transform().affine_inverse() * screen_pos


## 用世界坐标模拟一次左键点击。
## 公开出来是为了**可测**：测试没法伪造鼠标事件，但可以调这个函数，
## 从而真正跑一遍「点击 → 走过去 → 到达时再检查」的完整链路。
func handle_click(world_point: Vector2) -> void:
	# 弹窗期间不该发生任何场景交互
	if get_tree().paused:
		return
	if ui != null and ui.is_any_popup_open():
		return

	# 收拾进行中：服务员不可转向（文档第九节「不可取消」）
	if waiter.is_locked():
		return

	# 1) 客人优先：客人的身体和桌子矩形有重叠，必须先判客人
	var c := _customer_at(world_point)
	if c != null:
		c.interact(self)
		return

	# 2) 家具
	var obj := _object_at(world_point)
	if obj == null:
		walk_to_only(world_point)      # 点空地：只是走过去
		return

	# 3) 后厨 / 出餐口是同一个大矩形里的两块，按点在哪一块分派
	if obj.kind == Constants.Kind.COUNTER:
		if obj.is_pickup_point(world_point):
			obj.take_from_counter(self)
		else:
			obj.open_kitchen(self)
		return

	obj.interact(self)


## 找鼠标下的客人（只找「可点击状态」的客人）
func _customer_at(world_point: Vector2) -> Node:
	if customers == null:
		return null
	var best: Node = null
	var best_d: float = INF
	for child in customers.get_children():
		if not child.has_method("is_clickable"):
			continue
		if not child.is_clickable():
			continue
		# 显式 float 转换：child 是 Node，dynamic 调用返回 Variant
		var d: float = float(child.global_position.distance_to(world_point))
		if d <= float(child.click_radius()) and d < best_d:
			best = child
			best_d = d
	return best


## 找鼠标下的家具。
## 命中多个时（家具矩形理论上不重叠，但留个保险）取「会接受点击」的那个。
func _object_at(world_point: Vector2) -> Node:
	if world == null:
		return null
	var fallback: Node = null
	for child in world.get_children():
		if not child.has_method("hit_test"):
			continue
		if not child.hit_test(world_point):
			continue
		if child.has_method("accepts_click") and child.accepts_click():
			return child
		if fallback == null:
			fallback = child
	return fallback
