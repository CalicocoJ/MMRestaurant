extends Node
## 「站在椅子旁会不会触发清洁」现场取证。
##
## 用法：
##   godot --headless --path <project> res://tools/diag_clean.tscn
##
## 【为什么要这个】玩家两次反馈「站在椅子旁边也能清洁」，
## 而我按代码算（判定区=整个桌面 80×60）怎么都不该触发 ——
## 测量与现象冲突时，就把动作执行那一刻的全部数值打出来。
##
## 做法：把脏桌摆在中间，让服务员从**右侧椅子外侧**一步步逼近，
## 记录「第一次判定为到达」时的位置 —— 那一刻就是清洁开始的位置。

const STEP := 1.0 / 60.0

var _ok := 0
var _bad := 0


func _ready() -> void:
	await get_tree().process_frame
	var lv: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(lv)
	lv.get_node("CustomerSpawner").set_process(false)
	await get_tree().physics_frame

	var t: Node = Game.table_by_id(2)
	t.state = TableRules.State.DIRTY
	t.call("_refresh_look")

	var box: Rect2 = t.call("touch_box")
	var phys: Rect2 = t.call("collision_rect_global")
	var waiter: Node = lv.get_node("Actors/Waiter")
	var router: Node = lv.get_node("ClickRouter")

	print("")
	print("======== 站哪才算碰到桌子 ========")
	print("  可碰区(整个桌面) %s" % str(box))
	print("  碰撞盒(寻路用)   %s" % str(phys))
	print("  服务员半径 16，判定阈值 = 16 + 1 = 17")
	print("")

	# 从桌子右侧很远的地方开始，每次靠近 4px，找「第一次算到达」的位置
	var y := box.get_center().y
	var first_hit_x := -1.0
	var x := box.end.x + 200.0
	while x > box.end.x - 10.0:
		waiter.global_position = Vector2(x, y)
		# 直接问两条判据
		if bool(t.call("touches_from", waiter.global_position, 16.0)):
			first_hit_x = x
			break
		x -= 1.0

	var d_at_hit: float = (first_hit_x - box.end.x)
	print("  从右侧逼近：第一次「算碰到桌子」在 x=%.0f，离桌面右沿 %.0fpx" % [
		first_hit_x, d_at_hit])
	if first_hit_x > 0.0 and d_at_hit <= 17.0:
		_ok += 1
		print("  [OK]   必须在身体贴住桌面（≤17px）才算碰到 ✓")
	else:
		_bad += 1
		print("  [FAIL] 太早触发（离 %.0fpx 就算碰到了）" % d_at_hit)

	# 椅子外侧：右椅 x 728..768（桌2）。站在椅子右边、桌面之外
	var chair_out := Vector2(768.0 + 10.0, y)
	var d_chair: float = chair_out.distance_to(EntityBase.nearest_point_on_rect(box, chair_out))
	var hit_chair := bool(t.call("touches_from", chair_out, 16.0))
	print("")
	print("  站在右椅外侧 %s：离桌面 %.0fpx → 算碰到? %s" % [
		str(chair_out), d_chair, str(hit_chair)])
	if not hit_chair:
		_ok += 1
		print("  [OK]   站在椅子外侧**不会**触发清洁 ✓")
	else:
		_bad += 1
		print("  [FAIL] 站在椅子外侧也会触发 —— 这就是玩家报的问题")

	# 走一遍完整流程：从右侧远处点脏桌，看清洁在哪停下
	print("")
	print("======== 从右侧点脏桌：他在哪停下 ========")
	waiter.global_position = Vector2(box.end.x + 220.0, y)
	router.call("handle_click", t.global_position + Vector2(40, 30))
	for i in int(8.0 / STEP):
		await get_tree().physics_frame
		if waiter.call("is_locked"):
			break
	var stop: Vector2 = waiter.global_position
	var d_stop: float = stop.distance_to(EntityBase.nearest_point_on_rect(box, stop))
	print("  停在 %s，离桌面 %.1fpx（阈值 17）" % [str(stop), d_stop])
	if d_stop <= 17.5:
		_ok += 1
		print("  [OK]   停下时身体确实贴住了桌面 ✓（绕到够得着的一侧）")
	else:
		_bad += 1
		print("  [FAIL] 停在离桌面 %.1fpx 处还是太远" % d_stop)

	# ── 复现玩家报的场景：卡住时**再点一次**同一张脏桌 ──
	#
	# 玩家描述：第一次点 → 服务员撞上椅子卡了約 1 秒才绕开；
	# 如果在卡住期间又点一次脏桌，他就在椅子旁（没碰到桌子）触发了清洁。
	print("")
	print("======== 卡住期间再点一次（复现玩家场景）========")
	# 【测试自身的坑】上一段结束时服务员可能还在清洁（_locked），
	# 那样这里的点击直接被拒绝、什么都测不到 —— 先等他空闲，
	# 并且换一张**没被碰过的**桌子。
	for i in int(10.0 / STEP):
		await get_tree().physics_frame
		if not waiter.call("is_locked") and not waiter.call("is_busy"):
			break
	var t3: Node = Game.table_by_id(3)
	var box3: Rect2 = t3.call("touch_box")
	t3.state = TableRules.State.DIRTY
	t3.call("_refresh_look")
	print("  准备就绪：_locked=%s 用 %s（判定区 %s）" % [
		str(waiter.get("_locked")), t3.label, str(box3)])
	# 站到「右边被椅子挡住」的位置，让他第一次点必然要绕
	waiter.global_position = Vector2(box3.end.x + 220.0, box3.get_center().y)
	router.call("handle_click", t3.global_position + Vector2(40, 30))
	# 只推进很短一段：让他刚走到椅子附近（还没绕开）
	for i in int(1.0 / STEP):
		await get_tree().physics_frame
	var mid: Vector2 = waiter.global_position
	var d_mid: float = mid.distance_to(EntityBase.nearest_point_on_rect(box3, mid))
	print("  第一次点击后 1.0 秒：位置 %s，离桌面 %.1fpx，清洁中=%s，卡住 %.2f 秒" % [
		str(mid.round()), d_mid, str(waiter.call("is_locked")),
		float(waiter.get("_stuck_clock"))])

	# 就在这一刻再点一次
	router.call("handle_click", t3.global_position + Vector2(40, 30))
	for i in int(4.0 / STEP):
		await get_tree().physics_frame
		if waiter.call("is_locked"):
			break
	var after: Vector2 = waiter.global_position
	var d_after: float = after.distance_to(EntityBase.nearest_point_on_rect(box3, after))
	print("  再点一次后：位置 %s，离桌面 %.1fpx，清洁中=%s" % [
		str(after.round()), d_after, str(waiter.call("is_locked"))])
	if not waiter.call("is_locked"):
		_ok += 1
		print("  [OK]   没触发清洁（他还在走）")
	elif d_after <= 17.5:
		_ok += 1
		print("  [OK]   触发了清洁，而且身体确实贴住了桌面 ✓")
	else:
		_bad += 1
		print("  [FAIL] **在没碰到桌子的情况下触发了清洁**（离 %.1fpx）— 玩家报的就是这个" % d_after)

	print("--------------------------------")
	print("通过 %d / 失败 %d" % [_ok, _bad])
	print("================================")
	get_tree().quit(1 if _bad > 0 else 0)
