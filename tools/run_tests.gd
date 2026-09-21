extends Node
## Headless 测试：纯规则 + 场景可达性。
##
## 用法：
##   godot --headless --path <project> res://tools/run_tests.tscn
##
## 【为什么入口是 .tscn 而不是 --script】
## 用 `--script` 时脚本自己就是 main loop，此时 **autoload 还没被创建**，
## 于是 Config / Game / Stickers 全都是「Identifier not found」。
## 换成场景入口，引擎会先装好 autoload 再跑根节点，和游戏运行时完全一致 ——
## 测试环境与真实环境一致，测出来的结论才算数。
##
## 【为什么这些测试值得写】
## 这份文档最容易出错的不是「画得对不对」，而是四类逻辑：
##   1. 订单栏的划红线 / 减数量 / 票何时消失
##   2. 后厨「出餐口有餐就阻塞」（计时该不该继续跑）
##   3. 客人气走**不留脏桌**、吃完**留脏桌**
##   4. 服务员走到家具中心被自己的碰撞盒挡住 → 表现为「点了没反应」
## 前三条是纯函数，第 4 条是几何判断，都不需要真的跑物理引擎就能断言。

var _pass := 0
var _fail := 0
var _failures: PackedStringArray = PackedStringArray()


func _ready() -> void:
	# 测试要往场景树里 add_child，但 _ready 期间父节点还在「布置子节点」，
	# 此时 add_child 会失败。等一帧再跑。
	await get_tree().process_frame

	print("")
	print("======== 餐厅物语 · 测试 ========")
	_test_menu()
	_test_order_lines()
	_test_order_deliver()
	_test_kitchen()
	_test_table_rules()
	await _test_customer_lifecycle()
	await _test_waiter_movement()
	await _test_click_flow()
	await _test_counter_visual_sync()
	await _test_touch_arrival()
	await _test_seats_and_groups()
	await _test_shared_order_delivery()
	await _scan_seat_reachability()
	_test_walk_targets()
	_test_walk_target_clearance()
	print("--------------------------------")
	if _fail == 0:
		print("全部通过：%d 项" % _pass)
	else:
		print("通过 %d 项，失败 %d 项：" % [_pass, _fail])
		for f in _failures:
			print("  x " + f)
	print("================================")
	get_tree().quit(1 if _fail > 0 else 0)


# ── 断言小工具 ─────────────────────────────────────────────────────

## 把一位客人放进某张桌的第 seat_index 个座位，并让它「已经坐下」。
## 返回 [customer, seat]。多座位下这几乎是每个测试都要做的事，所以抽出来。
func _seed_customer(spawner: Node, level: Node, table: Node, seat_index: int = 0) -> Array:
	var seats: Array = table.seats
	var seat = seats[seat_index]
	var c: Node = spawner.call("spawn_at_seat", table, seat)
	c.global_position = table.call("seat_sit_point", seat)
	level.call("_on_customer_seated", c)
	return [c, seat]


## 某位客人「自己点的那几样,已经拿到的那几样」——
## 订单是桌级共享的，所以客人身上不再有 Order；
## 要判断「谁的菜」只能看座位上的 pending/got。
func _seat_items(seat) -> Array:
	return [seat.pending.duplicate(), seat.got.duplicate()]


## 推进物理帧，直到某位客人走到门口发完 gone（或实例已释放）。
##
## 【为什么必须有它】现在的时序是：吃完 → 起身 → **走到门口才还座位**，
## 桌子也到那一刻才变脏/结账。旧测试直接在 finish_meal 后断言，
## 于是全部失败 —— 那不是 bug，是断言没跟上设计。
func _walk_to_door(c: Node, seconds: float = 8.0) -> void:
	for i in int(seconds * 60.0):
		await get_tree().physics_frame
		if not is_instance_valid(c):
			return
		if bool(c.get("_gone_sent")):
			return


func ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_failures.append(what)
		print("  x " + what)


func eq(actual: Variant, expected: Variant, what: String) -> void:
	if actual == expected:
		_pass += 1
	else:
		_fail += 1
		var msg := "%s（期望 %s，实际 %s）" % [what, str(expected), str(actual)]
		_failures.append(msg)
		print("  x " + msg)


# ── 1. 菜单与价格 ──────────────────────────────────────────────────

func _test_menu() -> void:
	print("[1] 菜单 / 价格")
	eq(Config.item_price("burger"), 15, "汉堡 15 元")
	eq(Config.item_price("fries"), 6, "薯条 6 元")
	eq(Config.item_price("cola"), 3, "可乐 3 元")
	eq(Config.item_price("chicken"), 12, "炸鸡块 12 元")
	# 【这两条数字是跟着 menu.json 走的】
	# 原来写的是「后厨 2 道 / 饮品 1 种」——那是加炸鸡块和橙汁之前的旧数字。
	# 断言菜单规模本来是为了「加了菜忘了配数值」这类错，所以数字必须跟着菜单更新。
	eq(Config.kitchen_items.size(), 3, "后厨 3 道（汉堡 / 薯条 / 炸鸡块）")
	eq(Config.drink_items.size(), 2, "饮品 2 种（可乐 / 橙汁）")
	eq(Config.table_count(), 3, "桌子 3 张")

	# 3 样菜单的 ID 必须唯一，否则 _by_id 会互相覆盖
	ok(Config.has_item("burger") and Config.has_item("fries") and Config.has_item("cola"),
		"三道菜都在菜单里")

	var total := Config.total_price(["burger", "burger"] as Array[String])
	eq(total, 30, "两个汉堡 = 30 元")


# ── 2. 订单栏显示规则（文档第七节）─────────────────────────────────

