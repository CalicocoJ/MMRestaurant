extends Node
## 离屏截图 + 状态快照。
##
## 用法：
##   godot --path <project> --resolution 1280x720 res://tools/screenshot.tscn -- <输出路径> [模拟秒数]
##
## 【为什么要离屏渲染而不是直接开窗截图】
## 开窗截图需要人（或另一个进程）去抓屏，还要有人真的在看。
## 渲染到 SubViewport 再 get_texture().get_image().save_png() 完全在
## 引擎内部完成，可以在无人值守的情况下产出可检查的图片。
##
## 【为什么要把 autoload 的 UI / Stickers 搬进 SubViewport】
## 它们是 CanvasLayer 类型的 autoload，挂在**主窗口**的 viewport 上。
## 如果只把场景塞进 SubViewport，截图里就只有世界，没有 HUD ——
## 我第一次跑就是这么被骗过去的：图看着正常，其实 UI 全丢了。
## 所以这里显式把这两个 autoload 重新挂到离屏视口下。
##
## 【它能验证什么、不能验证什么】
##   能：中文字体是否真的渲染成汉字（不是方块）、各家具位置、
##       HUD / 订单栏 / 飘字有没有画出来、图层顺序对不对。
##   不能：鼠标交互与物理移动 —— 那些靠 tools/run_tests.gd 断言。

const OUT_DEFAULT := "res://.artifacts/screenshot.png"
const W := 1280
const H := 720


func _ready() -> void:
	await get_tree().process_frame

	var argv := OS.get_cmdline_user_args()
	var out_path := OUT_DEFAULT
	var seconds := 9.0
	if argv.size() > 0:
		out_path = String(argv[0])
	if argv.size() > 1:
		seconds = float(argv[1])

	# 1) 离屏视口
	var vp := SubViewport.new()
	vp.size = Vector2i(W, H)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.transparent_bg = false
	add_child(vp)

	# 2) 把 CanvasLayer 类型的 autoload 搬进离屏视口（否则 HUD 不会被画进来）
	for autoload_name in ["Stickers", "UI"]:
		var layer := get_tree().root.get_node_or_null(NodePath(autoload_name))
		if layer != null:
			get_tree().root.remove_child(layer)
			vp.add_child(layer)
		else:
			push_warning("找不到 autoload：" + autoload_name)

	# 3) 场景装进视口
	var level: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	vp.add_child(level)

	# 4) 手动推进游戏时间，让画面有内容（客人、订单栏、飘字）
	await _simulate(level, seconds)

	# 5) 可选场景：拿一份餐在手上 / 打开某个弹窗，用来检查这些 UI
	if argv.size() > 2:
		await _setup_pose(level, String(argv[2]))

	# 6) 打印状态，方便不看图也能判断
	_report(level)

	# 7) 渲染并落盘
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_path.get_base_dir()))
	var err := img.save_png(out_path)
	if err != OK:
		push_error("保存失败 %s: %d" % [out_path, err])
		get_tree().quit(1)
		return
	print("[screenshot] 已保存 %s (%dx%d)" % [out_path, img.get_width(), img.get_height()])
	get_tree().quit(0)


