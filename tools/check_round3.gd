extends Node
## 验收本轮三个改动：
##   1. 走路是纯直角折线（没有明显偏斜/抖动）
##   2. 点桌子上菜 = 点客人上菜
##   3. 一组客人一起离开（各吃各的，但一起起身）
##
## 用法：
##   godot --headless --path <project> res://tools/check_round3.tscn

const STEP := 1.0 / 60.0

var _ok := 0
var _bad := 0


func _ready() -> void:
	await get_tree().process_frame
	print("")
	print("======== 本轮三点验收 ========")
	await _t1_straight_walk()
	await _t2_serve_via_table()
	await _t3_group_leave()
	print("------------------------------")
	print("通过 %d / 失败 %d" % [_ok, _bad])
	print("==============================")
	get_tree().quit(1 if _bad > 0 else 0)


func _check(cond: bool, what: String) -> void:
	if cond:
		_ok += 1
		print("  [OK]   " + what)
	else:
		_bad += 1
		print("  [FAIL] " + what)


func _new_level() -> Node:
	var lv: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(lv)
	lv.get_node("CustomerSpawner").set_process(false)
	return lv


# ── 1. 走路是否直角、是否抖动 ──────────────────────────────────────
func _t1_straight_walk() -> void:
	print("1) 走路轨迹")
	var lv := _new_level()
	await get_tree().physics_frame
	var waiter: Node = lv.get_node("Actors/Waiter")
	var router: Node = lv.get_node("ClickRouter")

	# 从右下走到左上，中间隔着桌3；必然要绕
	waiter.global_position = Vector2(1100, 560)
	var goal := Vector2(820, 260)
	waiter.set("_debug_trace", true)
	router.call("handle_click", goal)
	# 直接问寻路器算了什么（排查「为什么走出来是斜线」）
	var pf: Node = lv.get_node_or_null("Pathfinder")
	if pf != null:
		print("      寻路: %s -> %s" % [str(waiter.global_position), str(goal)])
		print("      路径=%s" % str(pf.call("find_path", waiter.global_position, goal)))
	print("      waiter 记录的 _goal_pt=%s waypoints=%s" % [
		str(waiter.get("_goal_pt")), str(waiter.get("_waypoints"))])

	var trail: Array = []
	var trace: Array = []
	for i in 600:
		await get_tree().physics_frame
		trail.append(waiter.global_position)
		if i >= 3:
			waiter.set("_debug_trace", false)
		if not bool(waiter.call("is_busy")) and not bool(waiter.call("is_locked")):
			break
	for t in trace:
		print("      " + t)

	# 统计：相邻两帧的方向变化次数（直角折线应该只在少数几个拐点转向）
	var turns := 0
	var prev_dir := Vector2.ZERO
	var wobble := 0
	var change_log: Array = []
	for i in range(1, trail.size()):
		var d: Vector2 = trail[i] - trail[i - 1]
		if d.length() < 0.01:
			continue
		var dir := d.normalized()
		if prev_dir != Vector2.ZERO:
			var ang := dir.angle_to(prev_dir)
			if absf(ang) > deg_to_rad(5.0):
				turns += 1
				change_log.append("f%d pos=%s dir %s -> %s (%.0f°)" % [
					i, str(trail[i]), str(prev_dir), str(dir), rad_to_deg(ang)])
				if absf(ang) < deg_to_rad(45.0):
					wobble += 1
		prev_dir = dir
	for line in change_log:
		print("      " + line)
	if change_log.is_empty():
		print("      从未转向：轨迹 %s → %s" % [str(trail[0]), str(trail[trail.size() - 1])])

	var dist: float = waiter.global_position.distance_to(Vector2(820, 260))
	_check(dist <= 24.0, "绕到了目标（残差 %.1fpx）" % dist)
	# 【为什么要求 turns >= 1】
	# 如果一条需要绕行的路线「0 次转向」，那多半是路径本身有问题
	# （比如根本没绕、或者判定写成永远不转向），不是「走得很直」。
	# 必须同时满足「转向次数少」且「该转的时候转了」才说明是直角折线。
	_check(turns >= 1, "该转弯的时候转了（%d 次）" % turns)
	_check(turns <= 8, "转向次数少（%d 次，直角折线应该只有几个拐点）" % turns)
	_check(wobble <= 4, "几乎没有「小角度偏斜」（%d 次小转向，越少越直）" % wobble)
	print("      轨迹采样 %d 帧，转向 %d 次，其中小角度偏斜 %d 次" % [
		trail.size(), turns, wobble])
	# 打印拐点附近的采样，肉眼确认是直角
	var shown := 0
	for i in range(1, trail.size()):
		var d: Vector2 = trail[i] - trail[i - 1]
		if d.length() < 0.01:
			continue
		if shown < 6 and i > 1:
			print("      f%-4d pos=%s dir=%s" % [
				i, str(trail[i]), str(d.normalized())])
			shown += 1

	lv.free()


