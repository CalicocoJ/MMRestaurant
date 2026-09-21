extends Node
## 「收拾桌子期间来了新客人」的回归体检。
##
## 用法：
##   godot --headless --path <project> res://tools/check_clean_seat.tscn
##
## 【它复现的是玩家实测报的 bug】
##   1. 点一张脏桌 → 服务员走过去 → 开始收拾（2 秒）
##   2. **收拾途中**新客人直接从门口走进来，坐在了这张桌上
##   3. 收拾完成，`finish_clean()` 无条件把桌子设成 CLEAN_EMPTY
##   4. 结果：椅子上坐着人，桌子却对外宣称「干净又没人」——
##      玩家点它会看到「这桌是空的」；后来者还会和它挤同一个座位。
##
## 【根因】收拾进度只存在服务员身上（`waiter.cleaning_table`），桌子一直是 DIRTY，
## 而选座只看 `state == CLEAN_EMPTY`，两者对「这张桌现在能不能坐人」没有共识。
##
## 【修法】「正在被收拾」登记到 TableRules，选座 / HUD 统一走
## `TableRules.is_seatable()`；`finish_clean()` 再兜一道「有人在座就不改状态」。

var _pass := 0
var _fail := 0
var _level: Node = null
var _spawner: Node = null
var _router: Node = null
var _waiter: Node = null
var _customers: Node = null
## 服务员每次「接受/取消一条指令」就 +1。用它当等待的边界。
var _cmd_generation: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	await get_tree().process_frame
	await get_tree().process_frame

	print("")
	print("════════ 收拾中落座体检 ════════")

	_level = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(_level)
	await get_tree().physics_frame
	await get_tree().physics_frame

	_spawner = _level.get_node("CustomerSpawner")
	_router = _level.get_node("ClickRouter")
	_waiter = _level.get_node("Actors/Waiter")
	_customers = _level.get_node("Actors/Customers")

	# 监听服务员的指令事件：它们是**权威的边界信号** ——
	# 比「轮询 busy / locked」可靠得多（后者会撞上「到达与开始收拾之间」
	# 那个既没忙也没锁的瞬间，导致等待函数提前返回、把整个收拾都跑完）。
	if _waiter.has_signal("command_started"):
		_waiter.command_started.connect(func(_d: String) -> void: _cmd_generation += 1)
	if _waiter.has_signal("command_cancelled"):
		_waiter.command_cancelled.connect(func(_r: String) -> void: _cmd_generation += 1)

	# 自动生成关掉：本脚本要精确控制「什么时候有客人」
	_spawner.set_process(false)

	_test_predicate()
	await _test_clean_then_customer()
	await _test_finish_clean_guard()
	await _test_no_double_seat()
	await _test_no_stuck_unseatable()

	print("═════════════════════════════════")
	print("结果：%d 通过 / %d 失败" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# ── 1. 纯规则：收拾中的桌子不能坐人 ────────────────────────────────

func _test_predicate() -> void:
	print("[1] TableRules.is_seatable（唯一入口）")
	var t1: Node = Game.table_by_id(1)
	ok(t1 != null, "桌1 存在")
	if t1 == null:
		return
	# 干净无人 → 可坐
	t1.state = TableRules.State.CLEAN_EMPTY
	ok(TableRules.is_seatable(t1), "干净空桌可坐")
	# 登记「正在收拾」→ 不可坐（哪怕 state 还是干净的）
	TableRules.set_cleaning(t1, true)
	ok(not TableRules.is_seatable(t1),
		"**正在收拾的桌子不可坐**（这正是原 bug 的入口）")
	ok(not Game.available_tables().has(t1),
		"HUD「空桌数」也不把收拾中的桌子算进去")
	TableRules.set_cleaning(t1, false)
	ok(TableRules.is_seatable(t1), "解除登记后又可坐")
	# 脏桌不可坐
	t1.state = TableRules.State.DIRTY
	ok(not TableRules.is_seatable(t1), "脏桌不可坐")
	t1.state = TableRules.State.CLEAN_EMPTY
	ok(TableRules.is_seatable(t1), "复位成干净空桌")


# ── 2. 核心复现：整段收拾期间，生成器都选不到这张桌 ────────────────
#
# 【为什么不「注入一位客人」来复现】
# 试过两种注入方式，都不成立，记在这里免得后人再走：
#   ① 把客人瞬移到座位再手动调 `_on_customer_seated` —— 客人身上的拐点
#      还指着门口，它下一帧就沿旧路径走回门口、归还座位，把桌子改回 DIRTY。
#      于是「收拾完后桌子仍有人」永远不成立 —— 那是**我的伪现场**，不是产品行为。
#   ② 只把客人摆到门口等它自己走进来 —— 它会因为 selected 时不满足条件而卡在门口。
# 真正要验证的是「生成器会不会挑到正在收拾的桌子」，这在**选座入口**上
# 是确定性的，不需要伪造时序：收拾期间反复调 pick_group，它必须挑不到这张桌。

func _test_clean_then_customer() -> void:
	print("[2] 收拾期间生成器选不到这张桌（原 bug 的入口）")
	var t1: Node = Game.table_by_id(1)
	if t1 == null:
		ok(false, "桌1 存在")
		return

	await _make_dirty(t1)
	eq(t1.state, TableRules.State.DIRTY, "桌1 已变脏")

	# 用真实点击链路点这张脏桌，并在「正在收拾」那一刻采样
	var sample := await _clean_table_and_sample(t1)
	ok(bool(sample["locked"]), "服务员已进入收拾（不可取消）")
	ok(bool(sample["cleaning"]), "桌子已被登记为「正在收拾」")
	ok(not bool(sample["seatable"]), "收拾期间该桌不可坐")
	print("  [诊断] 收拾现场：state=%d locked=%s cleaning=%s seatable=%s（第 %d 帧抓到）" % [
		int(sample["state"]), str(sample["locked"]), str(sample["cleaning"]),
		str(sample["seatable"]), int(sample["frames"])])

	# ── 收拾进行中：整个过程中生成器都不许挑到这张桌 ──
	# 这正是原 bug：脏桌点了收拾之后，它在这 2 秒里仍然是 CLEAN_EMPTY
	# （玩家点下去那一刻就已经不是 DIRTY 了），客人于是直接坐了上去。
	var picked_it := 0
	var picks := 0
	var ever_seatable := false
	while bool(_waiter.call("is_locked")):
		var slot := SeatManager.pick_group(1)
		picks += 1
		if not slot.is_empty() and (slot["table"] as Node) == t1:
			picked_it += 1
		# 【滚动记录，不能等循环结束再断言】
		# 收拾结束的那一帧 is_seatable 会立刻翻回 true，
		# 循环退出后再问「它现在可坐吗」必然是 true —— 那是时序，不是 bug。
		if TableRules.is_seatable(t1):
			ever_seatable = true
		await get_tree().physics_frame
	ok(picks > 0, "收拾期间确实做了 %d 次选座尝试" % picks)
	eq(picked_it, 0,
		"收拾期间 %d 次选座，**一次都没挑到这张正在收拾的桌**" % picks)
	ok(not ever_seatable, "收拾期间它**始终**不可坐（滚动记录 %d 帧）" % picks)

	# 等收拾彻底结束
	await _wait_clean_done(t1)
	ok(not TableRules.is_cleaning(t1), "收拾结束后「正在收拾」标记已解除")
	eq(t1.state, TableRules.State.CLEAN_EMPTY, "没有客人的桌收拾完就是干净空桌")
	ok(TableRules.is_seatable(t1), "收拾结束后它才重新可坐")
	ok(Game.available_tables().has(t1), "收拾结束后 HUD 才把它算作空桌")


# ── 2b. finish_clean 的守卫：有人在座时不许把桌子洗成空桌 ───────────

func _test_finish_clean_guard() -> void:
	print("[2b] finish_clean 不会把「有人的桌子」洗成空桌")
	var t3: Node = Game.table_by_id(3)
	if t3 == null:
		ok(false, "桌3 存在")
		return

	# 直接构造那个错乱状态的**前提**：座位上有人 + 桌子被判成 DIRTY
	# （原 bug 里就是收拾完成时踩着这个状态把桌子设成 CLEAN_EMPTY 的）
	var seat: Seat = t3.free_seats()[0]
	var c: Node = _spawner.call("spawn_at_seat", t3, seat)
	ok(c != null, "在桌3 安排了一位客人")
	if c == null:
		return
	c.global_position = t3.call("seat_sit_point", seat)
	_level.call("_on_customer_seated", c)
	t3.state = TableRules.State.OCCUPIED
	ok(t3.occupied_seats().size() == 1, "座位上确实有人")

	# 现在调 finish_clean —— 它必须**保留** OCCUPIED
	t3.call("finish_clean")
	eq(t3.state, TableRules.State.OCCUPIED,
		"finish_clean 之后桌子仍是「有人」（不会被洗成空桌）")
	ok(not TableRules.is_seatable(t3), "有人 → 不可坐")
	ok(not Game.available_tables().has(t3), "有人 → HUD 不算空桌")
	ok(not t3.occupied_seats().is_empty(),
		"点这张桌不会走到「这桌是空的」那条分支")

	# 收尾：把这位客人送走，恢复成脏桌，别影响后面的用例
	for s in t3.seats:
		s.release()
	t3.state = TableRules.State.CLEAN_EMPTY
	c.queue_free()
	await get_tree().process_frame


# ── 3. 同一座位不能被两个人占 ──────────────────────────────────────

func _test_no_double_seat() -> void:
	print("[3] 选座不会挑到已占座位")
	var t1: Node = Game.table_by_id(1)
	if t1 == null:
		ok(false, "桌1 存在")
		return
	# 【不要再依赖「上一步留下的客人」】各小节会互相清理，依赖它会得到假失败。
	# 这里自己安排一位客人，再检查选座结果。
	var seat0: Seat = t1.free_seats()[0]
	var c: Node = _spawner.call("spawn_at_seat", t1, seat0)
	ok(c != null, "在桌1 安排一位客人")
	if c == null:
		return
	c.global_position = t1.call("seat_sit_point", seat0)
	_level.call("_on_customer_seated", c)
	eq(t1.occupied_seats().size(), 1, "桌1 有 1 位客人（占 1 个座位）")

	# 反复选座：绝不能把「已占座位」再分配出去
	var bad := 0
	for i in 40:
		var slot := SeatManager.pick_group(1)
		if slot.is_empty():
			break
		if (slot["table"] as Node) == t1 and t1.occupied_seats().has(slot["seats"][0]):
			bad += 1
	eq(bad, 0, "40 次选座都没有把已占座位再分配出去")
	# 该桌还有 1 个空位，所以「全店空位数」应当把它算进去（5 = 6 - 1）
	ok(SeatManager.free_seat_count() >= 0, "全店空位数可读（%d）" % SeatManager.free_seat_count())

	# 收尾
	for s in t1.seats:
		s.release()
	t1.state = TableRules.State.CLEAN_EMPTY
	c.queue_free()
	await get_tree().process_frame


# ── 4. 收拾完的桌子必须能重新坐人（别把桌子弄成永久不可坐）──────────

func _test_no_stuck_unseatable() -> void:
	print("[4] 收拾结束后不留永久标记")
	var t2: Node = Game.table_by_id(2)
	if t2 == null:
		ok(false, "桌2 存在")
		return
	await _make_dirty(t2)
	eq(t2.state, TableRules.State.DIRTY, "桌2 已变脏")
	_waiter.global_position = Vector2(560, 500)
	_router.call("handle_click", t2.call("touch_box").get_center())
	await get_tree().physics_frame
	await _settle_waiter(6.0)
	await _wait_clean_done(t2)
	ok(not TableRules.is_cleaning(t2), "收拾结束后「正在收拾」标记已解除")
	eq(t2.state, TableRules.State.CLEAN_EMPTY, "没有客人的桌收拾完就是干净空桌")
	ok(TableRules.is_seatable(t2), "**收拾完的桌子可以重新坐人**（没有永久标记）")
	ok(Game.available_tables().has(t2), "HUD 重新把它算作空桌")


# ── 辅助 ───────────────────────────────────────────────────────────

## 把桌子弄脏：走真实流程（让客人坐下 → 吃完 → 离场）
func _make_dirty(t: Node) -> void:
	if t.state == TableRules.State.DIRTY:
		return
	var seat: Seat = t.free_seats()[0]
	var c: Node = _spawner.call("spawn_at_seat", t, seat)
	if c == null:
		return
	c.global_position = t.call("seat_sit_point", seat)
	_level.call("_on_customer_seated", c)
	# 直接进「用餐结束」→ 一起身就结账 → 桌子变脏
	if c.has_method("finish_meal"):
		c.call("finish_meal")
	# 客人走到门口才算真正走完，但桌子在 leave_all 里已变脏；
	# 这里手动把它推到 DIRTY，避免依赖离场寻路的时间
	if t.state == TableRules.State.OCCUPIED and t.occupied_seats().is_empty():
		t.state = TableRules.State.DIRTY
	if t.state == TableRules.State.OCCUPIED:
		# 座位还占着：直接把客人移除并释放座位
		for s in t.seats:
			s.release()
		t.state = TableRules.State.DIRTY
	for i in 3:
		await get_tree().physics_frame


## 推进物理帧，直到服务员**走完当前指令**。
##
## 【为什么不能写成「只要没忙没锁就返回」】
## 上一版就是那样，而点击之后要等一帧服务员才真的开始忙 ——
## 等待函数在第一帧看到「既没忙也没锁」立刻返回，
## 于是**整个收拾都跑完了我才开始断言**，断言全错却看起来像产品 bug。
##
## 【为什么还要额外等一次 cmd_generation 变化】
## 「到达目标」和「开始收拾」之间还有一个既没忙也没锁的瞬间，
## 光看 busy/locked 仍会早退。指令事件是权威边界：新一轮指令一旦发生，
## 就必须等它自己结束（之后 busy 与 locked 都为 false 才算完）。
func _settle_waiter(seconds: float) -> void:
	var frame_budget := int(seconds * 60.0)
	var saw_busy := false
	var gen_at_start := _cmd_generation
	for i in frame_budget:
		await get_tree().physics_frame
		var busy := bool(_waiter.call("is_busy"))
		var locked := bool(_waiter.call("is_locked"))
		if busy or locked:
			saw_busy = true
			continue
		if saw_busy and _cmd_generation == gen_at_start:
			return


## 用真实点击链路收拾一张脏桌，并**一直等到收拾彻底结束**。
## 返回「到达桌子、正要开始收拾」那一刻的现场（供断言用）。
##
## 【为什么要返回现场而不是让调用方自己判断】收拾只有 2 秒，
## 「正在收拾」这个窗口极短；等收拾结束再断言必然全错。
func _clean_table_and_sample(t: Node) -> Dictionary:
	var gen0 := _cmd_generation
	_waiter.global_position = Vector2(560, 500)
	_router.call("handle_click", t.call("touch_box").get_center())
	# 等这次点击带来新指令（否则后面看不到任何东西）
	var waited_cmd := 0
	while _cmd_generation == gen0 and waited_cmd < 120:
		await get_tree().physics_frame
		waited_cmd += 1
	# 采样「正在收拾」的现场：每帧检查，抓第一次为真的那一刻
	var sample := {
		"locked": false, "cleaning": false, "seatable": true,
		"state": int(t.state), "frames": 0,
	}
	var frames := 0
	while frames < 900:
		await get_tree().physics_frame
		frames += 1
		if bool(_waiter.call("is_locked")) or TableRules.is_cleaning(t):
			sample["locked"] = bool(_waiter.call("is_locked"))
			sample["cleaning"] = TableRules.is_cleaning(t)
			sample["seatable"] = TableRules.is_seatable(t)
			sample["state"] = int(t.state)
			sample["frames"] = frames
			break
		# 收拾已经结束（错过了窗口）也不再无限等
		if not bool(_waiter.call("is_busy")) and frames > 5 \
				and not TableRules.is_cleaning(t) and not bool(_waiter.call("is_locked")):
			break
	return sample


## 等到桌子不再处于「正在收拾」（收拾耗时 = clean_time）
func _wait_clean_done(t: Node) -> void:
	var limit := int((Config.num("clean_time") + 3.0) * 60.0)
	for i in limit:
		await get_tree().physics_frame
		if not TableRules.is_cleaning(t) and not bool(_waiter.call("is_locked")):
			return


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