## pose 取值：
##   hand:burger / hand:fries / hand:cola  服务员手上端着某道餐
##   kitchen                               打开后厨 UI
##   drink                                 打开饮料机 UI
##   dirty                                 让客人全部结账走人，露出脏桌
##   order                                 模拟点击一位客人，走完「接单」全过程
##   touch:right|left|above|below          把服务员放在桌2指定一侧，点它，看他在哪停
##   pass / fail                           关卡模式：走**真实开始按钮**之后把时间推到 0，
##                                         看结算界面（pass = 达标、fail = 未达标）
func _setup_pose(level: Node, pose: String) -> void:
	var waiter: Node = level.get_node("Actors/Waiter")
	if pose.begins_with("hand:"):
		var item := pose.substr(5)
		# 支持 "hand:burger+cola" 这种「手上两份」的写法（容量 2）
		Game.clear_hand()
		for p: String in item.split("+"):
			Game.hand_take(p)
		waiter.call("set_carried_list", Game.hand_items())
	elif pose == "kitchen":
		UI.open_kitchen()
	elif pose == "kitchen2":
		# 后厨点单弹窗 + 队列里放几份（用来看「队列小方块 + 菜名/价格」的样子）
		UI.open_kitchen()
		await get_tree().physics_frame
		var kp: Control = UI.kitchen_popup()
		for id in ["burger", "fries", "burger", "chicken", "fries", "burger", "cola"]:
			kp.call("_add_one", id)
		await get_tree().physics_frame
	elif pose == "drink":
		UI.open_drink_machine()
	elif pose == "pass" or pose == "fail":
		await _pose_level_result(level, pose == "pass")
	elif pose.begins_with("stars:"):
		# stars:1 / stars:2 / stars:3 —— 造出对应星级的营收，再走真实结算链路
		await _pose_level_result(level, true, int(pose.substr(6)))
	elif pose.begins_with("touch:"):
		await _pose_touch(level, waiter, pose.substr(6))
	elif pose == "order":
		# 真的走一遍玩家路径：点客人 → 服务员走过去 → 到达时接单
		var router: Node = level.get_node("ClickRouter")
		var customers := level.get_node("Actors/Customers")
		for c in customers.get_children():
			if int(c.get("state")) == Constants.State.WAITING_TO_ORDER:
				router.call("handle_click", c.global_position)
				# 等它走到并完成接单
				for i in 240:
					await get_tree().physics_frame
					if not bool(waiter.call("is_busy")):
						break
				break
	elif pose == "dirty":
		# 【注意】不能直接调 table.on_meal_finished() ——
		# 那只是桌子那一半的状态变化，客人节点还在、还会继续被画出来，
		# 截出来的图看起来像「脏桌上还坐着人」。
		# 正确做法是走真实流程：让客人 finish_meal()（结账 → 桌子变脏 → LEAVING），
		# 再把已经该消失的客人移除。
		var customers := level.get_node("Actors/Customers")
		for c in customers.get_children():
			if c.get("state") != Constants.State.LEAVING \
					and c.get("state") != Constants.State.ANGRY_LEAVING:
				c.call("finish_meal")
		for c in customers.get_children():
			if c.get("state") == Constants.State.LEAVING:
				c.queue_free()
	for i in 6:
		await get_tree().process_frame


## 关卡模式的结算界面取证。
##
## 【为什么要走「真实开始按钮」】关卡模式最容易坏在**接线**上
## （信号没人接、倒计时没人推进、重开忘了清场），而这些只有走
## 玩家的那条路才测得出来：UI.press_start() → run_requested → Level 开局 →
## 时间到 → Game.level_finished → UI 弹结算。
## 直接调 UI.show_result() 只是把界面画出来，证明不了这条链是通的。
func _pose_level_result(level: Node, make_pass: bool, star_wanted: int = 0) -> void:
	var spawner: Node = level.get_node("CustomerSpawner")
	spawner.set_process(false)          # 免得客人进来干扰画面
	# 1) 走真实按钮：开始本局
	UI.press_start()
	await get_tree().process_frame
	# 2) 让店里有点内容（接待数不为 0），再决定达标与否 / 拿几星
	Game.served_count = 5
	if star_wanted > 0:
		# 【造出指定的星级】直接给到那一星的门槛（不多给），
		# 这样截图上的星星数就是我们要验证的那个。
		Game.add_money(Game.star_target(clampi(star_wanted, 1, 3)))
	elif make_pass:
		Game.add_money(Game.target_money() + 40)
	else:
		Game.add_money(maxi(1, Game.target_money() / 3))
	# 3) 把时间推到 0（真实路径：Game.tick 由 UIManager 每帧推进）
	Game.tick(9999.0)
	await get_tree().process_frame
	await get_tree().process_frame
	print("  [pose] 关卡结算：第 %d 关 营收=%d 星级=%d 达标=%s 结算界面=%s" % [
		Game.level_index, Game.money, Game.stars(),
		str(Game.passed()), str(UI.is_result_open())])


## 「碰到就触发」的可视化验证。
##
## 把服务员放在桌2的指定一侧，然后**用真实点击链路**点桌子，
## 看他在哪里停下、以及最后有没有和桌子接触。
## 结果同时打印成 ASCII（控制台编码不可靠时也能读）。
func _pose_touch(level: Node, waiter: Node, side: String) -> void:
	var router: Node = level.get_node("ClickRouter")
	var t2: Node = Game.table_by_id(2)
	t2.call("on_meal_finished")          # 弄脏，点它就是收拾

	var box: Rect2 = t2.call("collision_rect_global")
	var r := 16.0
	var centre := box.get_center()
	var start := centre
	match side:
		"right": start = Vector2(box.end.x + 150.0, centre.y)
		"left":  start = Vector2(box.position.x - 150.0, centre.y)
		"above": start = Vector2(centre.x, box.position.y - 150.0)
		"below": start = Vector2(centre.x, box.end.y + 150.0)

	waiter.global_position = start
	router.call("handle_click", centre)      # 点桌子中心

	# 等它走到并触发
	var frames := 0
	for i in 300:
		await get_tree().physics_frame
		frames += 1
		if not bool(waiter.call("is_busy")):
			break

	var pos: Vector2 = waiter.global_position
	var touched: bool = bool(t2.call("touches_from", pos, r))
	var dist_to_edge := pos.distance_to(EntityBase.nearest_point_on_rect(box, pos))
	print("  [touch] side=%-5s start=%s stop=%s frames=%d dirty=%s touched=%s dist_to_edge=%.2f" % [
		side, str(start), str(pos), frames, str(t2.state == TableRules.State.DIRTY),
		str(touched), dist_to_edge])
	for i in 6:
		await get_tree().process_frame


