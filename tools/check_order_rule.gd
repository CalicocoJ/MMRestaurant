extends Node
## 炸鸡块 + 客人点单规则（每桌至少 1 份主食）体检。
##
## 用法：
##   godot --headless --path <project> res://tools/check_order_rule.tscn
##
## 【它验证什么】
##   1. 炸鸡块进了菜单：名字 / 价格 12 / 占位色 / 算主食
##   2. 主食名单 = 菜单里带 main 标记的后厨菜（汉堡 / 薯条 / 炸鸡块），饮品永远不是主食
##   3. **整组订单至少点够 min_main_per_group 份主食**（大样本）
##   4. 「不能只点饮料」真的落到**客人身上**（读客人的点单，不只看 Config）
##   5. 同组客人**同一帧全部生成**，且门口位置错开、不重叠
##   6. 关闭开关（min_main_per_group = 0）时规则确实失效
##   7. 菜单只剩饮料这种无解情况不会死循环
##
## 【为什么用大样本 + 固定种子】
## 这条规则是概率性的：单次摇出「全是饮料」是**正常**的，只有整组一起看才有意义。
## 所以跑几千次统计，并且用 set_seed 固定种子 —— 失败时能一模一样地复现。

var _pass := 0
var _fail := 0


func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

	print("")
	print("════════ 点单规则体检 ════════")

	_test_menu()
	_test_roll_group_orders()
	await _test_group_spawn()
	await _test_spawn_keeps_going()
	_test_level_gating()

	print("═════════════════════════════")
	print("结果：%d 通过 / %d 失败" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# ── 1. 菜单 ────────────────────────────────────────────────────────

func _test_menu() -> void:
	print("[1] 炸鸡块进了菜单")
	eq(Config.item_name(Constants.CHICKEN), "炸鸡块", "名字 = 炸鸡块")
	eq(Config.item_price(Constants.CHICKEN), 12, "价格 = 12 元")
	eq(Config.item_color(Constants.CHICKEN), Color("b5651d"), "占位色 = b5651d")
	ok(Config.has_item(Constants.CHICKEN), "菜单里有 chicken")
	ok(Constants.CHICKEN == "chicken", "Constants.CHICKEN 与 menu.json 的 id 一致")
	ok(Config.item_is_main(Constants.CHICKEN), "炸鸡块算主食")
	eq(Config.kitchen_items.size(), 3, "后厨 3 道（汉堡 / 薯条 / 炸鸡块）")
	# 【不要把数量写死】饮品会随设计增加（可乐/橙汁 → 再加柠檬水）。
	# 写死会让"加一道饮品"变成测试假失败，本轮已经踩过。
	ok(Config.drink_items.size() >= 2,
		"饮品 ≥2 种（当前 %d 种：%s）" % [
			Config.drink_items.size(), _drink_names()])
	ok(Config.has_item("lemonade"), "菜单里有柠檬水（lemonade）")
	eq(Config.item_price("lemonade"), 2, "柠檬水 2 元")
	eq(Config.item_start_level("lemonade"), 3, "柠檬水从第 3 关才出现")
	eq(Config.item_start_level("cola"), 1, "可乐第 1 关就有")

	print("[2] 主食名单")
	var mains := Config.main_item_ids()
	ok(mains.has(Constants.BURGER), "汉堡算主食")
	ok(mains.has(Constants.FRIES), "薯条算主食（用户确认）")
	ok(mains.has(Constants.CHICKEN), "炸鸡块算主食")
	ok(not mains.has(Constants.COLA), "可乐不是主食")
	ok(Config.item_is_main(Constants.COLA) == false, "可乐 item_is_main = false")
	ok(Config.item_is_main("juice") == false, "橙汁不是主食")
	ok(Config.item_is_main("no_such_item") == false, "未知 id 一律不是主食")
	eq(mains.size(), 3, "主食恰好 3 道")


## 菜单里所有饮品的名字（拼成一行，用于断言失败时看清有哪些）
func _drink_names() -> String:
	var parts := PackedStringArray()
	for it in Config.drink_items:
		parts.append(String(it.get("name", it["id"])))
	return " / ".join(parts)


# ── 3. 整组点单规则（大样本）────────────────────────────────────────

func _test_roll_group_orders() -> void:
	print("[3] 整组点单：至少 min_main_per_group 份主食")
	Config.set_seed(20260917)

	var need := int(Config.config.get("min_main_per_group", 1))
	eq(need, 1, "配置里 min_main_per_group = 1")

	# ── 单人组 ──
	var trials := 4000
	var bad1 := 0
	var drink_only := 0
	for i in trials:
		var orders := Config.roll_group_orders(1)
		if orders.size() != 1:
			bad1 += 1
			continue
		var mains := _count_mains(orders[0])
		if mains < need:
			bad1 += 1
		if mains == 0:
			drink_only += 1
	ok(bad1 == 0, "单人组 %d 次：全部至少 1 份主食（违规 %d 次）" % [trials, bad1])
	eq(drink_only, 0, "单人组没有出现「只点饮料」（%d 次）" % drink_only)

	# ── 两人组 ──
	var bad2 := 0
	var both_drink := 0
	for i in trials:
		var orders := Config.roll_group_orders(2)
		if orders.size() != 2:
			bad2 += 1
			continue
		var total := _count_mains(orders[0]) + _count_mains(orders[1])
		if total < need:
			bad2 += 1
		if _count_mains(orders[0]) == 0 and _count_mains(orders[1]) == 0:
			both_drink += 1
	ok(bad2 == 0, "两人组 %d 次：整桌合计至少 1 份主食（违规 %d 次）" % [trials, bad2])
	eq(both_drink, 0, "两人组没有出现「两人都只点饮料」（%d 次）" % both_drink)

	# ── 规则只约束「合计」，不该把每个人都逼成必须点主食 ──
	# 两人组里出现「其中一位只点饮料」是**允许**的（用户确认按整桌算）。
	var one_drink_only := 0
	Config.set_seed(20260918)
	for i in 2000:
		var orders := Config.roll_group_orders(2)
		if orders.size() != 2:
			continue
		var m0 := _count_mains(orders[0])
		var m1 := _count_mains(orders[1])
		if (m0 == 0 and m1 > 0) or (m0 > 0 and m1 == 0):
			one_drink_only += 1
	ok(one_drink_only > 0,
		"两人组里出现过「一人只点饮料、另一人有主食」（%d 次 / 2000）——按整桌算，不按人算"
			% one_drink_only)

	# ── 订单内容仍然是「全菜单随机、1~2 样」 ──
	var sizes_ok := true
	var all_known := true
	Config.set_seed(20260919)
	for i in 1000:
		var orders := Config.roll_group_orders(1)
		var o: Array = orders[0]
		if o.size() < 1 or o.size() > _num(Config.config.get("max_items_per_customer", 2)):
			sizes_ok = false
		for id in o:
			if not Config.has_item(String(id)):
				all_known = false
	ok(sizes_ok, "每人仍然是 1~2 样（沿用 max_items_per_customer）")
	ok(all_known, "订单里的 id 全部存在于菜单")

	print("[4] 开关可以关掉这条规则")
	var saved := int(Config.config.get("min_main_per_group", 1))
	Config.config["min_main_per_group"] = 0
	var off_bad := 0
	Config.set_seed(20260920)
	for i in 4000:
		var orders := Config.roll_group_orders(2)
		if _count_mains(orders[0]) + _count_mains(orders[1]) < 0:
			off_bad += 1
	ok(off_bad == 0, "min_main_per_group = 0 时不再强制主食（不报错）")
	# 关掉之后**应该**能摇出「只点饮料」，否则说明开关没生效
	var found_drink_only := false
	Config.set_seed(20260921)
	for i in 4000:
		var orders := Config.roll_group_orders(1)
		if _count_mains(orders[0]) == 0:
			found_drink_only = true
			break
	ok(found_drink_only, "关掉开关后确实摇得出「只点饮料」（证明开关真的生效）")
	Config.config["min_main_per_group"] = saved

	print("[5] 无解情况不死循环")
	# 菜单里一道主食都没有 → 规则无解，必须直接返回而不是一直重摇
	var saved_kitchen: Array[Dictionary] = Config.kitchen_items.duplicate()
	Config.kitchen_items = [] as Array[Dictionary]
	var t0 := Time.get_ticks_msec()
	var orders_empty := Config.roll_group_orders(2)
	var elapsed := Time.get_ticks_msec() - t0
	ok(elapsed < 2000, "菜单无主食时立刻返回（耗时 %d ms）" % elapsed)
	eq(orders_empty.size(), 2, "仍然返回 2 位客人的订单（不会卡住）")
	Config.kitchen_items = saved_kitchen


## 数一份订单里有几样主食
func _count_mains(order: Array) -> int:
	var n := 0
	for id in order:
		if Config.item_is_main(String(id)):
			n += 1
	return n


# ── 6/7. 整组同时生成 + 规则落到客人身上 ─────────────────────────────
#
# 【为什么必须读客人自己的点单】只验证 Config 是不够的：
## roll_group_orders() 摇对了、但中间某一环没把它传到客人身上的话，
## 「不能只点饮料」在真正玩起来时是失效的 —— 而这种断链不会报错。

func _test_group_spawn() -> void:
	print("[6] 同组客人同一帧生成 + 订单落到客人身上")
	var packed := load("res://scenes/main.tscn") as PackedScene
	var level: Node = packed.instantiate()
	get_tree().root.add_child(level)
	await get_tree().physics_frame

	var spawner: Node = level.get_node_or_null("CustomerSpawner")
	var customers: Node = level.get_node_or_null("Actors/Customers")
	if spawner == null or customers == null:
		ok(false, "CustomerSpawner / Customers 节点存在")
		level.queue_free()
		return

	# 关掉自动生成，免得干扰断言
	spawner.set_process(false)

	var t1: Node = Game.table_by_id(1)
	var seats: Array = t1.free_seats()
	if seats.size() < 2:
		ok(false, "桌1 至少有两个空座")
		level.queue_free()
		return

	Config.set_seed(20260922)
	# 【同一帧】调用前后不做任何 await，成员必须是同一次调用里建出来的
	var group: Array = spawner.call("spawn_group", t1, [seats[0], seats[1]])
	eq(group.size(), 2, "一次调用生成 2 位客人")
	eq(customers.get_child_count(), 2, "两位客人都在同一个子节点容器里（同一帧）")

	# 门口位置必须错开（用户要求：同时生成但不要重叠）
	if group.size() == 2:
		var p0: Vector2 = group[0].global_position
		var p1: Vector2 = group[1].global_position
		var stagger := Config.num("group_entry_stagger")
		ok(absf((p1 - p0).length() - stagger) < 0.5,
			"两人门口起点错开 %.1f px（配置 %.1f，实测 %s → %s）" % [
				(p1 - p0).length(), stagger, str(p0), str(p1)])
		# 两人都还在「走向座位」，即都真的生成了、都在走路
		var walking := 0
		for c in group:
			if _num(c.get("state")) == Constants.State.WALKING_IN:
				walking += 1
		eq(walking, 2, "两人都处于「走向座位」状态")

	# 订单落到客人身上：整桌合计必须有主食
	var mains := 0
	var detail := ""
	for c in group:
		var items: Array = c.call("pending_items")
		mains += _count_mains(items)
		detail += "%s " % str(items)
	ok(mains >= _num(Config.config.get("min_main_per_group", 1)),
		"整桌订单合计 %d 份主食（%s）" % [mains, detail])

	# 再来几组，反复确认（自动生成关着，可以放手调）
	var bad := 0
	for round_i in 40:
		for c in customers.get_children():
			c.queue_free()
		await get_tree().process_frame
		var free_seats: Array = t1.free_seats()
		if free_seats.size() < 2:
			break
		var g: Array = spawner.call("spawn_group", t1, [free_seats[0], free_seats[1]])
		if g.size() != 2:
			bad += 1
			continue
		var m := 0
		for c in g:
			m += _count_mains(c.call("pending_items"))
		if m < _num(Config.config.get("min_main_per_group", 1)):
			bad += 1
	ok(bad == 0, "连续 40 组都是「整桌至少 1 份主食」（违规 %d 组）" % bad)

	print("[7] 单人组也照这条规则来")
	for c in customers.get_children():
		c.queue_free()
	await get_tree().process_frame
	var free1: Array = t1.free_seats()
	var g1: Array = spawner.call("spawn_group", t1, [free1[0]])
	eq(g1.size(), 1, "单人组生成 1 位客人")
	if g1.size() == 1:
		ok(_count_mains(g1[0].call("pending_items")) >= 1,
			"单人组也有主食（%s）" % str(g1[0].call("pending_items")))

	level.queue_free()
	await get_tree().process_frame


# ── 8. 回归：客人必须**一直**来 ────────────────────────────────────
#
# 【这条断言是为什么加的】
# 曾经有一个 bug：改「整组同一帧生成」时留下一个 _group_size 计数器，
# 它只在 spawn_group 末尾被赋值、**没有任何地方清回 0**，
# 而 _attempt_spawn 开头就是 `if _group_size > 0: return`。
# 结果：第一组客人进来之后，**整局再也不生成任何客人**。
# 这个死锁不报错、不警告，只有真的开着找店员跑一段才会发现。
# 所以这里必须在**真正开着自动生成**的完整世界里跑一段，数一数到底来了几组人。

func _test_spawn_keeps_going() -> void:
	print("[8] 自动生成不会「来一组就停」")
	var packed := load("res://scenes/main.tscn") as PackedScene
	var level: Node = packed.instantiate()
	get_tree().root.add_child(level)
	await get_tree().physics_frame

	var spawner: Node = level.get_node_or_null("CustomerSpawner")
	var customers: Node = level.get_node_or_null("Actors/Customers")
	if spawner == null or customers == null:
		ok(false, "CustomerSpawner / Customers 节点存在")
		level.queue_free()
		return

	# 【关键】这一次**不要**关掉自动生成 —— 要测的就是它。
	eq(spawner.is_processing(), true, "自动生成处于开启状态")

	# 诊断：先把「生成的前置条件」逐条打出来，免得断言失败时只能猜。
	var t1: Node = Game.table_by_id(1)
	print("  [诊断] 起始：桌子=%d 张，空桌=%d，空桌计时=%.2fs（要求 %.2fs）" % [
		Game.tables.size(), Game.empty_table_count(),
		t1.available_duration() if t1 != null else -1.0,
		Config.num("empty_table_delay")])
	print("  [诊断] 检测间隔=%.2fs，组大小权重=%s" % [
		Config.num("customer_spawn_check_interval"),
		str(Config.config.get("group_size_weights", {}))])

	# 手动推进世界 30 秒（与 screenshot.gd 同一套做法：只驱动 World/Actors），
	# 每步检查一次客人数量。检测间隔 1s，30 秒足够来好几组。
	const STEP := 1.0 / 60.0
	var max_alive := 0
	var ever_alive := 0
	var steps := int(30.0 / STEP)
	var wall_start := Time.get_ticks_msec()
	for i in steps:
		for group in ["World", "Actors"]:
			var n := level.get_node_or_null(group)
			if n != null:
				_walk_tree(n, "_physics_process", STEP)
				_walk_tree(n, "_process", STEP)
		var alive := customers.get_child_count()
		if alive > max_alive:
			max_alive = alive
		ever_alive = maxi(ever_alive, alive)
		await get_tree().process_frame
	var wall_ms := Time.get_ticks_msec() - wall_start
	print("  [诊断] 推进 %d 步结束：墙上耗时 %d ms，空桌=%d，在店=%s，已坐下累计=%d" % [
		steps, wall_ms, Game.empty_table_count(),
		str(spawner.call("in_store_count")), level.seated_total])
	# 【分辨「引擎到底有没有给 spawner 发 _process」】
	# 这两条是排查「整棵树被暂停 → _process 不跑 → 客人永远不来」时唯一有效的证据。
	print("  [诊断] spawner: is_processing=%s 时钟=%.3f 间隔=%.2f tree.paused=%s" % [
		str(spawner.is_processing()), float(spawner.get("_check_clock")),
		Config.num("customer_spawn_check_interval"), str(get_tree().paused)])

	# 「整局只来一组」就是那个 bug 的特征：客人数量再也回不到 0 之后的新高。
	ok(max_alive >= 2,
		"30 秒内同时出现过 ≥2 位客人（实测峰值 %d）—— 不是「来一组就停」" % max_alive)
	ok(ever_alive > 0, "确实有客人被生成（峰值 %d）" % ever_alive)

	# 更直接的判据：这一局**一共坐下了几位客人**。
	# 只有第一组的话，这个数最多是 2（组大小上限）。
	#
	# 【不要写 int(level.get("seated_total"))】
	# `Node.get()` 返回 Variant，实测那样写在 GDScript 里会抛
	# "Nonexistent 'int' constructor" —— 脚本错误把协程直接中断，
	# 后面几条断言**一行都没跑**，而工具照样打印「37 通过」，看着是全绿。
	# 直接读公开字段即可（类型明确，不需要转换）。
	var created: int = level.seated_total
	ok(created >= 3,
		"30 秒内一共坐下了 ≥3 位客人（实测 %d 位）—— 说明第一组之后还在继续生成" % created)

	level.queue_free()
	await get_tree().process_frame


func _walk_tree(node: Node, method: String, delta: float) -> void:
	if node.has_method(method):
		node.call(method, delta)
	for c in node.get_children():
		_walk_tree(c, method, delta)


## 把「可能是 null 的动态返回值」安全地取成 int。
##
## 【为什么不能直接写 int(x)】
## `Node.call()` / `Node.get()` 返回 Variant，客人容器为空时
## `in_store_count()` 会返回 **null** —— 而 GDScript 里 `int(null)` 并不返回 0，
## 它抛 `Invalid call. Nonexistent 'int' constructor`。
## 这种脚本错误会**直接中断当前协程**：后面的断言一行都不跑，
## 而工具照样把已有断言打成「全部通过」，看上去一片绿。本轮被它骗过两次。
func _num(v: Variant) -> int:
	match typeof(v):
		TYPE_INT: return int(v)
		TYPE_FLOAT: return int(v)
		TYPE_BOOL: return 1 if bool(v) else 0
		_: return 0


# ── 9. 菜单的「按关卡解锁」（start_level）────────────────────────────
#
# 【它验证什么】已与玩家确认：柠檬水是第 3 关才加的，前两关不该出现。
# 菜单是全局的，所以用 start_level 表达渐进解锁。**两处**都必须尊重它：
#   ① 客人点单的抽取池（否则前两关的客人会点柠檬水，而饮料机没有按钮 → 永远上不了）
#   ② 饮料机 UI 的按钮（否则第 1 关就能买到第 3 关的饮品）

func _test_level_gating() -> void:
	print("[9] 菜单按关卡解锁（柠檬水第 3 关才有）")
	var saved := Game.level_index
	var lemon := "lemonade"

	# ── 按关卡查菜单 ──
	Game.set_level_index(1)
	ok(not Config.item_available_at(lemon, 1), "第 1 关：柠檬水不可用")
	ok(not Config.pool_at(1).has(lemon), "第 1 关：点单池里没有柠檬水")
	ok(not _ids_of(Config.drink_items_at(1)).has(lemon),
		"第 1 关：饮料机菜单里没有柠檬水（%s）" % str(_ids_of(Config.drink_items_at(1))))
	Game.set_level_index(2)
	ok(not Config.item_available_at(lemon, 2), "第 2 关：柠檬水仍不可用")
	Game.set_level_index(3)
	ok(Config.item_available_at(lemon, 3), "第 3 关：柠檬水可用")
	ok(Config.pool_at(3).has(lemon), "第 3 关：点单池里有柠檬水")
	ok(_ids_of(Config.drink_items_at(3)).has(lemon),
		"第 3 关：饮料机菜单里有柠檬水（%s）" % str(_ids_of(Config.drink_items_at(3))))
	Game.set_level_index(5)
	ok(Config.item_available_at(lemon, 5), "第 5 关：柠檬水仍然可用")

	# ── 真正摇一批订单：前两关绝不能出现柠檬水 ──
	# （大样本，因为点单是随机的）
	var bad1 := 0
	var bad2 := 0
	var good3 := 0
	Config.set_seed(20260925)
	Game.set_level_index(1)
	for i in 1500:
		if Config.roll_group_orders(2).any(func(o): return (o as Array).has(lemon)):
			bad1 += 1
	Game.set_level_index(2)
	for i in 1500:
		if Config.roll_group_orders(2).any(func(o): return (o as Array).has(lemon)):
			bad2 += 1
	Game.set_level_index(3)
	for i in 1500:
		if Config.roll_group_orders(2).any(func(o): return (o as Array).has(lemon)):
			good3 += 1
	eq(bad1, 0, "第 1 关 1500 组订单：**一次都没点柠檬水**")
	eq(bad2, 0, "第 2 关 1500 组订单：**一次都没点柠檬水**")
	ok(good3 > 0, "第 3 关 1500 组订单：出现柠檬水 %d 次（证明解锁真的生效）" % good3)

	# ── 「每桌至少 1 份主食」这条规则不受影响 ──
	# 柠檬水是**饮料**、不是主食，加了它之后 3 主食 / 3 饮料，规则照旧成立
	Game.set_level_index(3)
	var need := int(Config.config.get("min_main_per_group", 1))
	var viol := 0
	for i in 2000:
		var orders := Config.roll_group_orders(2)
		var mains := _count_mains(orders[0]) + _count_mains(orders[1])
		if mains < need:
			viol += 1
	eq(viol, 0, "第 3 关（有柠檬水）：2000 组订单仍然全部满足主食下限")
	ok(not Config.item_is_main(lemon), "柠檬水不是主食")

	Game.set_level_index(saved)


func _ids_of(items: Array) -> Array:
	var out: Array = []
	for it in items:
		out.append(String((it as Dictionary).get("id", "")))
	return out


# ── 断言小工具 ─────────────────────────────────────────────────────

func ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
		print("  PASS  ", what)
	else:
		_fail += 1
		print("  FAIL  ", what)


func eq(actual: Variant, expected: Variant, what: String) -> void:
	if actual == expected:
		_pass += 1
		print("  PASS  ", what)
	else:
		_fail += 1
		print("  FAIL  %s（期望 %s，实际 %s）" % [what, str(expected), str(actual)])