func _test_order_lines() -> void:
	print("[2] 订单栏显示规则")

	# 不同菜品：汉堡、可乐
	var o1 := Order.new(1, ["burger", "cola"] as Array[String])
	eq(o1.plain_text(), "汉堡、可乐", "不同菜品显示「汉堡、可乐」")

	# 重复菜品：汉堡×2
	var o2 := Order.new(1, ["burger", "burger"] as Array[String])
	eq(o2.plain_text(), "汉堡×2", "重复菜品显示「汉堡×2」")

	# 送了一个 → 汉堡×1
	o2.deliver("burger")
	eq(o2.plain_text(), "汉堡×1", "送掉一份后显示「汉堡×1」")
	ok(not o2.all_delivered(), "还剩一份时票不该消失")

	# 重复菜品全送完 → 票消失（all_delivered）
	o2.deliver("burger")
	ok(o2.all_delivered(), "全部送完 → 票消失")
	eq(o2.plain_text(), "汉堡×0", "送完的重复菜品数量归零（票随后消失）")

	# 不同菜品：重复菜品保留 ×N 记号，即使只剩 1 份。
	# 如果「汉堡×2 → 送一份 → 汉堡」，玩家会以为订单内容变了。
	var o6 := Order.new(1, ["burger", "burger"] as Array[String])
	o6.deliver("burger")
	eq(o6.plain_text(), "汉堡×1", "重复菜剩一份仍显示「汉堡×1」而不是「汉堡」")

	# 不同菜品划红线：送了汉堡以后，汉堡那行 done = true，可乐 false
	var o3 := Order.new(2, ["burger", "cola"] as Array[String])
	o3.deliver("burger")
	var lines := o3.lines()
	eq(lines.size(), 2, "两道不同的菜 = 两行")
	eq(bool(lines[0]["done"]), true, "汉堡那行已划掉")
	eq(int(lines[0]["left"]), 0, "汉堡剩余 0")
	eq(bool(lines[1]["done"]), false, "可乐那行没划掉")
	eq(int(lines[1]["left"]), 1, "可乐剩余 1")
	eq(o3.plain_text(), "汉堡、可乐", "不同菜品不做 ×N 标记")

	# 混合：汉堡×2 + 可乐
	var o4 := Order.new(3, ["burger", "cola", "burger"] as Array[String])
	eq(o4.plain_text(), "汉堡×2、可乐", "混合订单合并重复项")

	# 顺序：先出现的菜排在前面（可乐在前）
	var o5 := Order.new(1, ["cola", "burger"] as Array[String])
	eq(o5.plain_text(), "可乐、汉堡", "按首次出现顺序排列")


func _test_order_deliver() -> void:
	print("[3] 上菜判定")
	var o := Order.new(1, ["burger", "cola"] as Array[String])
	ok(o.wants("burger"), "客人要汉堡")
	ok(o.wants("cola"), "客人要可乐")
	ok(not o.wants("fries"), "客人没要薯条")
	ok(o.deliver("burger"), "送汉堡成功")
	ok(not o.deliver("burger"), "同一份汉堡不能送两次")
	ok(not o.wants("burger"), "汉堡已送，不再需要")
	eq(o.remaining_count(), 1, "还剩 1 份")
	ok(o.deliver("cola"), "送可乐成功")
	ok(o.all_delivered(), "全部送齐")
	eq(o.total_price(), 18, "订单总价 15+3=18")


# ── 4. 后厨（文档第六节）───────────────────────────────────────────

func _test_kitchen() -> void:
	print("[4] 后厨")
	var k := Kitchen.new(3.0, 1)

	# 空队列不推进
	k.update(1.0)
	eq(k.counter_slot(), "", "队列空时不出餐")

	# 下单后 3s 出餐
	k.enqueue(["burger"] as Array[String])
	eq(k.queue_count(), 1, "队列里有 1 道")
	k.update(2.9)
	eq(k.counter_slot(), "", "2.9s 还没做好")
	k.update(0.2)
	eq(k.counter_slot(), "burger", "3s 后汉堡放到出餐口")
	eq(k.queue_count(), 0, "队列空了")

	# 阻塞：出餐口有餐时，后厨不开始做下一道
	k.enqueue(["fries", "burger"] as Array[String])
	k.update(10.0)
	eq(k.counter_slot(), "burger", "出餐口有餐时不会被覆盖")
	eq(k.queue_count(), 2, "出餐口满 → 队列不动")

	# 取走以后才开始做
	k.take_from_counter()
	eq(k.counter_slot(), "", "取走后出餐口为空")
	k.update(3.1)
	eq(k.counter_slot(), "fries", "取走后做出下一道（按队列顺序）")

	# 顺序性：出一份取一份，顺序 = 入队顺序
	k.take_from_counter()
	k.update(3.1)
	eq(k.counter_slot(), "burger", "再做就是队列里第二个")

	# 客人气走后不清理队列（文档第六节）
	var k2 := Kitchen.new(3.0, 1)
	k2.enqueue(["fries", "fries"] as Array[String])
	eq(k2.queue_count(), 2, "气走后后厨继续做，队列不动")

	# fast_forward 只是测试工具，顺带验证它和 update 等价
	var k3 := Kitchen.new(3.0, 1)
	k3.enqueue(["cola"] as Array[String])
	k3.fast_forward(3.0)
	eq(k3.counter_slot(), "cola", "fast_forward 等价于逐帧推进")


# ── 5. 桌子规则 ────────────────────────────────────────────────────

func _test_table_rules() -> void:
	print("[5] 桌子状态")
	ok(TableRules.is_available(TableRules.State.CLEAN_EMPTY), "干净无人 = 可坐")
	ok(not TableRules.is_available(TableRules.State.DIRTY), "脏桌不能坐")
	ok(not TableRules.is_available(TableRules.State.OCCUPIED), "有人的桌不能坐")
	ok(TableRules.is_cleanable(TableRules.State.DIRTY), "脏桌可收拾")
	ok(not TableRules.is_cleanable(TableRules.State.CLEAN_EMPTY), "干净桌不用收拾")


# ── 6. 客人生命周期（文档第四、八、十节）──────────────────────────

