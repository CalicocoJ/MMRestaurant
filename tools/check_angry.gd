extends Node
## 客人气走后的桌子状态验收。
##
## 用法：
##   godot --headless --path <project> res://tools/check_angry.tscn
##
## 【要抓的 bug】
## 客人不耐烦气走、从没吃过东西，桌子应该变**干净**（文档第十节：不留脏桌）。
## 实际却变脏了：因为
##   1) leave_all(true) 已经把桌子设成干净；
##   2) 客人走到门口又调用 member_vacated()，「全空就变脏」无条件执行。
## 所以这里把气走的完整时序走一遍，逐节点断言桌子状态。

const STEP := 1.0 / 60.0

var _ok := 0
var _bad := 0


func _ready() -> void:
	await get_tree().process_frame
	var lv: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(lv)
	var spawner: Node = lv.get_node("CustomerSpawner")
	spawner.set_process(false)
	await get_tree().physics_frame

	print("")
	print("======== 气走后的桌子状态 ========")

	# ── 情形 1：单人，耐心归零 ──
	var t1: Node = Game.table_by_id(1)
	var c: Node = spawner.call("spawn_at_seat", t1, t1.seats[0])
	c.global_position = t1.call("seat_sit_point", t1.seats[0])
	lv.call("_on_customer_seated", c)
	_check(t1.state == TableRules.State.OCCUPIED, "客人坐下 → 桌子有人")

	var dirty0: int = Game.dirty_table_count()
	var money0: int = Game.money
	c.call("go_angry")
	_check(t1.state == TableRules.State.CLEAN_EMPTY,
		"气走瞬间 → 桌子变干净（不留脏桌）")
	_check(t1.occupied_seats().is_empty(), "气走瞬间 → 座位清空")

	# 让他走到门口（这一步原来会把桌子弄脏）
	for i in int(8.0 / STEP):
		await get_tree().physics_frame
		if not is_instance_valid(c):
			break
	_check(t1.state == TableRules.State.CLEAN_EMPTY,
		"走到门口之后 → 桌子**仍然干净**（这就是原来出错的地方）")
	_check(Game.dirty_table_count() == dirty0, "待收拾桌数没有增加")
	_check(not Game.available_tables().has(t1) == false,
		"气走的桌子仍算空桌，客人可以马上再坐")
	_check(Game.money == money0, "气走不产生收入")
	_check(Game.angry_count == 1, "气走计数 +1")

	# ── 情形 2：两人同桌，一人先气走 → 整桌一起走，桌子要干净 ──
	var t2: Node = Game.table_by_id(2)
	var canvas := lv.get_node("Actors/Customers")
	# 清掉上一轮的残留
	for ch in canvas.get_children():
		ch.queue_free()
	await get_tree().physics_frame

	var a: Node = spawner.call("spawn_at_seat", t2, t2.seats[0])
	a.global_position = t2.call("seat_sit_point", t2.seats[0])
	lv.call("_on_customer_seated", a)
	var b: Node = spawner.call("spawn_at_seat", t2, t2.seats[1])
	b.global_position = t2.call("seat_sit_point", t2.seats[1])
	lv.call("_on_customer_seated", b)
	t2.call("open_order")
	for s in t2.occupied_seats():
		s.occupant.call("accept_order")
	_check(t2.occupied_seats().size() == 2, "两人同桌就座")

	a.call("go_angry")
	_check(int(b.get("state")) == Constants.State.ANGRY_LEAVING,
		"一人气走 → 同桌另一位也跟着走")
	_check(t2.occupied_seats().is_empty(), "整桌座位一起清空")
	_check(t2.state == TableRules.State.CLEAN_EMPTY, "整桌气走 → 桌子干净")

	# 两人都走到门口
	for i in int(10.0 / STEP):
		await get_tree().physics_frame
		if not is_instance_valid(a) and not is_instance_valid(b):
			break
	_check(t2.state == TableRules.State.CLEAN_EMPTY,
		"两人都到门口之后 → 桌子**仍然干净**")
	_check(t2.order == null, "气走的订单票作废")

	# ── 情形 3：正常吃完 → 仍然要变脏（别把好的也改坏）──
	var t3: Node = Game.table_by_id(3)
	for ch in canvas.get_children():
		ch.queue_free()
	await get_tree().physics_frame
	var d: Node = spawner.call("spawn_at_seat", t3, t3.seats[0])
	d.call("set_pending_items", ["burger"] as Array[String])
	d.global_position = t3.call("seat_sit_point", t3.seats[0])
	lv.call("_on_customer_seated", d)
	t3.call("open_order")
	d.call("accept_order")
	t3.call("assign_delivery", "burger")
	var money1: int = Game.money
	d.call("finish_meal")
	_check(int(d.get("state")) == Constants.State.LEAVING, "吃完 → 起身离场")
	# 【注意】不要在这里读 d.get(...) —— 客人到门口会被 queue_free，
	# 再去访问就是「previously freed instance」。所以改成等桌子状态变化，
	# 反正要验的就是桌子。
	for i in int(10.0 / STEP):
		await get_tree().physics_frame
		if t3.state == TableRules.State.DIRTY:
			break
	_check(t3.state == TableRules.State.DIRTY, "正常吃完 → 桌子**变脏**（这条不能坏）")
	_check(Game.money > money1, "正常吃完 → 结账 +%d" % (Game.money - money1))

	print("--------------------------------")
	print("通过 %d / 失败 %d" % [_ok, _bad])
	print("================================")
	get_tree().quit(1 if _bad > 0 else 0)


func _check(cond: bool, what: String) -> void:
	if cond:
		_ok += 1
		print("  [OK]   " + what)
	else:
		_bad += 1
		print("  [FAIL] " + what)