## 逐帧驱动：_process 负责每帧逻辑，_physics_process 负责移动。
## 手动调用它们，就不用真的等好几秒墙上时间。
##
## 【只驱动游戏世界，绝不碰 UI 与 autoload】
## 这一条是踩坑换来的：早先的版本对整个场景树（含 UI / Stickers）
## 递归调 _process，结果弹窗遮罩在截图里**盖不住 HUD** ——
## 而引擎内部采样显示遮罩其实是好的（各点亮度比 0.44~0.48，正是 55% 黑）。
## 原因是手动调 Control._process 会打乱 Godot 内部的 canvas 更新标记，
## 弹窗那种 PROCESS_MODE_ALWAYS 的节点就画不对了。
## 结论：截图工具只准推进**世界**，UI 交给引擎自己每帧跑。
func _simulate(level: Node, seconds: float) -> void:
	const STEP := 1.0 / 60.0
	var steps := int(seconds / STEP)
	for i in steps:
		# 只驱动世界与演员；UI / autoload 交给引擎自己每帧跑，
		# 避免同一次 _process 被手动和引擎各调一遍。
		for group in ["World", "Actors"]:
			var n := level.get_node_or_null(group)
			if n != null:
				_walk_tree(n, "_physics_process", STEP)
				_walk_tree(n, "_process", STEP)
		await get_tree().process_frame


func _walk_tree(node: Node, method: String, delta: float) -> void:
	if node.has_method(method):
		node.call(method, delta)
	for c in node.get_children():
		_walk_tree(c, method, delta)


func _report(level: Node) -> void:
	print("──────── 状态快照 ────────")
	print("  钱 = %d，已接待 = %d，气走 = %d" % [Game.money, Game.served_count, Game.angry_count])
	print("  手上 = %s，出餐口 = %s，后厨队列 = %d" % [
		Game.hand_name(), Game.kitchen.counter_name(), Game.kitchen.queue_count()])
	print("  空桌 = %d，待收拾 = %d" % [Game.empty_table_count(), Game.dirty_table_count()])
	print("  在店人数 = %d" % level.get_node("CustomerSpawner").call("in_store_count"))
	# 同样一条信息的 ASCII 版：控制台是 ANSI 代码页时中文会变乱码，
	# 这行保证不看中文也能判断数字对不对。
	var leaving := 0
	var waiting := 0
	for c in level.get_node("Actors/Customers").get_children():
		var st: int = int(c.get("state"))
		if st == Constants.State.LEAVING or st == Constants.State.ANGRY_LEAVING:
			leaving += 1
		else:
			waiting += 1
	print("  [ascii] customers total=%d active(in_store)=%d leaving=%d" % [
		leaving + waiting, waiting, leaving])
	print("  订单栏票数 = %d" % Game.active_orders().size())
	for t in Game.tables:
		# 【桌子没有 occupant 这个属性】occupant 是**座位**（Seat）的字段，
		# 桌子只是通过 seats 持有座位。原来这里读 t.occupant 会抛
		# 「Invalid access to property or key 'occupant'」，只是因为它发生在
		# 报告阶段（截图已经存盘），所以一直没人注意。
		var who := "无"
		var guests: Array = t.call("customers")
		if not guests.is_empty():
			var names := PackedStringArray()
			for g in guests:
				names.append(_state_name(int(g.get("state"))))
			who = "客人(%s)" % ", ".join(names)
		print("    %s state=%s occupant=%s order=%s" % [
			t.label, _table_state_name(t.state), who,
			("<无>" if t.order == null else str(t.order.items))])
	print("  飘字条数 = %d" % Stickers.count())
	print("──────────────────────────")


func _state_name(s: int) -> String:
	match s:
		Constants.State.WALKING_IN: return "走向座位"
		Constants.State.WAITING_TO_ORDER: return "等点单"
		Constants.State.ORDER_TAKEN: return "等上菜"
		Constants.State.ORDERED: return "已下单"
		Constants.State.EATING: return "用餐中"
		Constants.State.LEAVING: return "离场"
		Constants.State.ANGRY_LEAVING: return "气走"
	return "?"


func _table_state_name(s: int) -> String:
	match s:
		TableRules.State.CLEAN_EMPTY: return "干净空"
		TableRules.State.DIRTY: return "脏"
		TableRules.State.OCCUPIED: return "有人"
	return "?"