## 这一节测的是文档里最容易搞反的一处：
##   吃完结账 → 桌子**变脏**
##   气走     → 桌子**变空，不留脏桌**
## 两种结局对桌子的影响完全相反，所以必须分开断言。
func _test_customer_lifecycle() -> void:
	print("[6] 客人生命周期")
	var packed := load("res://scenes/main.tscn") as PackedScene
	if packed == null:
		ok(false, "能加载 main.tscn")
		return
	var level: Node = packed.instantiate()
	get_tree().root.add_child(level)

	var spawner: Node = level.get_node_or_null("CustomerSpawner")
	var customers: Node = level.get_node_or_null("Actors/Customers")
	if spawner == null or customers == null:
		ok(false, "Spawner / Customers 节点存在")
		level.free()
		return

	# 关掉自动生成，免得干扰断言
	spawner.set_process(false)

	var t1: Node = Game.table_by_id(1)
	ok(t1 != null, "桌1 存在")

	# ── 生成客人 ──
	var seeded := _seed_customer(spawner, level, t1, 0)
	var c: Node = seeded[0]
	var s1 = seeded[1]
	ok(c != null, "能在桌1 生成客人")
	eq(c.get("state"), Constants.State.WAITING_TO_ORDER, "坐下后等点单")
	eq(t1.state, TableRules.State.OCCUPIED, "桌子立刻变成有客")
	ok(bool(c.call("is_clickable")), "等点单时可点击")
	ok(s1.pending.size() >= 1 and s1.pending.size() <= 2,
		"客人自己点好了单，1~2 样（实际 %d）" % s1.pending.size())
	ok(s1.got.size() == s1.pending.size(), "got 数组与 pending 等长")
	# 入座**不**挂订单到桌上：票要等玩家接单才出现（见第 8 组）
	ok(t1.order == null, "入座时不把订单挂到桌子上")

	# ── 接单：耐心切 45s ──
	c.call("accept_order")
	eq(c.get("state"), Constants.State.ORDER_TAKEN, "接单后 ORDER_TAKEN")
	eq(c.get("patience_max"), Config.num("patience_waiting_for_food"), "耐心切换为 45s")
	ok(bool(c.call("is_clickable")), "等上菜时可点击")

	# ── 后厨「完成」→ ORDERED，耐心不重置 ──
	var before: float = c.get("patience")
	c.call("mark_ordered")
	eq(c.get("state"), Constants.State.ORDERED, "后厨完成 → ORDERED")
	ok(absf(float(c.get("patience")) - before) < 0.001, "ORDERED 不重置耐心")

	# ── 上齐 → EATING ──
	# 共享订单模型下，上菜要经过 Table.assign_delivery（它负责分给还没拿到的客人）
	var o: Order = t1.call("open_order")
	for item in s1.pending:
		t1.call("assign_delivery", String(item))
	eq(c.get("state"), Constants.State.EATING, "全部上齐 → EATING")
	ok(not bool(c.call("is_clickable")), "用餐中不可点击")
	eq(c.get("patience_max"), Config.num("patience_eating"),
		"用餐时长 = config 的 patience_eating（%.0fs）" % Config.num("patience_eating"))
	ok(s1.all_got(), "座位记录上这位客人已经拿齐了")

	# ── 吃完 → 起身 → 走到门口：那一刻才结账、才变脏 ──
	#
	# 【时序说明】吃完全桌一起起身；座位等到**走到门口**才还回去，
	# 桌子也到那一刻才变脏、才结账。这样不会出现
	# 「人还在店里走，桌子已经脏了」。所以断言必须分两步。
	var money0: int = Game.money
	var price: int = o.total_price()
	c.call("finish_meal")
	eq(int(c.get("state")), Constants.State.LEAVING, "吃完 → 起身离场（LEAVING）")
	eq(t1.state, TableRules.State.OCCUPIED, "还在往门口走 → 桌子仍算有人")
	ok(Game.money == money0, "还没走到门口 → 先不结账")

	await _walk_to_door(c)
	eq(Game.money, money0 + price, "走到门口 → 结账 +%d 元" % price)
	eq(Game.served_count, 1, "已接待人数 +1")
	eq(t1.state, TableRules.State.DIRTY, "走到门口 → 桌子立刻变脏")
	ok(t1.order == null, "脏桌不再挂订单")
	ok(not Game.available_tables().has(t1), "脏桌不算空桌")
	ok(s1.is_free(), "客人走了，座位空出来")

	# ── 收拾：3s 后变干净可用 ──
	t1.call("finish_clean")
	eq(t1.state, TableRules.State.CLEAN_EMPTY, "收拾完 → 干净可用")
	ok(Game.available_tables().has(t1), "干净桌算空桌")

	# ── 气走：桌子变空，不留脏桌 ──
	var t2: Node = Game.table_by_id(2)
	var seeded2 := _seed_customer(spawner, level, t2, 0)
	var c2: Node = seeded2[0]
	var s2 = seeded2[1]
	c2.call("accept_order")
	c2.call("go_angry")
	eq(c2.get("state"), Constants.State.ANGRY_LEAVING, "耐心归零 → ANGRY_LEAVING")
	eq(t2.state, TableRules.State.CLEAN_EMPTY, "气走 → 桌子变空（不留脏桌）")
	ok(t2.order == null, "气走 → 订单票删除")
	ok(s2.is_free(), "气走后座位立刻空出")
	ok(Game.available_tables().has(t2), "气走后桌子马上能再坐人")
	eq(Game.angry_count, 1, "气走计数 +1")

	# ── 走到门口才消失 ──
	var gone := [false]
	c.gone.connect(func(_x): gone[0] = true)
	c.global_position = Door.home_point()
	c.call("_process", 0.016)
	ok(gone[0], "走到门口后发出 gone 信号")

	level.free()


# ── 7. 服务员真的走得过去吗 ────────────────────────────────────────

## 这一条是整个游戏的核心循环：点击 → 走过去 → 到达 → 做事。
## 前面第 7 节只证明了「目标点在几何上在家具外面」，
## 但那不代表**真的能用碰撞滑动走到那一点** ——
## 家具之间可能会夹出一个走不进去的凹角。
## 所以这里用真实物理帧驱动，走一遍最重要的几条路线。
func _test_waiter_movement() -> void:
	print("[7] 服务员移动（真实物理帧）")
	var packed := load("res://scenes/main.tscn") as PackedScene
	var level: Node = packed.instantiate()
	get_tree().root.add_child(level)
	level.get_node("CustomerSpawner").set_process(false)
	await get_tree().physics_frame

	var waiter: Node = level.get_node("Actors/Waiter")
	var world: Node = level.get_node("World")

	# 每条路线：能不能走到，以及「到达回调」有没有被触发
	# 物件与它自己的 walk_to 一起带上，避免在循环外又去引用循环变量
	var routes: Array = []
	for child in world.get_children():
		if child.kind == Constants.Kind.DOOR:
			continue
		routes.append([String(child.name), child.call("walk_to"), child])

	for route in routes:
		var obj_name: String = route[0]
		var point: Vector2 = route[1]
		var obj: Node = route[2]

		var arrived := [false]
		var cb := func() -> bool:
			arrived[0] = true
			return true
		waiter.global_position = Vector2(560, 500)   # 服务员出生点
		waiter.call("command_move", point, cb, "走 " + obj_name)

		if obj_name == "KitchenWindow":
			print("        诊断: goal=%s waypoints=%s" % [
				str(waiter.get("_goal_pt")), str(waiter.get("_waypoints"))])
			for k in 8:
				await get_tree().physics_frame
				print("          f%d pos=%s busy=%s wp=%s" % [
					k, str(waiter.global_position), str(waiter.call("is_busy")),
					str(waiter.get("_waypoints"))])

		var reached := await _drive_until_arrived(waiter, point, 10.0)
		var residual: float = waiter.global_position.distance_to(point)
		print("      route %-14s done=%s arrived_cb=%s stop=%s target=%s residual=%.2f" % [
			obj_name, str(reached), str(arrived[0]), str(waiter.global_position),
			str(point), residual])
		if obj_name == "KitchenWindow":
			var pf4: Node = get_tree().get_first_node_in_group("pathfinder")
			if pf4 != null:
				print("        寻路: 从服务员出生点到 %s" % str(point))
				print("        path=%s" % str(pf4.call("find_path", Vector2(560, 500), point)))
				print("        墙格样例: 桌子2 附近 %s" % str(pf4.call("dump_region",
					Vector2(500, 400), Vector2(700, 520))))
		if obj_name == "KitchenWindow":
			# 起点附近到底撞上了什么？把世界里的碰撞体和坐标都列出来
			print("        服务员停在 %s，附近物件：" % str(waiter.global_position))
			for other in world.get_children():
				var ob: Rect2 = other.call("collision_rect_global")
				if ob.size == Vector2.ZERO:
					continue
				if ob.grow(60.0).has_point(waiter.global_position):
					print("          %s collision=%s" % [String(other.name), str(ob)])
		ok(reached, "%s 的走路指令能正常结束（没有卡死）" % obj_name)
		ok(arrived[0], "走到 %s 后触发了到达回调" % obj_name)

	level.free()