# ── 2. 点桌子上菜 ──────────────────────────────────────────────────
func _t2_serve_via_table() -> void:
	print("2) 点桌子上菜")
	var lv := _new_level()
	await get_tree().physics_frame
	var router: Node = lv.get_node("ClickRouter")
	var waiter: Node = lv.get_node("Actors/Waiter")
	var t: Node = Game.table_by_id(1)

	# 一位客人，指定他点一份汉堡
	var seat = t.seats[0]
	var c: Node = lv.get_node("CustomerSpawner").call("spawn_at_seat", t, seat)
	c.call("set_pending_items", ["burger"] as Array[String])
	c.global_position = t.call("seat_sit_point", seat)
	lv.call("_on_customer_seated", c)

	# 接单
	c.call("_do_take_order", router)
	await get_tree().physics_frame
	_check(t.order != null, "接单后开出共享订单")

	# 手上拿汉堡，然后**点桌子**（不是点客人）
	Game.set_hand("burger")
	waiter.call("set_carried", "burger")
	router.call("handle_click", t.to_global(t.rect.get_center()))
	_check(bool(waiter.call("is_busy")), "点桌子后服务员开始走过去上菜")

	for i in 480:
		await get_tree().physics_frame
		if not bool(waiter.call("is_busy")):
			break

	_check(Game.hand_is_empty(), "点桌子上菜成功，手上空了")
	_check(seat.got[0] if seat.got.size() > 0 else false, "这份菜记到了客人头上")
	_check(int(c.get("state")) == Constants.State.EATING, "客人转用餐中")

	lv.free()


# ── 3. 一组客人一起离开 ────────────────────────────────────────────
func _t3_group_leave() -> void:
	print("3) 一组客人一起离开")
	var lv := _new_level()
	await get_tree().physics_frame
	var router: Node = lv.get_node("ClickRouter")
	var t: Node = Game.table_by_id(1)

	# 两位客人同桌，各点一样
	var s0 = t.seats[0]
	var s1 = t.seats[1]
	var a: Node = lv.get_node("CustomerSpawner").call("spawn_at_seat", t, s0)
	a.call("set_pending_items", ["burger"] as Array[String])
	a.global_position = t.call("seat_sit_point", s0)
	lv.call("_on_customer_seated", a)
	var b: Node = lv.get_node("CustomerSpawner").call("spawn_at_seat", t, s1)
	b.call("set_pending_items", ["fries"] as Array[String])
	b.global_position = t.call("seat_sit_point", s1)
	lv.call("_on_customer_seated", b)
	_check(t.occupied_seats().size() == 2, "同桌坐了 2 位客人")

	t.call("open_order")
	for seat in t.occupied_seats():
		seat.occupant.call("accept_order")

	# 给 a 上菜 → a 开始用餐
	t.call("assign_delivery", "burger")
	_check(int(a.get("state")) == Constants.State.EATING, "a 上齐了，开始用餐")
	_check(int(b.get("state")) == Constants.State.ORDER_TAKEN, "b 还没上齐，继续等")

	# 让 a 先吃完（12 秒）
	for i in int(12.5 / STEP):
		await get_tree().physics_frame
	_check(bool(a.call("is_meal_done")), "a 已经吃完自己那份")
	_check(int(a.get("state")) != Constants.State.LEAVING,
		"但 a 没有单独离开（应该等同桌 b）")
	_check(t.occupied_seats().size() == 2, "两位都还在座位上")

	# 再给 b 上菜 → b 开始用餐，整桌一起吃
	t.call("assign_delivery", "fries")
	_check(int(b.get("state")) == Constants.State.EATING, "b 也上齐，开始用餐")

	# 等 b 吃完 → 两人应该一起进入 LEAVING
	for i in int(12.5 / STEP):
		await get_tree().physics_frame
	_check(int(b.call("is_meal_done")), "b 也吃完了")
	_check(int(a.get("state")) == Constants.State.LEAVING, "a 起身离场")
	_check(int(b.get("state")) == Constants.State.LEAVING, "b 起身离场")

	var money0: int = Game.money
	# 走到门口 → 座位还回来、桌子变脏、结账
	for i in int(8.0 / STEP):
		await get_tree().physics_frame
	_check(t.occupied_seats().is_empty(), "两人都到门口，座位全部还回")
	_check(Game.money > money0, "整桌一次结清：钱 %d → %d" % [money0, Game.money])
	_check(t.state == TableRules.State.DIRTY, "全走后桌子变脏")

	lv.free()
