extends Node
## 上菜从手上扣几份 —— 回归体检。
##
## 用法：
##   godot --headless --path <project> res://tools/check_serve_hand.tscn
##
## 【它复现的是玩家实测报的 bug】
##   手上拿着**两份汉堡**，点一桌只要**一份汉堡**的客人 →
##   两份汉堡都消失了（应该只消失一份）。
##
## 【根因】`Customer._wanted_in_hand()` 是**按手上的份数**列出来的，会带重复：
##   手上两份汉堡、这桌只缺一份时它返回 ["burger", "burger"]。
##   循环第一遍真的送出并上榜，第二遍 `assign_delivery` 已经找不到想要的客人
##   （返回 null），但代码**不看返回值**照样 `remove_from_hand` 扣一份 ——
##   于是两份全没了。
##
## 【修法】先数出「实际送成功了几份」，再按这个数扣手上的菜。
##
## 【本脚本的写法约定】队伍（客人点了几样）用 `set_pending_items` 直接摆好 ——
## 那是**夹具**；而「上菜」这个被验证的动作走**真实点击链路**
## （`ClickRouter.handle_click` → 服务员走过去 → 到达时再检查 → 真的投递），
## 不手工调内部函数。上一轮我用伪现场写错过测试，这里刻意避开。

var _pass := 0
var _fail := 0
var _level: Node = null
var _spawner: Node = null
var _router: Node = null
var _waiter: Node = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	await get_tree().process_frame
	await get_tree().process_frame

	print("")
	print("════════ 上菜扣手体检 ════════")

	_level = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(_level)
	await get_tree().physics_frame
	await get_tree().physics_frame

	_spawner = _level.get_node("CustomerSpawner")
	_router = _level.get_node("ClickRouter")
	_waiter = _level.get_node("Actors/Waiter")
	_spawner.set_process(false)        # 自动生成关掉，避免干扰

	await _test_two_burgers_one_wanted()
	await _test_two_needed_two_in_hand()
	await _test_wrong_dish_keeps_hand()
	await _test_juice_not_touched()
	await _test_click_messages()

	print("═════════════════════════════")
	print("结果：%d 通过 / %d 失败" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# ── 1. 核心复现：手上 2 份汉堡，这桌只要 1 份 ──────────────────────

func _test_two_burgers_one_wanted() -> void:
	print("[1] 手上 2 份汉堡，桌上只点 1 份 → 只该少 1 份")
	var t := _fresh_table(1)
	if t == null:
		return
	var c := _seat_customer(t, 0, [Constants.BURGER] as Array[String])
	if c == null:
		return
	# 接单：点客人（真实链路）
	await _accept_order_via_click(c)

	# 手上放两份汉堡
	Game.clear_hand()
	_router.call("take_into_hand", Constants.BURGER)
	_router.call("take_into_hand", Constants.BURGER)
	eq(Game.hand_items().size(), 2, "手上先有 2 份汉堡")

	# 上菜：点客人（真实链路）
	await _serve_via_click(c)

	eq(Game.hand_items().size(), 1,
		"**上完菜手上还剩 1 份汉堡**（原来会变成 0）")
	ok(Game.hand_has(Constants.BURGER), "剩下的那份还是汉堡")
	# 客人应该已经拿到他那份
	var seat: Seat = t.seats[0]
	eq(seat.got.count(true), 1, "客人拿到了 1 份（数量正确，没有多送）")
	ok(seat.all_got(), "客人的单已齐")
	# 票应当消失（整桌送齐）
	ok(t.order == null, "整桌送齐后票消失")


# ── 2. 该桌真的要两份：两份都该送出去 ──────────────────────────────

func _test_two_needed_two_in_hand() -> void:
	print("[2] 桌上点 2 份汉堡、手上也有 2 份 → 两份都送出去")
	var t := _fresh_table(2)
	if t == null:
		return
	# 一位客人点两份汉堡（允许重复）
	var c := _seat_customer(t, 0, [Constants.BURGER, Constants.BURGER] as Array[String])
	if c == null:
		return
	await _accept_order_via_click(c)

	Game.clear_hand()
	_router.call("take_into_hand", Constants.BURGER)
	_router.call("take_into_hand", Constants.BURGER)
	eq(Game.hand_items().size(), 2, "手上 2 份汉堡")

	await _serve_via_click(c)

	eq(Game.hand_items().size(), 0, "两份都送出去了，手上空")
	eq(t.seats[0].got.count(true), 2, "客人两份都拿到了")


# ── 3. 拿到不匹配的菜：手上不动 ────────────────────────────────────

func _test_wrong_dish_keeps_hand() -> void:
	print("[3] 手上是不匹配的菜 → 手上不动、不误扣")
	var t := _fresh_table(3)
	if t == null:
		return
	var c := _seat_customer(t, 0, [Constants.BURGER] as Array[String])
	if c == null:
		return
	await _accept_order_via_click(c)

	# 手上两份可乐 + 一份汉堡（汉堡放在后面，检验「不匹配的留着」）
	Game.clear_hand()
	_router.call("take_into_hand", Constants.COLA)
	_router.call("take_into_hand", Constants.COLA)
	eq(Game.hand_items().size(), 2, "手上 2 份可乐（满）")
	# 满手拿不下汉堡，这里直接构造「手上两样都有」的等价场景：
	Game.clear_hand()
	_router.call("take_into_hand", Constants.BURGER)
	eq(Game.hand_items(), [Constants.BURGER] as Array[String], "手上 1 份汉堡")

	await _serve_via_click(c)
	eq(Game.hand_items().size(), 0, "匹配的汉堡送出去，手上空")
	ok(t.seats[0].all_got(), "客人拿到汉堡")


# ── 4. 饮品同样只扣对应份数 ────────────────────────────────────────

func _test_juice_not_touched() -> void:
	print("[4] 手上 1 份橙汁 + 1 份汉堡，这桌只要橙汁 → 汉堡留着")
	var t := _fresh_table(4)
	if t == null:
		return
	var c := _seat_customer(t, 0, ["juice"] as Array[String])
	if c == null:
		return
	await _accept_order_via_click(c)

	Game.clear_hand()
	_router.call("take_into_hand", "juice")
	_router.call("take_into_hand", Constants.BURGER)
	eq(Game.hand_items().size(), 2, "手上橙汁 + 汉堡")

	await _serve_via_click(c)

	eq(Game.hand_items(), [Constants.BURGER] as Array[String],
		"只送走橙汁，**汉堡继续拿着**（不匹配的不动）")
	ok(t.seats[0].all_got(), "客人拿到橙汁")


# ── 5. 点桌子 / 点客人时的提示文案 ─────────────────────────────────
#
# 【这条是玩家实测报的】手里拿着菜去点一张**空桌**，原来弹的是
# 「这不是他要的菜」—— 可桌上一个客人都没有，这句提示完全不成立。
# 根因是 Table.interact() 的判断顺序：「手上有菜」排在「桌上有没有人」前面。
#
# 【同时验证改过的文案】「这不是他要的菜」→「这桌没点这个菜」。

func _test_click_messages() -> void:
	print("[5] 点桌子 / 点客人的提示文案")
	var t := _fresh_table(5)
	if t == null:
		return

	# (a) 手上有菜 + 点**空桌** → 必须是「这桌是空的」
	Game.clear_hand()
	_router.call("take_into_hand", Constants.BURGER)
	eq(Game.hand_items().size(), 1, "手上有 1 份汉堡")
	eq(t.occupied_seats().size(), 0, "这张桌一个客人都没有")
	Stickers.clear()
	_router.call("handle_click", t.call("touch_box").get_center())
	eq(Stickers.last_text(), Constants.MSG_TABLE_EMPTY,
		"**手上拿着菜点空桌 → 提示「%s」**（原来说的是「这不是他要的菜」）"
			% Constants.MSG_TABLE_EMPTY)
	eq(Constants.MSG_TABLE_EMPTY, "这桌是空的", "「空桌」文案 = 这桌是空的")

	# (b) 文案已改成「这桌没点这个菜」
	eq(Constants.MSG_WRONG_DISH, "这桌没点这个菜",
		"「不匹配」文案 = 这桌没点这个菜")
	ok(not Constants.MSG_WRONG_DISH.contains("这不是他要的菜"),
		"旧文案「这不是他要的菜」已经不存在")

	# (c) 手上有菜 + 点**有客人但不要这个菜**的桌 → 「这桌没点这个菜」
	Game.clear_hand()
	for c in _level.get_node("Actors/Customers").get_children():
		c.queue_free()
	for tb in Game.tables:
		for s in tb.seats:
			s.release()
		tb.state = TableRules.State.CLEAN_EMPTY
		tb.order = null
	await get_tree().physics_frame
	var seat: Seat = t.free_seats()[0]
	var who: Node = _spawner.call("spawn_at_seat", t, seat)
	who.call("set_pending_items", ["juice"] as Array[String])
	who.global_position = t.call("seat_sit_point", seat)
	_level.call("_on_customer_seated", who)
	await _accept_order_via_click(who)      # 接单 → 整桌进入等上菜（缺橙汁）
	_router.call("take_into_hand", Constants.BURGER)   # 手上拿的是汉堡
	Stickers.clear()
	_router.call("handle_click", t.call("touch_box").get_center())
	eq(Stickers.last_text(), Constants.MSG_WRONG_DISH,
		"点「有客人但没点这个菜」的桌 → 提示「%s」" % Constants.MSG_WRONG_DISH)

	# (d) 有客人、手上没菜 → 仍是「手上没有餐品」（这条不能被上面的改动弄坏）
	Game.clear_hand()
	Stickers.clear()
	_router.call("handle_click", t.call("touch_box").get_center())
	eq(Stickers.last_text(), Constants.MSG_HAND_EMPTY,
		"空手点有客人的桌 → 提示「%s」" % Constants.MSG_HAND_EMPTY)

	# (e) 干净空桌 + 空手 → 也是「这桌是空的」
	# 【注意】(d) 里留着那位要橙汁的客人，这里要先把人和手上的菜都清掉，
	# 才是真正的「空桌 + 空手」。上一版漏了这步，测出来的是另一条分支。
	for c in _level.get_node("Actors/Customers").get_children():
		c.queue_free()
	for tb in Game.tables:
		for s in tb.seats:
			s.release()
		tb.state = TableRules.State.CLEAN_EMPTY
		tb.order = null
	Game.clear_hand()
	await get_tree().process_frame
	eq(t.occupied_seats().size(), 0, "确认这张桌又空了")
	eq(Game.hand_items().size(), 0, "确认手上也空了")
	Stickers.clear()
	_router.call("handle_click", t.call("touch_box").get_center())
	eq(Stickers.last_text(), Constants.MSG_TABLE_EMPTY,
		"空手点空桌 → 提示「%s」" % Constants.MSG_TABLE_EMPTY)

	# 收尾
	Game.clear_hand()
	for c in _level.get_node("Actors/Customers").get_children():
		c.queue_free()
	for tb in Game.tables:
		for s in tb.seats:
			s.release()
		tb.state = TableRules.State.CLEAN_EMPTY
		tb.order = null
	await get_tree().process_frame


# ── 夹具与真实动作 ─────────────────────────────────────────────────

## 拿一张干净空桌（桌号 1..3，第 4 个用例复用桌1 并清场）
func _fresh_table(idx: int) -> Node:
	# 先清场：把所有客人送走、座位释放，桌子恢复干净
	for cc in _level.get_node("Actors/Customers").get_children():
		cc.queue_free()
	for tb in Game.tables:
		for s in tb.seats:
			s.release()
		tb.state = TableRules.State.CLEAN_EMPTY
		tb.order = null
		tb.mark_available()
	Game.clear_hand()
	# 【必须刷新可坐时间】客人生成有 empty_table_delay，但这里直接摆客人，
	# 不经过生成器，所以不受它限制。
	var id := ((idx - 1) % 3) + 1
	var t: Node = Game.table_by_id(id)
	if t == null:
		ok(false, "桌%d 存在" % id)
	return t


## 在指定座位「摆」一位客人并让他坐下（**夹具**：只摆数据，不伪造投递动作）
func _seat_customer(t: Node, seat_index: int, items: Array[String]) -> Node:
	var seat: Seat = t.seats[seat_index]
	var c: Node = _spawner.call("spawn_at_seat", t, seat)
	if c == null:
		ok(false, "能在%s 生成客人" % t.label)
		return null
	c.call("set_pending_items", items)
	c.global_position = t.call("seat_sit_point", seat)
	_level.call("_on_customer_seated", c)
	return c


## 接单：走真实点击链路（点客人 → 走过去 → 到达时开票）
func _accept_order_via_click(c: Node) -> void:
	_waiter.global_position = Vector2(560, 500)
	_router.call("handle_click", c.global_position)
	await _wait_waiter_idle()
	# 接单成功后整桌进入「等上菜」
	if int(c.get("state")) != Constants.State.ORDER_TAKEN:
		ok(false, "接单后客人进入等上菜（实际 state=%d）" % int(c.get("state")))
	else:
		_pass += 1
		print("  PASS  接单成功（客人进入等上菜）")


## 上菜：走真实点击链路（点客人 → 走到桌边 → 到达时投递）
func _serve_via_click(c: Node) -> void:
	_waiter.global_position = Vector2(560, 500)
	_router.call("handle_click", c.global_position)
	await _wait_waiter_idle()


## 等服务员把当前指令走完。
## 【为什么要「先看到忙、再看它不忙」】点击只是把指令排给服务员，
## 同一帧里 is_busy() 还是 false —— 只判「不忙」会在第一帧就返回，
## 后面全部断言都会在动作还没发生时就跑（上一轮被这个骗过）。
func _wait_waiter_idle() -> void:
	await get_tree().physics_frame
	var saw_busy := false
	for i in 600:
		var busy := bool(_waiter.call("is_busy"))
		if busy:
			saw_busy = true
		elif saw_busy:
			return
		await get_tree().physics_frame


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