## 用真实物理帧推进，直到服务员的指令结束。返回**到达回调是否触发**。
##
## 【为什么以「回调触发」为准，而不是以「离目标点几像素」为准】
## move_and_slide 会把人从家具碰撞盒里推出来，最终停在目标点外 4~8px
## 是**正常且预期**的（物理上就进不去）。真正要断言的是
## 「到达回调有没有跑」—— 那才是文档里「到达后执行动作」的那一步。
## 早先版本用 5px 硬判距离，反而把正确的实现判成失败。
func _drive_until_arrived(waiter: Node, target: Vector2, timeout: float) -> bool:
	var frames := int(timeout * 60.0)
	for i in frames:
		await get_tree().physics_frame
		# 指令结束（到达或放弃）
		if not bool(waiter.call("is_busy")) and not bool(waiter.call("is_locked")):
			return true
	return false


# ── 8. 完整点击链路 ───────────────────────────────────────────────

## 【这一节是为了堵住一个真实漏测】
## 之前所有的测试都直接调 `customer.accept_order()` / `order.deliver()`，
## 也就是**绕过**了玩家真正走的那条路：点击 → 走过去 → 到达时再检查。
## 结果「客人根本没有 interact() 方法」这种致命问题一直没被发现 ——
## 游戏里点客人完全没反应，测试却全绿。
## 所以这里用 router.handle_click() 模拟真实左键，把整条链路跑一遍。
func _test_click_flow() -> void:
	print("[8] 完整点击链路（模拟左键）")
	var level: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(level)
	level.get_node("CustomerSpawner").set_process(false)
	await get_tree().physics_frame

	var router: Node = level.get_node("ClickRouter")
	var waiter: Node = level.get_node("Actors/Waiter")
	var spawner: Node = level.get_node("CustomerSpawner")
	var t1: Node = Game.table_by_id(1)

	# ── 准备：一位坐在桌1、已经点好单的客人 ──
	var seeded := _seed_customer(spawner, level, t1, 0)
	var c: Node = seeded[0]
	var s1 = seeded[1]
	eq(c.get("state"), Constants.State.WAITING_TO_ORDER, "客人就座等点单")
	ok(s1.pending.size() >= 1, "客人已点好单")

	# ── 接单**之前**：左侧不能有票 ──
	# 文档第五节：票是「接单成功」的结果，不是「客人入座」的副作用。
	# 这条断言就是为了钉住这个区别 —— 早先版本客人一坐下票就冒出来了。
	eq(Game.active_orders().size(), 0, "客人刚坐下、还没接单 → 左侧没有票")
	ok(t1.order == null, "接单前订单不挂到桌子上")
	ok(s1.pending.size() >= 1, "客人自己点的菜记在座位上（数据在，只是不显示在头顶）")

	# ── 点客人 → 走过去接单 ──
	var cp: Vector2 = c.global_position
	router.call("handle_click", cp)
	ok(bool(waiter.call("is_busy")), "点客人后服务员开始走过去")
	await _drive_until_arrived(waiter, cp, 4.0)

	eq(c.get("state"), Constants.State.ORDER_TAKEN, "到达后客人转为已接单")
	var stop_d: float = waiter.global_position.distance_to(c.global_position)
	print("      click诊断: state=%d waiter=%s customer=%s dist=%.2f touch_r=%.1f 该到=%s" % [
		int(c.get("state")), str(waiter.global_position), str(c.global_position),
		stop_d, c.TOUCH_RADIUS, str(c.call("touches_from", waiter.global_position, 16.0))])
	eq(float(c.get("patience_max")), Config.num("patience_waiting_for_food"),
		"接单后耐心切换为 45s")
	ok(t1.order != null, "接单后开出共享订单")
	var o: Order = t1.order
	eq(o.items.size(), s1.pending.size(), "共享订单内容 = 客人自己点的那些")
	eq(Game.active_orders().size(), 1, "接单后订单栏出现 1 张票")
	ok(o.plain_text() != "", "票上有菜名（菜名只在这里显示，客人头顶不再显示）")

	# ── 空手点已接单的客人：应提示「手上没有餐品」而不是「这不是他要的菜」──
	Game.clear_hand()
	await _click_brief(router, c.global_position)
	eq(Stickers.last_text(), Constants.MSG_HAND_EMPTY,
		"空手点已接单客人 → 提示「手上没有餐品」而不是「这不是他要的菜」")
	ok(not bool(waiter.call("is_busy")), "空手点客人不会让服务员白跑一趟")

	# ── 手上拿着这一桌要的菜 → 走过去上菜 ──
	var want := String(s1.pending[0])
	Game.set_hand(want)
	waiter.call("set_carried", want)
	router.call("handle_click", c.global_position)
	ok(bool(waiter.call("is_busy")), "手上有正确的菜，服务员去上菜")
	await _drive_until_arrived(waiter, c.global_position, 4.0)

	ok(Game.hand_is_empty(), "上菜后手上空了")
	ok(s1.got[0], "这份菜被记到了这位客人头上（自动分配）")
	if s1.pending.size() == 1:
		eq(c.get("state"), Constants.State.EATING, "只有一样菜 → 上齐后转用餐中")
		eq(Game.active_orders().size(), 0, "全部送齐后票消失")
	else:
		eq(c.get("state"), Constants.State.ORDER_TAKEN, "还没上齐，继续等")

	# ── 手上拿着**客人没要的**菜 → 点客人不应移动 ──
	Game.set_hand(Constants.COLA if want != Constants.COLA else Constants.FRIES)
	waiter.call("set_carried", Game.hand)
	await _click_and_settle(router, waiter, c.global_position)
	ok(not bool(waiter.call("is_busy")), "拿着客人没点的菜不会白跑一趟")

	# ── 不可点击状态：用餐中，点了完全没反应 ──
	c.call("start_eating")
	Game.clear_hand()
	if bool(waiter.call("is_busy")):
		waiter.call("cancel_command")
	await _click_and_settle(router, waiter, c.global_position)
	ok(not bool(waiter.call("is_busy")), "用餐中的客人点了没反应")

	level.free()


## 点一下，立刻返回（只推进一帧，让指令如果被接受就开始跑）。
## 【为什么单独要它】取消提示、原地飘字这类反馈只在点击后很短的时间内出现，
## 等一整条指令跑完再断言就会错过（或者被后面的飘字顶掉）。
func _click_brief(router: Node, pos: Vector2) -> void:
	router.call("handle_click", pos)
	for i in 3:
		await get_tree().physics_frame


