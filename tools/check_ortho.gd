extends Node
## 验收：路径必须是「横竖交替」的直角折线，不允许任何斜线段。
##
## 用法：
##   godot --headless --path <project> res://tools/check_ortho.tscn
##
## 【这个测试要抓的 bug】
## 玩家反馈「一靠近桌椅就出现斜线」。
## 成因：A* 的拐点是格子中心，终点为了贴家具会偏几像素，
## 共线合并把「几乎竖直」的段和竖直段合并成了一条斜线。
## 所以这里直接断言：实际执行的路径里**没有任何一段同时有横向和纵向位移**。

const STEP := 1.0 / 60.0

var _ok := 0
var _bad := 0


func _ready() -> void:
	await get_tree().process_frame
	var lv: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(lv)
	lv.get_node("CustomerSpawner").set_process(false)
	await get_tree().physics_frame

	var waiter: Node = lv.get_node("Actors/Waiter")
	var router: Node = lv.get_node("ClickRouter")
	var spawner: Node = lv.get_node("CustomerSpawner")

	print("")
	print("======== 直角折线验收（不许有斜线）========")
	# 把**每一个**碰撞形状的真实世界坐标打出来，别靠心算
	for tb in Game.tables:
		print("  %s body@%s  nav=%s" % [
			tb.label, _v(tb.global_position), str(tb.call("nav_rect_global"))])
		var idx := 0
		for c in tb.get_children():
			if c is CollisionShape2D and c.shape is RectangleShape2D:
				var r := c.shape as RectangleShape2D
				var box := Rect2(tb.global_position + c.position - r.size * 0.5, r.size)
				print("     形状%d 世界矩形=%s" % [idx, str(box)])
				idx += 1

	# 覆盖各种情形，特别是「紧贴桌椅」的。
	# 坐标跟着 layout.json 走（桌1 x=270、桌2 x=640、桌3 x=1010，y=440）。
	var cases: Array = [
		["空地对空地", Vector2(1150, 600), Vector2(860, 250)],
		["正下方→桌子上方", Vector2(680, 580), Vector2(680, 280)],
		["桌子正下→左侧空地", Vector2(680, 560), Vector2(200, 470)],
		["桌间窄道往返", Vector2(460, 560), Vector2(830, 560)],
		["贴右墙→桌子左侧", Vector2(1250, 300), Vector2(180, 470)],
		["底部中间→右上角", Vector2(620, 690), Vector2(1240, 200)],
		["贴桌右侧→桌左", Vector2(1180, 470), Vector2(920, 470)],
		["桌脚边→桌对侧", Vector2(430, 540), Vector2(430, 380)],
	]

	for c in cases:
		var name: String = c[0]
		var from: Vector2 = c[1]
		var to: Vector2 = c[2]
		waiter.global_position = from
		waiter.set("_last_pos", from)
		router.call("handle_click", to)
		# 【必须先等一帧再取路径】路径是在 `_walk()` 里懒构建的（`_build_path`），
		# 点击那一帧 `_waypoints` 还是空的 —— 原来的写法于是把「0 个拐点」
		# 当成「没有斜线」直接通过（假绿），而 `_settle()` 又因为上一例残留的
		# `is_busy=false` 立刻返回，量到的是**上一例的位置**。
		await get_tree().physics_frame
		var wps: Array = waiter.get("_waypoints").duplicate()
		var goal: Vector2 = waiter.get("_goal_pt")

		# ── 逐帧监控**真实移动方向**：横/竖/斜各占多少帧 ──
		#
		# 【为什么改成这个】按「拐点序列」判会漏两边：
		#   ① 路径数组是空的（懒构建）→ 假绿；
		#   ② 服务员朝第一个拐点走的**第一帧**，起点不在网格轴上，
		#      于是每次都量出一段 10px 的「像素级斜线」（那是正常贴格，
		#      不是路径斜线）。逐帧看真实位移才是玩家眼里的「有没有斜着走」。
		var axis := 0
		var oblique := 0
		var worst := 0.0
		var prev_pos: Vector2 = from
		for i in int(9.0 / STEP):
			await get_tree().physics_frame
			var p: Vector2 = waiter.global_position
			var d := p - prev_pos
			prev_pos = p
			if d.length() < 0.5:
				continue
			var dx: float = absf(d.x)
			var dy: float = absf(d.y)
			# 阈值 2px：A* 拐点是 20px 的格子中心，起点/终点不在轴上时，
			# 一步之内会有 1~1.5px 的贴格过渡（不算「斜着走」）。
			# 真正的斜线路径每帧斜向分量在 3px 以上，必然被抓到。
			if dx > 2.0 and dy > 2.0:
				oblique += 1
				worst = maxf(worst, minf(dx, dy))
			else:
				axis += 1
			if not bool(waiter.call("is_busy")) and not bool(waiter.call("is_locked")):
				break

		if oblique == 0:
			_ok += 1
			print("  [OK]   %-16s 全程横竖走（%d 帧轴向，无斜帧）" % [name, axis])
		else:
			_bad += 1
			print("  [FAIL] %-16s 有 %d 帧斜着走（最大斜向分量 %.1fpx）" % [
				name, oblique, worst])

		# 还要确认它真的能走到（不能为了好看把路弄不通）
		await _settle(waiter, 9.0)
		var d2: float = waiter.global_position.distance_to(goal)
		if d2 <= 26.0:
			_ok += 1
		else:
			_bad += 1
			print("         [FAIL] 但没走到：停在 %s，离落脚点 %.1fpx（拐点 %d 个）" % [
				_v(waiter.global_position), d2, wps.size()])

	# 顺带验一下「接单」路径也不许有斜线
	var t1: Node = Game.table_by_id(1)
	var seat = t1.seats[0]
	var cust: Node = spawner.call("spawn_at_seat", t1, seat)
	cust.global_position = t1.call("seat_sit_point", seat)
	lv.call("_on_customer_seated", cust)
	waiter.global_position = Vector2(600, 560)
	router.call("handle_click", cust.global_position)
	var wps2: Array = waiter.get("_waypoints").duplicate()
	var diag2 := 0
	var prev2 := Vector2(600, 560)
	for p in wps2:
		if absf(prev2.x - p.x) > 1.0 and absf(prev2.y - p.y) > 1.0:
			diag2 += 1
		prev2 = p
	if diag2 == 0:
		_ok += 1
		print("  [OK]   %-16s 无斜线段（%d 个拐点）" % ["去接单", wps2.size()])
	else:
		_bad += 1
		print("  [FAIL] %-16s 有 %d 段斜线：%s" % ["去接单", diag2, _seq_str(wps2)])

	print("----------------------------------------")
	print("通过 %d / 失败 %d" % [_ok, _bad])
	print("========================================")
	get_tree().quit(1 if _bad > 0 else 0)


func _settle(waiter: Node, seconds: float) -> void:
	for i in int(seconds / STEP):
		await get_tree().physics_frame
		if not bool(waiter.call("is_busy")) and not bool(waiter.call("is_locked")):
			return


func _v(p: Vector2) -> String:
	return "(%.0f,%.0f)" % [p.x, p.y]


func _seq_str(arr: Array) -> String:
	var parts: PackedStringArray = []
	for p in arr:
		parts.append(_v(p))
	return " → ".join(parts)
