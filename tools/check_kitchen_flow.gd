extends Node
## 后厨「点了单就一直做」+ 出餐口容量 2 体检。
##
## 用法：
##   godot --headless --path <project> res://tools/check_kitchen_flow.tscn
##
## 【它验证的是玩家提的这条需求】
## 「只要玩家点单，后厨就开始制作，而不是等取走一份再做下一份」
## —— 即后厨**不再被出餐口卡住**；做好的菜先预存，出餐口一空出来
## 就**当帧**补上（玩家看到的是"它一直在那儿排队"）。
##
## 【顺带验证】出餐口容量从 1 改成 2 之后：
##   - 能同时放 2 份、能一次拿走 2 份（受手上容量限制）
##   - 取走一份后**同一帧**就被补满（不是等下一帧或下一道）
##   - HUD 的「后厨队列」把预存的也算进去（否则会看到 0 却还在冒菜）

var _pass := 0
var _fail := 0


func _ready() -> void:
	await get_tree().process_frame
	print("")
	print("════════ 后厨出餐流程体检 ════════")

	_test_no_blocking()
	_test_sequential_cooking()
	_test_instant_refill()
	await _test_real_pickup()

	print("═══════════════════════════════")
	print("结果：%d 通过 / %d 失败" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# ── 1. 纯逻辑：出餐口满了，后厨也把菜做完（预存）────────────────────

func _test_no_blocking() -> void:
	print("[1] 后厨不再被出餐口卡住（点单就一直做）")
	var k := Kitchen.new(3.0, 2)
	k.enqueue(["burger", "fries", "chicken"] as Array[String])
	eq(k.queue_count(), 3, "下了 3 份，队列 3")

	# 【不要用「调几次 update(3.05)」来推后厨】踩过：第二份做完后计时被重置为满
	# 3 秒，剩下的 0.05 秒不够做第三份，于是"第三份已做好"的断言全错。
	# 这类"按秒数猜进度"的写法很脆；用 fast_forward 推到确定的状态再断言。
	k.fast_forward(3.05)
	eq(k.counter_slot(), "burger", "第 1 份（汉堡）上了出餐口")
	k.fast_forward(3.05)
	eq(k.counter_slots().size(), 2, "第 2 份也上了出餐口（容量 2）")
	eq(k.counter_slots(), ["burger", "fries"] as Array[String], "顺序 = 入队顺序")

	# 【关键】把 3 份全部做完：出餐口只放得下 2 份，第 3 份被预存
	k.fast_forward(3.05)
	eq(k.counter_slots(), ["burger", "fries"] as Array[String],
		"出餐口仍然只有 2 份（容量上限）")
	eq(k.queue_count(), 0, "**三份都做完了**，队列已空（后厨没被卡住）")
	eq(k.pending_count(), 1, "第 3 份（炸鸡块）已做好、在等位置")

	# 玩家取走一份 → 出餐口空位出现 → 第 3 份**当帧**补上
	var taken := k.take_from_counter()
	eq(taken, "burger", "取走的是队首那份（汉堡）")
	eq(k.counter_slots(), ["fries", "chicken"] as Array[String],
		"**取走一份后，第 3 份立刻补上**（不需要再等 3 秒）")
	eq(k.pending_count(), 0, "厨房里已经没有待出的了")

	# 空出餐口 + HUD 计数
	k.take_from_counter()
	k.take_from_counter()
	ok(k.counter_is_empty(), "全部取完后出餐口为空")
	eq(k.pending_count(), 0, "队列与预存都为 0")
	eq(k.counter_name(), "空", "counter_name 空态仍是「空」")


# ── 1b. 一道一道做：每道都要完整的 3 秒（不能同时出餐）────────────────
#
# 【为什么必须有这条断言】这里连续错了两版，两次都是"只断言状态、没断言间隔"：
#   ① 计时被重置成满周期 → 每道多等一个周期（3 份要 12 秒）
#   ② 我改成 timer = 0 → **下一帧立刻又出一份**，3 份在 3.0/3.05/3.1 秒挤出来
#      —— 玩家看到的就是「一起下单的菜同时做好、同时出现」，不符合现实逻辑。
# 只断言"最后有几份"是抓不到 ② 的（最终状态一样），**必须断言出餐的时间间隔**。

func _test_sequential_cooking() -> void:
	print("[1b] 下单 3 份 → 一道一道做，每道 3 秒（不能同时出餐）")
	# 【怎么量最可靠】记录 **pending_count() 每次下降**的时刻
	# （pending = queue + 预存 = 还没上架的总数）。每做完一道它就减 1，
	# 所以相邻两个下降时刻的间隔就是"每道要多久"。
	# 【不要用"出餐口份数/内容变化"来量】玩家取餐会当帧补位，份数不下降；
	# 容量 1 时还会卡住（出餐口被占 + 预存满 → 后厨停工），等不到后续。
	var k := Kitchen.new(3.0, 2)
	k.enqueue(["burger", "fries", "chicken"] as Array[String])
	var marks: Array[float] = []
	var last := k.pending_count()
	var t := 0.0
	while t < 13.0 and marks.size() < 3:
		k.update(0.1)
		t += 0.1
		var cur := k.pending_count()
		if cur < last:
			marks.append(t)
			print("    [时间线] t=%.1fs 做完第 %d 道（pending %d → %d）" % [
				t, marks.size(), last, cur])
			last = cur

	# 【为什么只记录到 2 次下降】第 3 道做好后会**停在预存区**（出餐口满了），
	# 所以 pending 只降到 1 就不再降 —— 这是设计如此（容量 2 只能摆 2 份）。
	# 要验的"一道一道做"看的是**前两次的间隔**：每道都必须间隔约 3 秒。
	eq(marks.size(), 2, "记录到 2 次「做完一道」（第 3 道停在预存区，pending 下限是 1）")
	eq(k.pending_count(), 1, "第 3 道已做好、在预存区等着（pending=1）")
	ok(k.queue_count() == 0, "三道都已经做完，队列空了")
	if marks.size() >= 2:
		var gap := marks[1] - marks[0]
		ok(absf(marks[0] - 3.0) < 0.3, "第 1 道在 3 秒做完（实际 %.1fs）" % marks[0])
		ok(absf(gap - 3.0) < 0.3,
			"**第 1→2 道间隔 %.1fs（≈3s：一道一道做，不是同时出）**" % gap)
		ok(gap > 1.5, "**两道之间没有几乎同时做好**（间隔 %.1fs > 1.5s）" % gap)

	# 【注意这里要多走一帧】做好的菜先进预存区，补到出餐口发生在
	# **下一次 update 的开头**（或者玩家取走一份时）。
	# 所以「计时器语义」要这样验：
	var k2 := Kitchen.new(3.0, 1)
	k2.enqueue(["burger", "fries"] as Array[String])
	k2.update(3.0)                      # 第 1 份做完（进预存）
	k2.update(0.01)                     # 这一帧开头把它补到出餐口
	eq(k2.counter_slot(), "burger", "第 1 份出餐")
	ok(absf(k2.timer - 3.0) < 0.06,
		"**做完第 1 份后计时重置为满 3 秒**（下一道要重新做，实际 %.2f）" % k2.timer)
	k2.update(0.1)
	eq(k2.counter_slot(), "burger", "再过 0.1 秒不会冒出第二份（它得重做 3 秒）")
	k2.update(3.0)                      # 第 2 份做完（进预存，出餐口被占）
	eq(k2.pending_count(), 1, "第 2 份做好后停在预存区（出餐口满了）")
	eq(k2.take_from_counter(), "burger", "取走第 1 份（汉堡）")
	eq(k2.counter_slot(), "fries",
		"**取走后预存的那份瞬间补上**（不是等下一帧、更不是卡住）")
	eq(k2.pending_count(), 0, "厨房里已经没有待出的了")


# ── 2. 预存只在"没位置"时存在，且立刻补位 ──────────────────────────

func _test_instant_refill() -> void:
	print("[2] 取走一份 → 同一帧补满（不是等下一帧）")
	var k := Kitchen.new(3.0, 2)
	k.enqueue(["burger", "fries", "chicken"] as Array[String])
	# 一道一道做，每道 3 秒 → 3 份在 9 秒左右全部做完
	# （出餐口 2 份 + 预存 1 份）。见 [1b] 对"间隔必须是 3 秒"的断言。
	k.fast_forward(9.5)
	eq(k.counter_slots().size(), 2, "出餐口 2 份")
	eq(k.queue_count(), 0, "队列已空（三份都做完了）")
	eq(k.pending_count(), 1, "1 份预存")
	eq(k.pending_count(), 1, "1 份预存")

	# 取一份，**不做任何 update**，出餐口就该已经是 2 份
	var before := k.counter_slots().size()
	k.take_from_counter()
	eq(before, 2, "取之前是 2 份")
	eq(k.counter_slots().size(), 2,
		"**没有调用 update 就已经补满**（补位发生在取餐这一步里，不是下一帧）")

	# 容量 1 的老行为不能被破坏：满了就不再上架，取走才补下一道
	var k1 := Kitchen.new(3.0, 1)
	k1.enqueue(["burger", "fries"] as Array[String])
	k1.fast_forward(9.0)                      # 同样推够：两份都做完
	eq(k1.counter_slots().size(), 1, "容量 1 时出餐口仍是 1 份")
	eq(k1.counter_slot(), "burger", "容量 1 时不会被覆盖")
	eq(k1.pending_count(), 1, "另一份已做好、在等位置")
	k1.take_from_counter()
	eq(k1.counter_slot(), "fries", "容量 1：取走后预存的那份立刻补上")


# ── 3. 走真实点击链路：一次能拿走 2 份 ────────────────────────────
#
# 【为什么必须走点击链路】取餐是「点击 → 走过去 → 到达时再检查」两阶段的，
# 直接调 _do_take 会绕过玩家真正走的那条路（项目规矩：新交互必须用
# ClickRouter.handle_click 驱动）。

func _test_real_pickup() -> void:
	print("[3] 真实点击取餐：一次拿走 2 份（受手上容量限制）")
	var level: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(level)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var spawner: Node = level.get_node("CustomerSpawner")
	spawner.set_process(false)             # 免得生成客人干扰
	var counter: Node = level.get_node("World/KitchenWindow")
	var router: Node = level.get_node("ClickRouter")
	var waiter: Node = level.get_node("Actors/Waiter")

	ok(counter != null, "找到出餐口节点")
	if counter == null:
		level.queue_free()
		return

	# 出餐口准备好 2 份（直接摆数据，投递动作仍走真实点击）
	Game.clear_hand()
	Game.kitchen.enqueue(["burger", "fries", "chicken"] as Array[String])
	Game.kitchen.fast_forward(9.0)
	eq(Game.kitchen.counter_slots().size(), 2, "出餐口有 2 份待取")

	# 点出餐口小矩形的中心（世界坐标）
	var pickup_pt: Vector2 = counter.to_global(counter.pickup_rect.get_center())
	ok(counter.call("is_pickup_point", pickup_pt), "点的是「出餐口小矩形」那一块")
	waiter.global_position = Vector2(560, 500)
	router.call("handle_click", pickup_pt)
	# 等服务员走完并取餐
	await get_tree().physics_frame
	var saw_busy := false
	for i in 600:
		var busy := bool(waiter.call("is_busy"))
		if busy:
			saw_busy = true
		elif saw_busy:
			break
		await get_tree().physics_frame

	eq(Game.hand_items().size(), 2,
		"**一次点击拿走了 2 份**（手上容量 2，实测 %s）" % str(Game.hand_items()))
	ok(Game.hand_has("burger") or Game.hand_has("fries"), "拿到的是出餐口里的菜")
	eq(Game.kitchen.counter_slots(), ["chicken"] as Array[String],
		"出餐口只剩预存的那份（已经补上位）")

	# 手上满了 → 再点应提示拿不下，而不是把出餐口那份也塞进来
	router.call("handle_click", pickup_pt)
	await get_tree().physics_frame
	eq(Game.hand_items().size(), 2, "手上满了，没有再拿走（仍是 2 份）")
	eq(Game.kitchen.counter_slots().size(), 1, "出餐口那份原封不动")

	# ── 【本轮新增的回归】忙的时候点饮料机/点餐台，弹窗必须等**真的走到** ──
	#
	# 玩家反馈：「离饮料机还有很远的距离就可以直接点饮料了，点餐台也一样」。
	# 根因在 `command_move()` 的执行顺序：先 `_compute_goal()`、后赋值
	# `_target`/`_touch_target`，于是新指令算出的是**上一条指令**的落脚点 ——
	# 服务员还在桌子那边（离旧落脚点 4.3px），同帧就判「到了」→ 立刻回调 →
	# 原地就弹窗。这一条专门盯住它。
	await _test_popup_waits_for_arrival(level, router, waiter, counter)

	level.queue_free()
	await get_tree().process_frame


## 回归：服务员在忙（正走向脏桌）时点饮料机 / 点餐台，
## 弹窗必须等它走到目标旁边才开，不能在原地就弹。
func _test_popup_waits_for_arrival(level: Node, router: Node, waiter: Node,
		counter: Node) -> void:
	print("[4] 忙的时候点饮料机/点餐台：弹窗要等服务员真的走到")
	var drink: Node = level.get_node("World/DrinkMachine")
	var table: Node = Game.table_by_id(2)

	for spec in [
		{"name": "饮料机", "point": Vector2(900, 140),
			"visual": Rect2(Vector2(845, 96), Vector2(110, 100))},
		{"name": "点餐台", "point": counter.to_global(counter.pickup_rect.get_center())
			- Vector2(0, 30),
			"visual": Rect2(Vector2(420, 96), Vector2(240, 100))},
	]:
		UI.close_popups()
		waiter.call("cancel_command", "体检复位")
		await get_tree().physics_frame

		# 让服务员先忙起来：点一张脏桌，它会走过去收拾
		Game.clear_hand()
		table.state = TableRules.State.DIRTY
		table.call("_refresh_look")
		waiter.global_position = Vector2(310, 470)
		waiter.set("_last_pos", Vector2(310, 470))
		router.call("handle_click", table.call("walk_to"))
		# 只等一帧就点目标 —— 这时它才刚迈步，离目标半个屏幕
		await get_tree().physics_frame
		var started_at: Vector2 = waiter.global_position
		router.call("handle_click", spec["point"])

		var opened_frame := -1
		var pos_when_open := Vector2.ZERO
		for i in 600:
			await get_tree().physics_frame
			if UI.is_any_popup_open():
				opened_frame = i
				pos_when_open = waiter.global_position
				break
			if not bool(waiter.call("is_busy")) and not bool(waiter.call("is_locked")) and i > 30:
				break

		var gap: float = pos_when_open.distance_to(
			EntityBase.nearest_point_on_rect(spec["visual"], pos_when_open))
		ok(opened_frame > 20,
			"%s：弹窗在第 %d 帧才开（不是在原地第 0~1 帧就弹）" % [spec["name"], opened_frame])
		ok(gap <= 24.0,
			"%s：弹窗打开时服务员离它 %.0fpx（≤24 = 真的走到了）" % [spec["name"], gap])
		ok(pos_when_open.distance_to(started_at) > 100.0,
			"%s：他确实走过去了一趟（移动了 %.0fpx）" % [
				spec["name"], pos_when_open.distance_to(started_at)])
		UI.close_popups()
		waiter.call("cancel_command", "体检复位")
		await get_tree().physics_frame


# ── 断言 ───────────────────────────────────────────────────────────

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