## 点一下，然后给「可能产生的指令」一点时间跑完，再返回。
## 【为什么需要它】如果上一条指令还没结束就点下一下，
## router 会因为 waiter.is_busy / is_locked 直接忽略这次点击，
## 断言就会误判成「点击没反应」。所以每次点击后都要等指令落地。
func _click_and_settle(router: Node, waiter: Node, pos: Vector2) -> void:
	router.call("handle_click", pos)
	# 等一小会儿，让「瞬间完成」的指令（原地飘字）和需要走路的指令都尘埃落定
	for i in 12:
		await get_tree().physics_frame
	if bool(waiter.call("is_busy")):
		await _drive_until_arrived(waiter, pos, 6.0)


# ── 9. 出餐口的视觉同步 ───────────────────────────────────────────

## 【这一节是为了钉住一个「靠鼠标才会刷新」的 bug】
## 出餐口那个方块和悬停高亮画在同一个节点上，而那个节点原先只在
## update_hover() 里重绘。结果菜被取走以后方块不消失，
## 要等玩家鼠标动一下才更新 —— 玩家看到的是「延迟半秒」。
##
## 【为什么不去数 _draw 被调了几次】
## 试过了，行不通：headless 模式下 _draw 只在进树时调一次，
## 之后即使显式 queue_redraw() 也不会再调（没有真实渲染管线）。
## 所以「画面有没有重画」这件事在 headless 里根本观测不到。
##
## 能观测的是**因果链的前半段**，而 bug 恰好就在前半段：
## 内容变化后到底有没有人请求重绘。
## 这里数 _on_counter_changed 被调用了几次 —— 它就是那个请求者。
## 早先的版本里根本没有这个方法，所以这个测试当时会直接失败。
##
## 「画面最终对不对」交给 tools/screenshot.tscn 与 check_dim.tscn 看像素。
func _test_counter_visual_sync() -> void:
	print("[9] 出餐口视觉同步（重绘请求）")
	var level: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(level)
	level.get_node("CustomerSpawner").set_process(false)
	await get_tree().physics_frame

	var kw: Node = level.get_node("World/KitchenWindow")

	# 探针：只数「出餐口变化 → 请求重绘」这条链路走了几次
	var probe := _CounterProbe.new()
	probe.name = "CounterProbe"
	kw.add_child(probe)
	Game.kitchen.counter_changed.connect(probe.on_counter_changed)

	# 订阅关系必须存在：厨房窗口得挂在出餐口信号上
	ok(Game.kitchen.counter_changed.get_connections().size() >= 1,
		"出餐口的变化信号有人订阅（否则画面永远不会更新）")

	# ── 出餐：内容变化必须请求重绘 ──
	var before := probe.redraw_requests
	Game.kitchen.enqueue(["burger", "fries"] as Array[String])
	Game.kitchen.update(3.0)
	eq(Game.kitchen.counter_slot(), "burger", "3s 后汉堡到了出餐口")
	ok(probe.redraw_requests > before,
		"出餐口内容变化后请求了重绘（不需要鼠标动）")

	# ── 取餐：内容被拿走同样必须请求重绘 ──
	# 这就是玩家看到「延迟半秒」的那个场景
	var before_take := probe.redraw_requests
	var id := Game.kitchen.take_from_counter()
	eq(id, "burger", "取出的是汉堡")
	eq(Game.kitchen.counter_slot(), "", "出餐口已清空")
	ok(probe.redraw_requests > before_take,
		"取餐后立刻请求了重绘（早先版本的 bug 就在这：要等鼠标动才刷新）")

	# ── 全程没有发生任何鼠标事件 ──
	ok(Game.kitchen.counter_is_empty(),
		"全程无 InputEventMouseMotion，状态与重绘请求依然同步")

	# ── 重复赋同样的值不该产生多余重绘 ──
	var same := probe.redraw_requests
	Game.kitchen.take_from_counter()
	eq(probe.redraw_requests, same, "出餐口本来就是空的，不再重复请求重绘")

	# ── 下一道也正常 ──
	# 先把队列清空：前面 enqueue 的 fries 还排在队里，
	# 不清掉的话下一道出的就是它，断言会误判（这是我第一次写错的地方）。
	Game.kitchen.queue.clear()
	Game.kitchen.timer = 0.0
	Game.kitchen.enqueue(["cola"] as Array[String])
	Game.kitchen.fast_forward(3.5)
	eq(Game.kitchen.counter_slot(), "cola", "下一道可乐也正常出餐")

	level.free()


## 探针：数「出餐口变化 → 请求重绘」被触发了几次。
class _CounterProbe extends Node:
	var redraw_requests: int = 0
	func on_counter_changed(_slot: String) -> void:
		redraw_requests += 1


# ── 10. 「碰到就触发」的到达判定 ──────────────────────────────────

