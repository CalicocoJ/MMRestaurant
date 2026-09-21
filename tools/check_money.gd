extends Node
## 「钱会正常增加」验收。
##
## 用法：
##   godot --headless --path <project> res://tools/check_money.tscn
##
## 【要抓的 bug（玩家反馈）】钱一直是 0。
##
## 成因：票送齐时会把 table.order 置空（那样订单栏的票才会消失），
## 但结账发生在客人**走到门口**那一刻 —— 比置空晚，
## 于是 `if order == null: return` 直接跳过结账。
## 修法：开单时就把该收的金额记到 table.bill_amount，结账只看它。

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
	print("======== 钱会不会增加 ========")

	# ── 情形 1：单人吃完结账 ──
	var t: Node = Game.table_by_id(1)
	var seat = t.seats[0]
	var c: Node = spawner.call("spawn_at_seat", t, seat)
	c.call("set_pending_items", ["burger"] as Array[String])
	c.global_position = t.call("seat_sit_point", seat)
	lv.call("_on_customer_seated", c)
	var router: Node = lv.get_node("ClickRouter")
	c.call("_do_take_order", router)

	var expect: int = Config.item_price("burger")
	_check(t.bill_amount == expect, "开单时记下金额 %d 元（实际 %d）" % [expect, t.bill_amount])

	# 上菜（走真实入口，送齐后票会消失）
	router.take_into_hand("burger")
	c.call("_do_serve", router)
	_check(t.order == null, "送齐后票消失（order 置空）")
	_check(t.bill_amount == expect, "票消失后金额仍然记着（%d）" % t.bill_amount)

	var money0: int = Game.money
	# 【规则】钱在「客人离开座位（一起身）」那一刻就收。
	#
	# 【注意等待时长】上菜后客人要**吃够 patience_eating** 才起身（当前 10 秒，
	# 曾按玩家要求从 12 秒缩短），所以这里必须等超过吃的时间。
	# 曾经只等 10 秒 → 误报「钱没增加」。所以按配置值 + 余量来等，别写死。
	var eat_wait := Config.num("patience_eating") + 6.0
	for i in int(eat_wait / STEP):
		await get_tree().physics_frame
		if Game.money > money0:
			break
	_check(Game.money == money0 + expect, "起身那一刻钱 +%d（实际 +%d，等了 %.0f 秒）" % [
		expect, Game.money - money0, eat_wait])

	# ── 情形 2：两人桌一次结清，不翻倍 ──
	var t2: Node = Game.table_by_id(2)
	var s0 = t2.seats[0]
	var s1 = t2.seats[1]
	var a: Node = spawner.call("spawn_at_seat", t2, s0)
	a.call("set_pending_items", ["burger"] as Array[String])
	a.global_position = t2.call("seat_sit_point", s0)
	lv.call("_on_customer_seated", a)
	var b: Node = spawner.call("spawn_at_seat", t2, s1)
	b.call("set_pending_items", ["juice"] as Array[String])
	b.global_position = t2.call("seat_sit_point", s1)
	lv.call("_on_customer_seated", b)
	a.call("_do_take_order", router)

	var expect2: int = Config.item_price("burger") + Config.item_price("juice")
	_check(t2.bill_amount == expect2, "两人桌金额 = 汉堡+橙汁 = %d（实际 %d）" % [
		expect2, t2.bill_amount])

	# 一次把两份都送完
	router.take_into_hand("burger")
	router.take_into_hand("juice")
	a.call("_do_serve", router)
	_check(t2.order == null, "两人桌的票也消失了")

	var money1: int = Game.money
	# 两人各自吃完才会一起起身；这里直接让两人都吃完
	a.call("finish_meal")
	b.call("finish_meal")
	for i in int(14.0 / STEP):
		await get_tree().physics_frame
		if Game.money > money1:
			break
	_check(Game.money == money1 + expect2, "两人桌一次结清 +%d，不翻倍（实际 +%d）" % [
		expect2, Game.money - money1])

	# ── 情形 3：气走不给钱 ──
	var t3: Node = Game.table_by_id(3)
	var s3 = t3.seats[0]
	var d: Node = spawner.call("spawn_at_seat", t3, s3)
	d.call("set_pending_items", ["fries"] as Array[String])
	d.global_position = t3.call("seat_sit_point", s3)
	lv.call("_on_customer_seated", d)
	d.call("_do_take_order", router)
	var money2: int = Game.money
	d.call("go_angry")
	for i in int(10.0 / STEP):
		await get_tree().physics_frame
		if t3.occupied_seats().is_empty():
			break
	_check(Game.money == money2, "气走不给钱（钱保持 %d）" % Game.money)

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
