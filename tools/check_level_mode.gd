extends Node
## 关卡模式体检：一局一局、倒计时、结算、下一关 / 重试。
##
## 用法：
##   godot --headless --path <project> res://tools/check_level_mode.tscn
##
## 【它验证什么】
##   1. data/levels.json 载入正确（5 关、每关时长/目标与文件一致）
##   2. 开局要把「本局状态」初始化全（少一个 run_active 就会「倒计时永远不动」）
##   3. 倒计时会走；**弹窗期间照走**（已与用户确认，和「世界暂停」是两回事）
##   4. 时间到 → 结算界面出现，且世界被冻住
##   5. 达标：标题「通关成功」、按钮「下一关」；按下 → 进下一关且**上一局状态不残留**
##   6. 未达标：标题「通关失败」、按钮「重试本关」；按下 → 重开本关、营收归零
##   7. 最后一关达标：按钮变成「重玩第 1 关」，按下回第 1 关

var _pass := 0
var _fail := 0
var _level: Node = null
var _spawner: Node = null
var _waiter: Node = null
var _customers: Node = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	await get_tree().process_frame
	await get_tree().process_frame

	print("")
	print("════════ 关卡模式体检 ════════")

	_level = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(_level)
	await get_tree().physics_frame
	await get_tree().physics_frame

	_spawner = _level.get_node("CustomerSpawner")
	_waiter = _level.get_node("Actors/Waiter")
	_customers = _level.get_node("Actors/Customers")
	_spawner.set_process(false)

	_test_levels_config()
	_test_start_level_state()
	_test_star_rules()
	await _test_countdown_runs()
	await _test_popup_does_not_freeze_clock()
	# 【先跑「达标」再跑「时间到/未达标」】达标那条要验证「有几颗星」，
	# 而未达标那条要验证「星星整行隐藏」—— 后者必须晚于前者，
	# 才能真正证明隐藏是这次填进去的结果，而不是恰好没设过。
	await _test_pass_advances_level()
	await _test_fail_retries_level()
	await _test_time_up_shows_result()
	await _test_last_level_wraps_to_first()
	await _test_counter_visual_stays_bound()

	print("═════════════════════════════")
	print("结果：%d 通过 / %d 失败" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# ── 1. 关卡表 ──────────────────────────────────────────────────────

func _test_levels_config() -> void:
	print("[1] data/levels.json")
	eq(Config.level_count(), 5, "共 5 关")
	var expect := [
		[1, 90.0, 60], [2, 120.0, 80], [3, 120.0, 90],
		[4, 130.0, 100], [5, 150.0, 120],
	]
	for e in expect:
		var lv := Config.level_at(int(e[0]))
		eq(int(lv.get("id", 0)), int(e[0]), "第 %d 关 id 正确" % int(e[0]))
		eq(float(lv.get("time_limit", 0.0)), float(e[1]),
			"第 %d 关时长 = %d 秒" % [int(e[0]), int(e[1])])
		eq(int(lv.get("target_money", 0)), int(e[2]),
			"第 %d 关目标 = %d 元" % [int(e[0]), int(e[2])])
	ok(String(Config.level_at(1).get("name", "")) != "",
		"关卡有名字（%s）" % Config.level_at(1).get("name", ""))
	eq(int(Config.level_at(99).get("id", 0)), 5, "越界的关卡号会夹到最后一关")
	eq(int(Config.level_at(0).get("id", 0)), 1, "小于 1 的关卡号会夹到第 1 关")


# ── 2. 开局的初始化 ────────────────────────────────────────────────

func _test_start_level_state() -> void:
	print("[2] 开一局要把本局状态初始化全")
	Game.start_level(2)
	# 【不要把目标/时长写死】它们是玩家反复调过的数值（140 → 105 → 70、90 → 120 …），
	# 写死会让每次调数值都变成"测试假失败"。一律以 levels.json 为准。
	var lv2 := Config.level_at(2)
	var limit2 := float(lv2.get("time_limit", 0.0))
	var target2 := int(lv2.get("target_money", 0))
	eq(Game.level_index, 2, "当前是第 2 关")
	eq(Game.money, 0, "开局营收 = 0（每关独立计算）")
	eq(Game.time_left, limit2, "倒计时装满（= 本关时长 %d 秒）" % int(limit2))
	ok(Game.is_run_active(), "标记为「本局进行中」")
	eq(Game.target_money(), target2, "本关目标 = %d 元" % target2)
	ok(not Game.passed(), "0 元当然没达标")

	# enable_run_clock 用于真实游戏：玩家按下「开始游戏」时放行倒计时
	Game.start_level(2, false)
	ok(not Game.is_run_active(), "clock_on=false 时本局不进行（标题画面/工具用）")
	eq(Game.time_left, limit2, "但倒计时初值仍是本关时长（界面不显示 0:00）")
	Game.enable_run_clock()
	ok(Game.is_run_active(), "enable_run_clock() 之后开始计时")


# ── 2b. 星级判定（0~3 星，边界逐个验）────────────────────────────────
#
# 【为什么要逐个点验边界】星级是**按金额比门槛**判的，最容易错的就是
# 「等于门槛算不算达标」和「刚好差 1 元算几星」。
# 所以每个档位都测三个点：门槛 -1（不该给）、门槛（该给）、门槛 +1（该给）。

func _test_star_rules() -> void:
	print("[2b] 星级判定（1 星 = 过关线）")
	var saved := Game.level_index
	for lv in [1, 2, 3, 4, 5]:
		var lv1 := Config.star_money(lv, 1)
		var lv2 := Config.star_money(lv, 2)
		var lv3 := Config.star_money(lv, 3)
		# 数据必须严格递增（1 < 2 < 3），否则判定毫无意义
		ok(lv1 < lv2 and lv2 < lv3,
			"第 %d 关门槛严格递增：%d < %d < %d" % [lv, lv1, lv2, lv3])

		Game.set_level_index(lv)
		# ── 1 星边界 ──
		Game.money = maxi(0, lv1 - 1)
		eq(Game.stars(), 0, "第 %d 关：%d 元（差 1 元）→ 0 星" % [lv, Game.money])
		ok(not Game.passed(), "第 %d 关：差 1 元 → 未过关" % lv)
		Game.money = lv1
		eq(Game.stars(), 1, "第 %d 关：%d 元（正好 1 星门槛）→ **1 星**" % [lv, lv1])
		ok(Game.passed(), "第 %d 关：1 星门槛 = 过关线 → 过关" % lv)
		# ── 2 星边界 ──
		Game.money = lv2 - 1
		eq(Game.stars(), 1, "第 %d 关：%d 元（2 星门槛差 1）→ 仍是 1 星" % [lv, lv2 - 1])
		Game.money = lv2
		eq(Game.stars(), 2, "第 %d 关：%d 元（正好 2 星门槛）→ **2 星**" % [lv, lv2])
		# ── 3 星边界 ──
		Game.money = lv3 - 1
		eq(Game.stars(), 2, "第 %d 关：%d 元（3 星门槛差 1）→ 仍是 2 星" % [lv, lv3 - 1])
		Game.money = lv3
		eq(Game.stars(), 3, "第 %d 关：%d 元（正好 3 星门槛）→ **3 星**" % [lv, lv3])
		Game.money = lv3 + 500
		eq(Game.stars(), 3, "第 %d 关：远超门槛 → 仍是 3 星（不会超过 3）" % lv)

	# 「passed() 等价于 stars() >= 1」这条不变式
	var mismatch := 0
	for lv in [1, 2, 3, 4, 5]:
		for m in [0, 10, 50, 60, 70, 75, 90, 105, 120, 125, 150, 175, 200, 999]:
			Game.set_level_index(lv)
			Game.money = m
			if Game.passed() != (Game.stars() >= 1):
				mismatch += 1
	eq(mismatch, 0, "passed() 与 stars()>=1 在 5 关 × 14 个金额上完全一致")

	# HUD 快照要带上星级门槛（HUD 那一行读它）
	Game.set_level_index(3)
	Game.money = 0
	var snap := Game.hud_snapshot(0)
	eq(int(snap.get("star1", -1)), Config.star_money(3, 1), "快照含 1 星门槛")
	eq(int(snap.get("star2", -1)), Config.star_money(3, 2), "快照含 2 星门槛")
	eq(int(snap.get("star3", -1)), Config.star_money(3, 3), "快照含 3 星门槛")
	eq(int(snap.get("stars", -1)), 0, "快照含当前星数（0）")

	Game.set_level_index(saved)
	Game.money = 0


# ── 3. 倒计时会走 ──────────────────────────────────────────────────

func _test_countdown_runs() -> void:
	print("[3] 倒计时会走")
	Game.start_level(1)
	# 【不要把秒数写死】第 1 关的时长是玩家调过的（90 → 120），
	# 断言写死就会在每次调数值后假失败。这里以「本关时长」为基准。
	var limit := Game.level_time_limit()
	eq(Game.time_left, limit, "开局装满（本关 %d 秒）" % int(limit))
	Game.tick(1.5)
	ok(absf(Game.time_left - (limit - 1.5)) < 0.001,
		"走 1.5 秒后剩 %.1f（实际 %.2f）" % [limit - 1.5, Game.time_left])
	# 真的按帧跑一段：UIManager 每帧推进
	var before := Game.time_left
	for i in 30:
		await get_tree().process_frame
	ok(Game.time_left < before,
		"按帧推进也在减少（%.2f → %.2f）" % [before, Game.time_left])
	ok(Game.tick(1000.0), "时间归零时 tick() 返回 true（= 刚刚结束）")
	eq(Game.time_left, 0.0, "剩余时间夹到 0，不会变成负数")
	ok(not Game.is_run_active(), "结束后不再是「进行中」")
	ok(not Game.tick(1.0), "再 tick 不会重复结算（只结束一次）")


# ── 4. 弹窗期间倒计时照走（已与用户确认）────────────────────────────

func _test_popup_does_not_freeze_clock() -> void:
	print("[4] 打开后厨弹窗时倒计时**照走**")
	await _reset_to_idle()
	Game.start_level(1)
	var before := Game.time_left
	UI.open_kitchen()
	ok(get_tree().paused, "后厨弹窗把世界冻住了（这是既有规则）")
	ok(UI.is_any_popup_open(), "弹窗确实开着")
	# 等几帧：世界停着（Level._process 不跑），但倒计时必须继续扣
	# —— 因为它由 PROCESS_MODE_ALWAYS 的 UIManager 推进。
	for i in 20:
		await get_tree().process_frame
	UI.close_popups()
	ok(Game.time_left < before,
		"**弹窗期间倒计时仍然在走**（%.2f → %.2f）——不能顺手改成暂停"
			% [before, Game.time_left])
	ok(not get_tree().paused, "关掉弹窗后世界恢复")


# ── 5. 时间到 → 结算 ───────────────────────────────────────────────

func _test_time_up_shows_result() -> void:
	print("[5] 时间到 → 结算界面")
	await _reset_to_idle()
	Game.start_level(1)
	# 【按目标取"差一点"的钱，不要写死数字】曾写死 50，而 L1 目标正好也是 50 →
	# 变成达标了，两条断言假失败。数值是可调的，断言必须相对目标来写。
	var tgt1 := Game.target_money()
	Game.add_money(maxi(1, tgt1 - 1))   # 差 1 元 → 未达标
	ok(not Game.passed(), "差 1 元 → 未达标（%d / %d）" % [Game.money, tgt1])
	ok(not UI.is_result_open(), "结算前界面是收起的")
	Game.tick(1000.0)                  # 时间到（会发 level_finished）
	await get_tree().process_frame     # UIManager 收到信号后弹结算
	await get_tree().process_frame
	ok(UI.is_result_open(), "时间到后结算界面出现")
	ok(get_tree().paused, "结算时世界被冻住")
	ok(UI.hud != null and not UI.hud.visible, "结算时 HUD 收起（不干扰阅读）")
	var title := _result_node("ResultTitle") as Label
	ok(title != null and title.text == "通关失败",
		"未达标 → 标题「通关失败」（实际「%s」）" % (title.text if title else "<无>"))
	# 【0 星时星星整行隐藏】已与玩家确认：失败就只显示标题，不画 3 颗空心星。
	# 这一条必须在本文件里**晚于**「达标」那条用例执行才有意义 ——
	# 否则"星星不可见"可能只是因为它从没被设过（见 _ready 里的执行顺序说明）。
	var stars_box := _result_node("Stars") as Control
	ok(stars_box != null and not stars_box.visible,
		"未达标（0 星）→ **星星那一行整行隐藏**")
	var btn: Button = UI.result_panel().call("action_button")
	ok(btn != null and btn.text == "重试本关",
		"未达标 → 按钮「重试本关」（实际「%s」）" % (btn.text if btn else ""))


# ── 6. 达标 → 下一关，且不残留上一局 ───────────────────────────────

func _test_pass_advances_level() -> void:
	print("[6] 达标 →「下一关」，且上一局状态不残留")
	await _reset_to_idle()
	Game.start_level(2)                 # 目标以 levels.json 为准（当前 60）
	# 造一点「上一局残留」：一位客人、手上的菜、一张脏桌（带收拾登记）
	var t1: Node = Game.table_by_id(1)
	var seat: Seat = t1.free_seats()[0]
	var c: Node = _spawner.call("spawn_at_seat", t1, seat)
	c.call("set_pending_items", [Constants.BURGER] as Array[String])
	c.global_position = t1.call("seat_sit_point", seat)
	_level.call("_on_customer_seated", c)
	Game.hand_take(Constants.BURGER)
	Game.served_count = 7                     # 夹具：摆一个本局战绩
	# 夹具：让服务员**身上挂着**一份餐（视觉源）。
	# 【为什么必须显式造这个夹具】玩家实测报的 bug 就是"换关后小人手上图标不消失"，
	# 而它的根因在 `waiter.carried`（画方块用它）而不是 `Game.hand`（数据）。
	# 不造这个夹具，那条断言就是空的 —— 之前正因为没造，158 项全过却漏了这个 bug。
	_waiter.call("set_carried_list", [Constants.BURGER] as Array[String])
	ok(_waiter.get("carried").size() > 0, "夹具：服务员身上挂着一份餐（待会要被清掉）")
	# 夹具：一张还带「正在收拾」登记的脏桌（视觉源同样是 state + _refresh_look）
	Game.table_by_id(3).state = TableRules.State.DIRTY
	TableRules.set_cleaning(Game.table_by_id(3), true)
	ok(_customers.get_child_count() > 0, "本局确实有客人（待会要被清掉）")
	ok(Game.hand_items().size() > 0, "手上确实有菜（待会要被清掉）")
	ok(Game.served_count > 0, "本局有接待记录（待会要归零）")

	# 【目标从关卡表读，别写死】它是玩家反复调过的数值。
	# 这里只"刚过 1 星线"，好让下面的星级断言有意义（亮 1 颗）。
	var tgt2 := Game.target_money()
	Game.add_money(tgt2 + 1)
	ok(Game.passed(), "营收 %d ≥ 1 星门槛 %d → 达标" % [Game.money, tgt2])
	eq(Game.stars(), 1, "刚过 1 星线 → **1 星**（好验证星星只亮 1 颗）")
	Game.tick(1000.0)
	await get_tree().process_frame
	await get_tree().process_frame

	var title := _result_node("ResultTitle") as Label
	var revenue := _result_node("ResultRevenue") as Label
	var served := _result_node("ResultServed") as Label
	var btn: Button = UI.result_panel().call("action_button")
	# ── 星星（在「通关成功」下面，已与玩家确认）──
	var stars_box := _result_node("Stars") as Control
	ok(stars_box != null and stars_box.visible, "达标 → 星星那一行可见")
	if stars_box != null:
		var icons := stars_box.get_children()
		eq(icons.size(), 3, "一共画 3 颗星")
		var lit := 0
		for ic in icons:
			if bool(ic.get("lit")):
				lit += 1
		eq(lit, 1, "**只亮 1 颗**（黄星在前，其余 2 颗是白星）")
		ok(bool(icons[0].get("lit")), "第 1 颗是亮的（黄）")
		ok(not bool(icons[1].get("lit")), "第 2 颗是暗的（白）")
		ok(not bool(icons[2].get("lit")), "第 3 颗是暗的（白）")
	ok(title != null and title.text == "通关成功",
		"达标 → 标题「通关成功」（实际「%s」）" % (title.text if title else "<无>"))
	ok(revenue != null and revenue.text.contains(str(Game.money))
			and revenue.text.contains(str(tgt2)),
		"营业额一行同时给出本局营收与目标（「%s」）" % (revenue.text if revenue else "<无>"))
	ok(served != null and served.text.contains("7"),
		"显示接待客人总数（「%s」）" % (served.text if served else "<无>"))
	ok(btn != null and btn.text == "下一关",
		"达标 → 按钮「下一关」（实际「%s」）" % (btn.text if btn else ""))

	UI.press_result_action()            # 走完整按钮链路
	await get_tree().physics_frame
	await get_tree().process_frame

	eq(Game.level_index, 3, "进度推进到第 3 关")
	ok(not UI.is_result_open(), "结算界面收起")
	ok(UI.hud != null and UI.hud.visible, "HUD 恢复显示")
	ok(not get_tree().paused, "世界恢复推进")
	eq(Game.money, 0, "**新一局营收归零**（不把上一关的钱算进来）")
	eq(Game.served_count, 0, "接待人数归零")
	eq(Game.hand_items().size(), 0, "手上清空")
	ok(Game.is_run_active(), "新一局进行中（倒计时会走）")
	# 【时长从关卡表读，绝不写死】这一关的时长被玩家调过（120 → 150），
	# 写死就会在每次调数值后假失败 —— 本文件已经因此踩过两次。
	var l3 := Game.level_time_limit()
	ok(Game.time_left > l3 - 1.0 and Game.time_left <= l3,
		"倒计时装满第 3 关的 %d 秒（实际 %.2f，已跑掉一帧）" % [int(l3), Game.time_left])
	# ── 残留检查 ──
	#
	# 【为什么必须检查"视觉源"而不只是数据】
	# 玩家实测报过：「进第 4 关时小人手上还拿着上一关的餐品，图标不消失」。
	# 根因是换关时只清了 `Game.hand`（数据），
	# 而服务员肩上两个方块画的是**他自己的 `carried` 数组**（由 router 同步）。
	# 只断言 `Game.hand_items()` 是**抓不到**这个 bug 的 —— 它本来就是空的。
	# 所以这里两种都要查：数据源（Game.hand）+ 视觉源（waiter.carried）。
	await get_tree().process_frame               # 让 queue_free 生效
	eq(_customers.get_child_count(), 0, "上一局的客人已清空")
	eq(Game.active_orders().size(), 0, "上一局的订单票已清空")
	eq(_waiter.get("carried").size(), 0,
		"**服务员身上没有残留的餐品标记**（视觉源，玩家报过这个 bug）")
	for t in Game.tables:
		eq(t.state, TableRules.State.CLEAN_EMPTY, "%s 回到干净空桌" % t.label)
		ok(t.occupied_seats().is_empty(), "%s 座位上没人" % t.label)
		ok(not TableRules.is_cleaning(t), "%s 没有残留「正在收拾」登记" % t.label)
	ok(not bool(_waiter.call("is_locked")), "服务员没有还锁着")


# ── 7. 未达标 → 重试本关 ───────────────────────────────────────────

func _test_fail_retries_level() -> void:
	print("[7] 未达标 →「重试本关」")
	await _reset_to_idle()
	Game.start_level(4)                 # 目标以 levels.json 为准（当前 70）
	Game.add_money(10)                  # 差得远
	Game.tick(1000.0)
	await get_tree().process_frame
	await get_tree().process_frame
	var btn: Button = UI.result_panel().call("action_button")
	ok(btn != null and btn.text == "重试本关",
		"未达标 → 按钮「重试本关」（实际「%s」）" % (btn.text if btn else ""))
	UI.press_result_action()
	await get_tree().physics_frame
	await get_tree().process_frame
	eq(Game.level_index, 4, "**仍停在第 4 关**（重试本关，不推进也不后退）")
	eq(Game.money, 0, "营收归零")
	var l4 := Game.level_time_limit()
	ok(Game.time_left > l4 - 1.0 and Game.time_left <= l4,
		"倒计时重新装满第 4 关的 %d 秒（实际 %.2f）" % [int(l4), Game.time_left])
	ok(Game.is_run_active(), "新一局进行中")


# ── 8. 最后一关 → 重玩第 1 关 ──────────────────────────────────────

func _test_last_level_wraps_to_first() -> void:
	print("[8] 最后一关达标 →「重玩第 1 关」")
	await _reset_to_idle()
	Game.start_level(Config.level_count())     # 第 5 关，目标以 levels.json 为准（当前 80）
	Game.add_money(9999)
	ok(Game.passed(), "远超目标 → 达标")
	ok(not Game.has_next_level(), "第 5 关后面没有关卡了")
	Game.tick(1000.0)
	await get_tree().process_frame
	await get_tree().process_frame
	var btn: Button = UI.result_panel().call("action_button")
	ok(btn != null and btn.text == "重玩第 1 关",
		"没有下一关 → 按钮改成「重玩第 1 关」（实际「%s」）" % (btn.text if btn else ""))
	UI.press_result_action()
	await get_tree().physics_frame
	await get_tree().process_frame
	eq(Game.level_index, 1, "回到第 1 关")
	eq(Game.money, 0, "营收归零")
	var l1 := Game.level_time_limit()
	ok(Game.time_left > l1 - 1.0 and Game.time_left <= l1,
		"第 1 关的 %d 秒（实际 %.2f）" % [int(l1), Game.time_left])
	ok(Game.is_run_active(), "新一局进行中")


# ── 9. 出餐口的视觉订阅不能因为「换了一局」而失效 ───────────────────
#
# 【复现的是玩家实测报的 bug】取走出餐口的餐后，**图标延迟 1~2 秒才消失**
# （要动一下鼠标才更新）。根因：开一局会 `Game.reset_progress()` 重建
# Kitchen 对象，而出餐口订阅的是**旧对象**的 `counter_changed` ——
# 新对象发信号没人听，于是不重绘；一动鼠标、悬停状态变化才触发重绘。
#
# 【为什么这条断言能抓到它】直接检查「当前这个 Kitchen 的 counter_changed
# 上挂着出餐口的回调」。换一局之后若没重绑，连接数就是 0。
func _test_counter_visual_stays_bound() -> void:
	print("[9] 换一局后出餐口的视觉订阅仍然有效")
	await _reset_to_idle()
	Game.start_level(1)
	await get_tree().process_frame

	var counter: Node = _level.get_node_or_null("World/KitchenWindow")
	ok(counter != null, "出餐口节点存在")
	if counter == null:
		return
	var cb := Callable(counter, "_on_counter_changed")
	ok(Game.kitchen.counter_changed.is_connected(cb),
		"出餐口已订阅**当前** Kitchen 的 counter_changed（新一局之后仍然有效）")

	# 走真实链路：下一道菜 → 时间推进到出餐 → 取走 → 连接必须还在
	Game.kitchen.enqueue([Constants.BURGER] as Array[String])
	Game.kitchen.fast_forward(3.5)
	eq(Game.kitchen.counter_slot(), Constants.BURGER, "汉堡到了出餐口")
	ok(Game.kitchen.counter_changed.is_connected(cb), "出餐后订阅仍在")
	Game.kitchen.take_from_counter()
	ok(Game.kitchen.counter_is_empty(), "餐已取走")
	ok(Game.kitchen.counter_changed.is_connected(cb),
		"**取走后订阅仍在**（否则图标不会立刻消失，要动鼠标才更新）")

	# 再开一局（换 Kitchen），订阅必须跟着重新挂上
	UI.request_run_at(2)
	await get_tree().physics_frame
	await get_tree().process_frame
	eq(Game.level_index, 2, "已切到第 2 关")
	ok(Game.kitchen.counter_changed.is_connected(cb),
		"**换一局（Kitchen 被重建）之后重新绑上了**——这是那个 bug 的核心")


# ── 工具 ───────────────────────────────────────────────────────────
#
## 把世界恢复成「准备开一局」的干净状态。
##
## 【为什么每个用例开头都要调它】结算界面会 `paused = true` 并把 HUD 藏起来。
## 不清掉这个状态就直接开始下一段测试，世界仍然是暂停的 ——
## 于是 UIManager 的 _process 不跑、倒计时不动、时间永远到不了，
## 后面所有断言连锁失败。本轮被这个骗过一次：
## 16 条失败里有一半其实是这一个原因造成的假失败。
func _reset_to_idle() -> void:
	UI.hide_result()
	_clear_customers()
	for t in Game.tables:
		for s in t.seats:
			s.release()
		t.order = null
		t.state = TableRules.State.CLEAN_EMPTY
		t.call("mark_available")
	TableRules.set_cleaning(null, false)
	Game.clear_hand()
	await get_tree().process_frame
	await get_tree().physics_frame


## 按**唯一节点名**找结算界面里的控件。
## 【为什么不写 "Center/Column/ResultTitle" 这种路径】路径一改，
## get_node_or_null 会安静地返回 null，断言于是「看起来失败」而不是报错；
## find_child 按名字递归找，改布局不会影响断言。
func _result_node(nm: String) -> Node:
	var p: Control = UI.result_panel()
	if p == null:
		return null
	return p.find_child(nm, true, false)


func _clear_customers() -> void:
	if _customers == null:
		return
	for c in _customers.get_children():
		c.queue_free()


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