## 【这一节验证的是玩家反馈的那个手感问题】
## 以前：点桌子必须走到「桌面底面正下方」那个固定点，
##       所以从右边点桌子也会先绕到下面来。
## 现在：到达 = 身体碰到桌子的碰撞盒，从哪一侧贴上都能触发。
##
## 所以这里从**四个方向**分别靠近同一张桌子，
## 断言服务员最终都停在「该侧边缘 + 身体半径」的位置上。
## 只从下面测是证明不了这件事的 —— 那正是旧实现唯一的入口。
func _test_touch_arrival() -> void:
	print("[10] 碰到就触发（四个方向）")
	var level: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(level)
	level.get_node("CustomerSpawner").set_process(false)
	await get_tree().physics_frame

	var waiter: Node = level.get_node("Actors/Waiter")
	var t2: Node = Game.table_by_id(2)          # 桌2
	t2.call("on_customer_left", t2.seats[0])    # 没有客人也直接置脏，方便测收拾
	t2.state = TableRules.State.DIRTY
	t2.call("_refresh_look")
	eq(t2.state, TableRules.State.DIRTY, "桌2 已变脏")

	var box: Rect2 = t2.call("collision_rect_global")
	var r := 16.0
	var centre := box.get_center()

	# 四组：起点相对桌子中心的偏移，以及期望贴上的边。
	#
	# 【为什么用相对坐标】绝对值写过两轮，桌子一挪就全部失效
	# （表现是「从600,300 出发碰不到桌2」）。相对坐标跟布局无关，
	# 以后调 layout.json 不用再改这里。
	var offsets := [
		["上", Vector2(0, -140)],
		["下", Vector2(0, 140)],
		["左", Vector2(-170, 0)],
		["右", Vector2(170, 0)],
	]

	for off in offsets:
		var name: String = off[0]
		var start: Vector2 = centre + off[1]
		var expect_axis := "y" if off[1].x == 0.0 else "x"
		var expect_val := (box.position.y - r) if (off[1].y < 0.0) else \
			((box.end.y + r) if off[1].y > 0.0 else \
			((box.position.x - r) if off[1].x < 0.0 else (box.end.x + r)))

		waiter.global_position = start
		var arrived := [false]
		var cb := func() -> bool:
			arrived[0] = true
			return true
		waiter.call("command_move", start, cb, "收拾", t2)

		await _drive_until_arrived(waiter, start, 10.0)
		var pos: Vector2 = waiter.global_position
		if not arrived[0]:
			print("      touch诊断 %s: 从 %s 停 %s（桌子中心 %s）" % [
				name, str(start), str(pos), str(centre)])

		ok(arrived[0], "从%s方靠近：碰到家具就触发" % name)
		# 碰到桌子本身，或碰到它任意一把椅子，都算「走到这件家具边上了」。
		# 【注意】必须按**每个碰撞形状**判断：桌子两侧的椅子是独立碰撞盒，
		# 只查桌面那个矩形会把「贴着椅子」误判成没碰到。
		var touching := false
		var best := INF
		var shapes0: Array = t2.call("collision_shapes_global")
		for shp in shapes0:
			var dd: float = pos.distance_to(EntityBase.nearest_point_on_rect(shp, pos))
			best = minf(best, dd)
			if dd <= r + 1.5:
				touching = true
		if not touching:
			print("         [touch] %s: 停 %s，桌子中心 %s，碰撞形状 %s，最近距离 %.2f（半径 %.0f）" % [
				name, str(pos), str(centre), str(shapes0), best, r])
		ok(touching, "从%s方靠近：最终位置确实贴着桌子或椅子" % name)
		# 别停在半路：残余距离不该大到「明显没走到」
		ok(waiter.global_position.distance_to(start) < 250.0 or arrived[0],
			"从%s方靠近：确实走过去了（起点 %s → 停 %s）" % [name, str(start), str(pos)])

	# ── 客人也不需要「走到他身上」了 ──
	var spawner: Node = level.get_node("CustomerSpawner")
	var seat0 = Game.table_by_id(1).seats[0]
	var cust: Node = spawner.call("spawn_at_seat", Game.table_by_id(1), seat0)
	cust.global_position = Game.table_by_id(1).call("seat_sit_point", seat0)
	level.call("_on_customer_seated", cust)

	waiter.global_position = cust.global_position + Vector2(0, 120)
	var got_arrive := [false]
	var cb2 := func() -> bool:
		got_arrive[0] = true
		return true
	waiter.call("command_move", cust.global_position, cb2, "接单", cust)
	await _drive_until_arrived(waiter, cust.global_position, 4.0)

	ok(got_arrive[0], "靠近客人就触发，不需要精确走到他身上")
	var d: float = waiter.global_position.distance_to(cust.global_position)
	ok(d <= cust.TOUCH_RADIUS + r + 2.5,
		"停在客人身边 %.1fpx 内（上限 %.1f）" % [d, cust.TOUCH_RADIUS + r])

	level.free()


# ── 11. 座位与「一组客人」──────────────────────────────────────────

## 这一节验证用户提出的模型：
##   - 每张桌有多个座位（默认 2：左右各一），椅子是实体、会挡路
##   - 客人以**组**为单位生成，一组 1~2 人，**整组必须同一张桌**
##   - 坐不下就等（不拆组）
func _test_seats_and_groups() -> void:
	print("[11] 座位与一组客人")
	var level: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(level)
	var spawner: Node = level.get_node("CustomerSpawner")
	spawner.set_process(false)
	await get_tree().physics_frame

	# ── 每张桌都有 2 个座位，椅子有碰撞体 ──
	for t in Game.tables:
		eq(t.seat_count(), 2, "%s 有 2 个座位" % t.label)
		# 桌子自己 1 个碰撞体 + 每座位 1 个椅子碰撞体
		var shapes := 0
		for c in t.get_children():
			if c is CollisionShape2D:
				shapes += 1
		eq(shapes, 3, "%s 有 1 个桌面碰撞盒 + 2 个椅子碰撞盒" % t.label)

	# ── 座位几何：左右各一，分别在桌子两侧 ──
	var t1: Node = Game.table_by_id(1)
	var left = t1.seats[0]
	var right = t1.seats[1]
	ok(left.pos.x < 0.0, "座位1 在桌子左侧（x=%.1f）" % left.pos.x)
	ok(right.pos.x > t1.rect.size.x, "座位2 在桌子右侧（x=%.1f）" % right.pos.x)
	eq(left.facing, -1, "左侧座位朝右（面向桌子）")
	eq(right.facing, 1, "右侧座位朝左（面向桌子）")

	# 椅子不能压在桌面上（否则客人等于站在桌上）
	ok(left.chair_rect().end.x <= 0.0, "左椅不与桌面重叠")
	ok(right.chair_rect().position.x >= t1.rect.size.x, "右椅不与桌面重叠")

	# ── 全店空位统计 ──
	eq(SeatManager.free_seat_count(), 6, "3 桌 × 2 座 = 6 个空位")

	# ── 一组 2 人：必须坐同一张桌，而且占满两个座位 ──
	var slot := SeatManager.pick_group(2)
	ok(not slot.is_empty(), "能找到容纳 2 人组的桌子")
	var gt: Node = slot["table"]
	eq(slot["seats"].size(), 2, "分配了 2 个座位")
	ok(slot["seat_indices"][0] != slot["seat_indices"][1], "两个座位不是同一个")

	var c1: Node = spawner.call("spawn_at_seat", gt, slot["seats"][0])
	c1.global_position = gt.call("seat_sit_point", slot["seats"][0])
	level.call("_on_customer_seated", c1)
	var c2: Node = spawner.call("spawn_at_seat", gt, slot["seats"][1])
	c2.global_position = gt.call("seat_sit_point", slot["seats"][1])
	level.call("_on_customer_seated", c2)

	eq(gt.occupied_seats().size(), 2, "同桌坐了 2 位客人")
	eq(gt.customers().size(), 2, "两位客人都挂在桌上")
	eq(SeatManager.free_seat_count(), 4, "剩下 4 个空位")

	# ── 两位客人各自有耐心（耐心是客人级的）──
	ok(c1.patience > 0.0 and c2.patience > 0.0, "两位客人各自在掉耐心")
	c2.patience = 1.0
	c2.call("go_angry")
	eq(gt.occupied_seats().size(), 1, "一位气走后，同桌另一位不受影响")
	eq(gt.state, TableRules.State.OCCUPIED, "还有人坐着 → 桌子不能变脏")
	ok(not Game.available_tables().has(gt), "还有人的桌子不算空桌")

	# ── 坐不下整组就不拆：只剩 1 个空位的桌不能满足 2 人组 ──
	# 把其他桌占满，只留下 gt 的一个空位
	for other in Game.tables:
		if other == gt:
			continue
		for s in other.free_seats():
			var cc: Node = spawner.call("spawn_at_seat", other, s)
			# 【必须真的坐下】之前漏了这一句，客人停在 WALKING_IN，
			# 座位一直算「被占」，于是「只剩 1 个空位」断言失败。
			level.call("_on_customer_seated", cc)
	eq(SeatManager.free_seat_count(), 1, "全店只剩 1 个空位")
	ok(SeatManager.pick_group(2).is_empty(), "只剩 1 位时，2 人组坐不下 → 不拆，继续等")
	ok(not SeatManager.pick_group(1).is_empty(), "但 1 人组还能坐")

	# ── 组规模概率 ──
	var seen := {}
	for i in 400:
		var n := Config.roll_group_size()
		seen[n] = int(seen.get(n, 0)) + 1
	ok(seen.has(1) and seen.has(2), "组的规模只可能是 1 或 2（实际：%s）" % str(seen.keys()))
	ok(not seen.has(3), "不会掷出超过桌位数的组")

	level.free()


