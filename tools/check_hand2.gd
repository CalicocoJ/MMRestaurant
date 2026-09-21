extends Node
## 「手上能拿 2 份」验收。
##
## 用法：
##   godot --headless --path <project> res://tools/check_hand2.tscn
##
## 【要验的规则（都已与用户确认）】
##   1. 手上最多 2 份（config.hand_capacity）
##   2. 出餐口 / 饮料机 的前置条件是「手上还有空位」，不是「手上为空」
##      —— 写错就会变成「拿了 1 份以后再也拿不了第二份」
##   3. 上菜一次把该桌缺的、手上有的**都送完**
##   4. 手上不匹配的那份**继续拿着**
##   5. 饮料机满了：不弹窗，飘字「你拿不下其他东西了」
##   6. 垃圾桶一次清空手上所有

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
	print("======== 手上能拿 2 份 ========")
	_check(Game.hand_capacity() == 2, "容量是 2（config.hand_capacity）")

	# ── 1. 手上加两份 ──
	Game.clear_hand()
	_check(Game.hand_take("burger"), "拿第 1 份成功")
	_check(Game.hand_has_room(), "拿了 1 份后还有空位")
	_check(Game.hand_take("cola"), "拿第 2 份成功")
	_check(Game.hand_is_full(), "拿了 2 份后满了")
	_check(not Game.hand_take("fries"), "满了以后拿不了第 3 份")
	_check(Game.hand_items().size() == 2, "手上确实是 2 份")
	_check(Game.hand_name() == "汉堡、可乐", "HUD 文字是「汉堡、可乐」（实际 %s）" % Game.hand_name())

	# ── 2. 上菜：一次把该桌缺的都送完，不匹配的继续拿 ──
	var t: Node = Game.table_by_id(1)
	var s0 = t.seats[0]
	var a: Node = spawner.call("spawn_at_seat", t, s0)
	a.call("set_pending_items", ["burger"] as Array[String])
	a.global_position = t.call("seat_sit_point", s0)
	lv.call("_on_customer_seated", a)
	t.call("open_order")
	for s in t.occupied_seats():
		s.occupant.call("accept_order")

	# 桌上只要汉堡；手上是汉堡+可乐 → 应该只送汉堡，可乐留下
	var served: bool = bool(a.call("_do_serve", lv.get_node("ClickRouter")))
	_check(served, "上菜动作成功执行")
	_check(s0.all_got(), "该桌要的汉堡送达了")
	_check(Game.hand_items() == ["cola"], "可乐继续拿在手上（实际 %s）" % str(Game.hand_items()))

	# ── 3. 一次送两份：两人桌点汉堡+可乐，手上两样都有 ──
	Game.clear_hand()
	var t2: Node = Game.table_by_id(2)
	var b0 = t2.seats[0]
	var b1 = t2.seats[1]
	var x: Node = spawner.call("spawn_at_seat", t2, b0)
	x.call("set_pending_items", ["burger"] as Array[String])
	x.global_position = t2.call("seat_sit_point", b0)
	lv.call("_on_customer_seated", x)
	var y: Node = spawner.call("spawn_at_seat", t2, b1)
	y.call("set_pending_items", ["cola"] as Array[String])
	y.global_position = t2.call("seat_sit_point", b1)
	lv.call("_on_customer_seated", y)
	t2.call("open_order")
	for s in t2.occupied_seats():
		s.occupant.call("accept_order")

	Game.hand_take("burger")
	Game.hand_take("cola")
	_check(Game.hand_items().size() == 2, "手上备好两份")
	var served2: bool = bool(x.call("_do_serve", lv.get_node("ClickRouter")))
	_check(served2, "上菜动作成功")
	_check(b0.all_got() and b1.all_got(), "两位客人都拿到了自己的菜")
	_check(Game.hand_is_empty(), "一次点击把两份都送完（实际 %s）" % str(Game.hand_items()))

	# ── 4. 饮料机：满了不弹窗，飘字 ──
	Game.clear_hand()
	Game.hand_take("burger")
	Game.hand_take("burger")
	var dm: Node = lv.get_node("World/DrinkMachine")
	Stickers.clear()
	dm.call("interact", lv.get_node("ClickRouter"))
	_check(not UI.is_any_popup_open(), "手满时点饮料机**不弹窗**")
	_check(Stickers.last_text() == Constants.MSG_HANDS_FULL,
		"飘字是「%s」（实际「%s」）" % [Constants.MSG_HANDS_FULL, Stickers.last_text()])

	# 手上有空位时应该弹窗
	Game.clear_hand()
	Game.hand_take("burger")
	var router: Node = lv.get_node("ClickRouter")
	_check(bool(dm.call("_do_open", router)), "手上有空位时能打开饮料机")
	UI.close_popups()

	# ── 5. 垃圾桶：一次清空 ──
	Game.clear_hand()
	Game.hand_take("burger")
	Game.hand_take("fries")
	var tr: Node = lv.get_node("World/Trash")
	_check(bool(tr.call("_do_trash", router)), "扔垃圾桶成功")
	_check(Game.hand_is_empty(), "垃圾桶一次清空手上所有（实际 %s）" % str(Game.hand_items()))

	# ── 6. 饮料机选了饮品会进手上 ──
	Game.clear_hand()
	router.take_into_hand("juice")
	_check(Game.hand_items() == ["juice"], "橙汁能拿在手上（加进饮料目录的新品）")
	_check(Game.hand_capacity() == 2, "容量仍是 2（拿 1 份后还有空位）")
	_check(Game.hand_has_room(), "拿 1 份后还有空位")

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
