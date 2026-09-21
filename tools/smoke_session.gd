extends Node
## 端到端烟测：模拟玩家真的在一局里操作一遍，看整条链路通不通。
##
## 用法：
##   godot --path <project> --resolution 1280x720 res://tools/smoke_session.tscn
##
## 【为什么除了单元测试还要这个】
## 单元测试是分块验证，各块都过也可能拼不起来。
## 这个脚本只做一件事：**按玩家会做顺序真的点一遍**，然后报告每一步成没成。
## 出问题时打印的就是「第几步开始不对」，比看一堆断言快得多。

const STEP := 1.0 / 60.0

var _level: Node
var _waiter: Node
var _router: Node
var _spawner: Node
var _ok := 0
var _bad := 0


func _ready() -> void:
	await get_tree().process_frame
	_level = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(_level)
	_router = _level.get_node("ClickRouter")
	_waiter = _level.get_node("Actors/Waiter")
	_spawner = _level.get_node("CustomerSpawner")
	# 不用自动生成，手动控制节奏
	_spawner.set_process(false)
	await get_tree().physics_frame

	print("")
	print("======== 一局烟测（按玩家操作顺序）========")
	await _run()
	print("----------------------------------------")
	print("通过 %d 步，失败 %d 步" % [_ok, _bad])
	print("========================================")
	get_tree().quit(1 if _bad > 0 else 0)


func _check(cond: bool, what: String) -> void:
	if cond:
		_ok += 1
		print("  [OK]   " + what)
	else:
		_bad += 1
		print("  [FAIL] " + what)


## 推进 n 秒（真实物理帧 + 逻辑帧）
func _advance(seconds: float) -> void:
	var n := int(seconds / STEP)
	for i in n:
		await get_tree().physics_frame


## 等服务员把当前指令做完（最多 seconds 秒）
func _settle(seconds: float = 6.0) -> void:
	var n := int(seconds / STEP)
	for i in n:
		await get_tree().physics_frame
		if not bool(_waiter.call("is_busy")) and not bool(_waiter.call("is_locked")):
			return


func _run() -> void:
	# ── 1. 等客人自己进来坐下 ──
	print("1) 客人生成与入座")
	var t1: Node = Game.table_by_id(1)
	_spawner.call("spawn_at_seat", t1, t1.seats[0])
	await _advance(3.0)
	var seated := t1.occupied_seats().size() > 0
	_check(seated, "客人自动走到座位并坐下（%s 有 %d 人）" % [t1.label, t1.occupied_seats().size()])
	var cust: Node = t1.occupied_seats()[0].occupant if seated else null
	if cust == null:
		print("  客人没坐下，后面没法继续")
		return
	_check(int(cust.get("state")) == Constants.State.WAITING_TO_ORDER, "客人处于等点单状态")

	# ── 2. 点客人接单 ──
	print("2) 点客人接单")
	_router.call("handle_click", cust.global_position)
	await _settle()
	_check(int(cust.get("state")) == Constants.State.ORDER_TAKEN, "接单成功，客人转为等上菜")
	_check(t1.order != null, "订单栏生成了一张票")
	var items: Array = []
	if t1.order != null:
		items = t1.order.items.duplicate()
	print("      这桌点了：%s" % str(items))

	# ── 3. 去后厨点菜（模拟在后厨 UI 里按票下单）──
	print("3) 后厨按单做菜")
	Game.enqueue_kitchen(items)
	_check(Game.kitchen.queue_count() > 0, "菜进了后厨队列（%d 道）" % Game.kitchen.queue_count())

	# ── 4. 等做好，把出餐口的餐端起来 ──
	print("4) 出餐口取餐")
	await _advance(4.0)
	_check(not Game.kitchen.counter_is_empty(), "出餐口有餐了：%s" % Game.kitchen.counter_name())

	# ── 5. 一道一道取 + 上菜 ──
	print("5) 取餐 → 上菜（循环到送齐）")
	var guard := 0
	while t1.order != null and guard < 8:
		guard += 1
		# 等出餐口有餐
		var wait := 0
		while Game.kitchen.counter_is_empty() and wait < 600:
			await get_tree().physics_frame
			wait += 1
		if Game.kitchen.counter_is_empty():
			break
		# 取出餐口那份餐（真实链路：走到出餐口 → 端起来）
		# 用和玩家点击出餐口完全相同的入口，走完「走过去 → 到达时再检查 → 端起」
		var kw: Node = _level.get_node("World/KitchenWindow")
		_router.call("handle_click", kw.to_global(kw.get("pickup_rect").get_center()))
		await _settle()
		if Game.hand_is_empty():
			_check(false, "第 %d 道：取餐失败" % guard)
			break
		# 送到桌边
		var target: Node = cust if (cust != null and is_instance_valid(cust)) else t1
		_router.call("handle_click", cust.global_position)
		await _settle()
		print("      第 %d 道送完，手上=%s，票=%s" % [
			guard, Game.hand_name(),
			("已消失" if t1.order == null else "还剩 %d 样" % t1.order.remaining_count())])

	_check(t1.order == null, "全部送齐后票消失")

	# ── 6. 客人用餐 → 结账 ──
	print("6) 用餐与结账")
	var money0: int = Game.money
	await _advance(14.0)
	_check(Game.money > money0, "客人吃完结账，钱 %d → %d" % [money0, Game.money])
	_check(t1.state == TableRules.State.DIRTY, "吃完后桌子变脏")
	_check(t1.occupied_seats().is_empty(), "客人的座位空出来了")

	# ── 7. 点脏桌收拾 ──
	print("7) 收拾桌子")
	_router.call("handle_click", t1.to_global(t1.rect.get_center()))
	await _settle(10.0)
	_check(t1.state == TableRules.State.CLEAN_EMPTY, "收拾完成，桌子恢复可用")

	# ── 8. 再接待一桌，确认循环能继续 ──
	print("8) 再接待一桌（确认循环可继续）")
	_spawner.call("spawn_at_seat", t1, t1.seats[0])
	await _advance(3.0)
	_check(t1.occupied_seats().size() > 0, "新客人能再坐进来")