# ── 全局可达性扫描 ─────────────────────────────────────────────────

## 从世界各处出发，测试服务员能不能走到每个「客人座位」。
## 【为什么值得单独做】「椅子挡路导致接不了单」这类问题，
## 只要有一个方向走不到，玩家就会觉得「点了没反应」。
## 单点测试很容易漏，所以这里做网格扫描。
func _scan_seat_reachability() -> void:
	print("[scan] 从网格各点出发，能否到达每个座位")
	var level: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(level)
	level.get_node("CustomerSpawner").set_process(false)
	await get_tree().physics_frame

	var waiter: Node = level.get_node("Actors/Waiter")
	var origins := [
		Vector2(560, 500), Vector2(300, 550), Vector2(900, 550),
		Vector2(120, 550), Vector2(1150, 550), Vector2(640, 620),
		Vector2(300, 200), Vector2(900, 200),
	]

	var bad := 0
	var total := 0
	# 先直接问一次寻路器：它到底算不算得出路径
	var pf: Node = get_tree().get_first_node_in_group("pathfinder")
	ok(pf != null, "场景里有 Pathfinder 节点")
	if pf != null:
		var t1: Node = Game.table_by_id(1)
		var sit: Vector2 = t1.call("seat_sit_point", t1.seats[0])
		var pts: Array = pf.call("find_path", Vector2(560, 500), sit)
		print("      path诊断: 从(560,500) 到 桌1座1=%s 拐点数=%d %s" % [
			str(sit), pts.size(), str(pts)])
		var pts2: Array = pf.call("find_path", Vector2(900, 550), sit)
		print("      path诊断2: 从(900,550) 拐点数=%d %s" % [pts2.size(), str(pts2)])
		var t3: Node = Game.table_by_id(3)
		var sit3: Vector2 = t3.call("seat_sit_point", t3.seats[1])
		var pts3: Array = pf.call("find_path", Vector2(120, 550), sit3)
		print("      path诊断3: 从(120,550) 到 桌3座2=%s 拐点数=%d %s" % [
			str(sit3), pts3.size(), str(pts3)])
	for t in Game.tables:
		for si in t.seat_count():
			var seat = t.seats[si]
			var sit: Vector2 = t.call("seat_sit_point", seat)
			# 客人真的坐在那里（touches_from 是相对客人算的，所以放个客人才准）
			var spawner: Node = level.get_node("CustomerSpawner")
			var cust: Node = spawner.call("spawn_at_seat", t, seat)
			cust.global_position = sit
			for o in origins:
				total += 1
				waiter.global_position = o
				var hit := [false]
				var cb := func() -> bool:
					hit[0] = true
					return true
				waiter.call("command_move", sit, cb, "scan", cust)
				await _drive_until_arrived(waiter, sit, 6.0)
				var d: float = waiter.global_position.distance_to(sit)
				if not hit[0]:
					bad += 1
					var dbg2: Array = []
					var pf3: Node = get_tree().get_first_node_in_group("pathfinder")
					if pf3 != null:
						dbg2 = pf3.call("find_path", o, cust.call("touch_point", o))
					print("      scan 失败: %s 座%d 从 %s 出发，停在 %s 距离 %.1f" % [
						t.label, si + 1, str(o), str(waiter.global_position), d])
					print("         路径=%s" % str(dbg2))
			# 清掉这位客人，好测下一个座位
			cust.call("go_angry")
			cust.queue_free()

	print("      scan: %d/%d 条路线失败" % [bad, total])
	ok(bad == 0, "所有座位都能从各处走到（失败 %d/%d）" % [bad, total])
	level.free()


# ── 12. 共享订单与自动分配 ─────────────────────────────────────────

## 用户选的模型：一张票 = 同桌所有客人的菜合并；
## 上菜送到桌边，系统自动分给「还没拿到这道菜」的那位客人。
func _test_shared_order_delivery() -> void:
	print("[12] 共享订单与自动分配")
	var level: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(level)
	var spawner: Node = level.get_node("CustomerSpawner")
	spawner.set_process(false)
	await get_tree().physics_frame

	var t: Node = Game.table_by_id(1)
	var s0 = t.seats[0]
	var s1 = t.seats[1]

	# 两位客人，指定他们各点什么，方便断言「分配给了谁」
	var a: Node = spawner.call("spawn_at_seat", t, s0)
	a.call("set_pending_items", ["burger"] as Array[String])
	a.global_position = t.call("seat_sit_point", s0)
	level.call("_on_customer_seated", a)

	var b: Node = spawner.call("spawn_at_seat", t, s1)
	b.call("set_pending_items", ["cola", "fries"] as Array[String])
	b.global_position = t.call("seat_sit_point", s1)
	level.call("_on_customer_seated", b)

	eq(s0.pending, ["burger"], "座位1 的客人要汉堡")
	eq(s1.pending, ["cola", "fries"], "座位2 的客人要可乐+薯条")

	# 接单：模拟玩家点了这一桌（订单是共享的，两人一起进入等上菜）
	var o: Order = t.call("open_order")
	for s in t.occupied_seats():
		s.occupant.call("accept_order")

	# ── 一张票 = 两人的菜合并 ──
	eq(o.items.size(), 3, "共享订单共 3 样")
	ok(o.wants("burger") and o.wants("cola") and o.wants("fries"), "三样都在票上")

	# ── 送汉堡：应该分给座位1 那位客人 ──
	var who: Node = t.call("assign_delivery", "burger")
	ok(who == a, "汉堡归给了点汉堡的那位客人")
	ok(s0.all_got(), "座位1 的客人齐了")
	eq(a.get("state"), Constants.State.EATING, "齐了的客人转用餐中")
	eq(b.get("state"), Constants.State.ORDER_TAKEN, "没齐的客人继续等")

	# ── 送薯条：应该分给座位2 那位客人 ──
	var who2: Node = t.call("assign_delivery", "fries")
	ok(who2 == b, "薯条归给了点薯条的那位客人")
	ok(not s1.all_got(), "座位2 还差可乐")
	eq(b.get("state"), Constants.State.ORDER_TAKEN, "还差一样，继续等")

	# ── 送可乐：座位2 齐了 ──
	t.call("assign_delivery", "cola")
	ok(s1.all_got(), "座位2 也齐了")
	eq(b.get("state"), Constants.State.EATING, "第二位客人也转用餐中")
	ok(o.all_delivered(), "整张票送齐")

	# ── 送一份没人要的菜：不该被任何人认领 ──
	ok(t.call("assign_delivery", "burger") == null, "没人要的菜不会被认领")
	ok(not t.call("wants_from_seats", "burger"), "这桌已经不需要汉堡了")

	# ── 结账：共享订单只结一次，不按人头翻倍 ──
	var money0: int = Game.money
	var price: int = o.total_price()
	a.call("finish_meal")
	eq(a.get("state"), Constants.State.LEAVING, "第一位客人离场")
	ok(Game.money == money0, "还有人没走 → 先不结账（避免同桌结两次）")
	b.call("finish_meal")
	eq(Game.money, money0 + price, "最后一位离场时一次结清整桌：+%d 元" % price)
	eq(Game.served_count, 2, "两位客人都记入已接待")
	eq(t.state, TableRules.State.DIRTY, "同桌全走 → 桌子立刻变脏")

	level.free()


# ── 13. 场景可达性（最容易出「点了没反应」的地方）──────────────────

func _test_walk_targets() -> void:
	print("[13] 家具可达性")
	var packed := load("res://scenes/main.tscn") as PackedScene
	if packed == null:
		ok(false, "能加载 main.tscn")
		return
	var level: Node = packed.instantiate()
	get_tree().root.add_child(level)
	level.get_node("CustomerSpawner").set_process(false)

	var world: Node = level.get_node_or_null("World")
	if world == null:
		ok(false, "World 节点存在")
		level.free()
		return

	eq(Game.tables.size(), 3, "3 张桌子都注册进了桌子登记处")

	for child in world.get_children():
		var obj_name := String(child.name)
		var walk: Vector2 = child.call("walk_to")
		var local_pt: Vector2 = child.to_local(walk)

		# 目标点必须在屏幕内
		ok(walk.x >= 0.0 and walk.x <= 1280.0 and walk.y >= 0.0 and walk.y <= 720.0,
			"%s 的 walk_to 在屏幕内 %s" % [obj_name, str(walk)])

		# 除门口外，目标点必须落在**碰撞盒**外面。
		# 站到碰撞盒里 = 被自己的碰撞盒挡住 = 指令永远走不完 = 「点了没反应」。
		#
		# 【为什么按碰撞盒而不是 click_rect】click_rect 是**视觉外框**
		# （后厨/饮料机的视觉框比碰撞盒高 28px），站进视觉框的下缘
		# 既不挡人也不重叠，反而是玩家要的「贴着柜台站」。
		# 原来按 click_rect 判，会把这种正确的锚点误判成 bug。
		var col: Rect2 = child.call("collision_rect_global")
		var local_col: Vector2 = child.to_local(col.position + col.size * 0.5)
		if child.kind == Constants.Kind.DOOR:
			ok(true, "%s 门口不挡人" % obj_name)
		else:
			var box := Rect2(local_col - col.size * 0.5, col.size)
			ok(not box.has_point(local_pt),
				"%s 的 walk_to 在碰撞盒外 %s" % [obj_name, str(local_pt)])

	# 出餐口的小矩形必须嵌在后厨大矩形内部
	var kw: Node = world.get_node_or_null("KitchenWindow")
	if kw != null:
		var body: Rect2 = kw.call("click_rect")
		var pick: Rect2 = kw.get("pickup_rect")
		ok(body.encloses(pick), "出餐口小矩形嵌在后厨大矩形内")
		ok(pick.size.x > 0.0 and pick.size.y > 0.0, "出餐口小矩形有面积")
		# 点小矩形内部走的是取餐，点在外部走的是开后厨 UI
		var centre: Vector2 = kw.to_global(pick.get_center())
		ok(bool(kw.call("is_pickup_point", centre)), "小矩形中心被判定为取餐点")
		var top_left: Vector2 = kw.to_global(body.position + Vector2(8, 8))
		ok(not bool(kw.call("is_pickup_point", top_left)), "大矩形左上角被判定为后厨区")

	level.free()


# ── 9. walk_to 必须落在碰撞盒外面 ──────────────────────────────────

## 【这一节是补上一次漏测】
## 第 8 节原本只断言「walk_to 在家具的**视觉矩形**外面」，
## 结果漏掉了真正致命的情况：目标点在**碰撞盒**里面。
## 那样的家具表现为服务员停在几像素外、指令永远走不完 ——
## 也就是文档里最怕的「点了鼠标没反应」。
## 桌2 和饮料机就是这么挂的，所以这里必须按碰撞盒断言。
const MIN_CLEARANCE := 6.0


func _test_walk_target_clearance() -> void:
	print("[14] walk_to 与碰撞盒的间隙")
	var packed := load("res://scenes/main.tscn") as PackedScene
	var level: Node = packed.instantiate()
	get_tree().root.add_child(level)
	level.get_node("CustomerSpawner").set_process(false)

	for t in Game.tables:
		_check_clearance(t)

	var world: Node = level.get_node("World")
	for child in world.get_children():
		if child.kind == Constants.Kind.DOOR:
			continue          # 门口不挡人
		_check_clearance(child)

	level.free()


func _check_clearance(obj: Node) -> void:
	var walk: Vector2 = obj.call("walk_to")
	var local_pt: Vector2 = obj.to_local(walk)
	var clearance := INF
	var boxes: PackedStringArray = []
	for c in obj.get_children():
		if not (c is CollisionShape2D):
			continue
		var cs: CollisionShape2D = c
		if not (cs.shape is RectangleShape2D):
			continue
		var r := cs.shape as RectangleShape2D
		var box := Rect2(cs.position - r.size * 0.5, r.size)
		boxes.append("box=[%s..%s]" % [str(box.position), str(box.end)])
		clearance = minf(clearance, _dist_to_rect(local_pt, box))
	if clearance == INF:
		ok(true, "%s 没有碰撞盒，不需要间隙" % String(obj.name))
		return
	print("      %-14s walk_global=%s local=%s %s clearance=%.2f" % [
		String(obj.name), str(walk), str(local_pt), " ".join(boxes), clearance])
	ok(clearance >= MIN_CLEARANCE,
		"%s 的 walk_to 离碰撞盒至少 %.0fpx（实际 %.2f，贴太近会走不到）" % [
			String(obj.name), MIN_CLEARANCE, clearance])


## 点到矩形的最短距离（在矩形内返回负值）
func _dist_to_rect(p: Vector2, r: Rect2) -> float:
	if r.has_point(p):
		return -1.0
	var dx := maxf(maxf(r.position.x - p.x, p.x - r.end.x), 0.0)
	var dy := maxf(maxf(r.position.y - p.y, p.y - r.end.y), 0.0)
	return sqrt(dx * dx + dy * dy)
