extends Node
## 「走得顺不顺」体检：撞到椅子后**游戏自己改道**，不需要玩家再点一次。
##
## 用法：
##   godot --headless --path <project> res://tools/check_smooth_walk.tscn
##
## 【它防的是哪个回归】
## 玩家反馈：去桌子的路上**擦到椅子就卡住**，要再点一次桌子才会迅速改道。
## 根因是判卡只看「位移 < 1.5px」——擦着椅子滑行时一帧还能滑 3~4px，
## 永远判不了卡，等真滑不动了人已经贴死。
##
## 所以这里不看「最后有没有走到」（那有 stuck 看门狗兜底，旧代码也能过），
## 而是看**有没有连续多帧「想走却没走出去」**：
##   - 期望步长 = speed × delta；真实位移 < 期望 × BLOCKED_MOVE_RATIO 记为 1 帧停滞
##   - 修好之后，最长连续停滞必须很短（改道在冷却 0.3s ≈ 18 帧内发生）
##
## 这些帧数直接对应玩家的观感：连续停滞 8 帧（0.13s）看不出来，
## 连续停滞 60 帧（1s）就是「卡住不动了」。

const STEP := 1.0 / 60.0
## 与 waiter.gd 的 BLOCKED_MOVE_RATIO 一致。它是对外可见的手感参数，
## 改了那边就要同步这里（不一致会让这个体检变成假绿）。
const BLOCKED_MOVE_RATIO := 0.6
## 最长可接受停滞：改道冷却 0.3s = 18 帧，留一点余量
const MAX_STALL_FRAMES := 30

var _ok := 0
var _bad := 0


func _ready() -> void:
	await get_tree().process_frame
	var level: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(level)
	level.get_node("CustomerSpawner").set_process(false)
	await get_tree().physics_frame

	var waiter: Node = level.get_node("Actors/Waiter")
	var router: Node = level.get_node("ClickRouter")

	print("")
	print("======== 顺畅行走体检（撞椅子自己改道）========")

	_test_blocked_predicate(waiter)
	_test_slide_steer(waiter)
	await _test_real_collision(waiter, router)
	await _test_routes(waiter, router)
	await _test_budget_recovers(waiter, router)

	print("--------------------------------")
	print("通过 %d / 失败 %d" % [_ok, _bad])
	print("================================")
	get_tree().quit(1 if _bad > 0 else 0)


# ── 1. 判据本身：擦着滑行也必须算「没走出去」 ──────────────────────

func _test_blocked_predicate(waiter: Node) -> void:
	print("[1] 判据：位移只有期望的四成 → 必须算「撞住了」")
	waiter.call("cancel_command", "体检复位")
	var want: float = float(waiter.get("speed")) * STEP

	# ① 只有期望的 40%：这正是「擦着椅子磨」的样子，旧判据（<1.5px）看不见
	waiter.set("_last_pos", waiter.global_position + Vector2(want * 0.4, 0))
	_eq(bool(waiter.call("_blocked_no_progress", STEP)), true,
		"位移 %.1fpx（期望 %.1fpx）→ 判为撞住" % [want * 0.4, want])

	# ② 走了 90%：正常移动，不能误判（误判会让人走得歪歪扭扭）
	waiter.set("_last_pos", waiter.global_position + Vector2(want * 0.9, 0))
	_eq(bool(waiter.call("_blocked_no_progress", STEP)), false,
		"位移 %.1fpx（正常）→ 不算撞住" % [want * 0.9])

	# ③ 位移为 0：指令刚下达（还没走过），不能白算一次路径
	waiter.set("_last_pos", waiter.global_position)
	_eq(bool(waiter.call("_blocked_no_progress", STEP)), false,
		"位移恰好为 0（指令第一帧）→ 不算撞住")
	waiter.set("_last_pos", waiter.global_position)


# ── 2. 沿面滑行：速度要真的被偏到切向 ─────────────────────────────

func _test_slide_steer(waiter: Node) -> void:
	print("[2] 滑行：只在「真的在往面里压」时才偏转")
	# 【几何约定】move_and_slide 的法线指向**离开障碍**的一侧，
	# 「压着这个面」= 前进方向与法线对抗（dot < 0）。下面障碍都在正前方。
	# 正撞：法线迎面；前进 (-1,0) 正压进去 → 必须偏 18°，且压向障碍的分量要变小
	waiter.set("_slide_dir", Vector2(1, 0))
	var head_on: Vector2 = waiter.call("_slide_steer", Vector2(-1, 0))
	var into_before := Vector2(-1, 0).dot(Vector2(1, 0))
	var into_after := head_on.dot(Vector2(1, 0))
	_ok += 1
	if into_after > into_before + 0.01 and absf(head_on.length() - 1.0) < 0.001:
		print("  [OK]   正撞：偏 %.0f°，压向障碍 %.2f → %.2f（沿面滑走）" % [
			rad_to_deg(absf(Vector2(-1, 0).angle_to(head_on))), into_before, into_after])
	else:
		_bad += 1
		print("  [FAIL] 正撞没有沿面滑：%s（压向障碍 %.2f → %.2f）" % [
			str(head_on), into_before, into_after])

	# 擦角：法线与前进方向几乎垂直（贴着面滑过去）→ 不该偏，路线不该拐多余的弯
	waiter.set("_slide_dir", Vector2(0.02, -0.9998))
	var graze_in := Vector2(-1, 0)
	var graze: Vector2 = waiter.call("_slide_steer", graze_in)
	var graze_deg := rad_to_deg(absf(graze_in.angle_to(graze)))
	_ok += 1
	if graze_deg < 3.0:
		print("  [OK]   擦角：偏 %.1f°（几乎不变，不会为了避让绕远路）" % graze_deg)
	else:
		_bad += 1
		print("  [FAIL] 擦角被偏得太多：%.1f°" % graze_deg)

	# 没有碰撞时不能残留偏转
	waiter.set("_slide_dir", Vector2.ZERO)
	var plain: Vector2 = waiter.call("_slide_steer", Vector2(1, 0))
	_eq(plain, Vector2(1, 0), "没有碰撞 → 方向原样返回")
	waiter.call("cancel_command", "体检复位")


# ── 2b. 真的撞上椅子：滑行与改道必须真的启动 ──────────────────────

func _test_real_collision(waiter: Node, router: Node) -> void:
	print("[2b] 真撞家具：滑行要生效，且不许长时间停滞")
	waiter.call("cancel_command", "体检复位")
	await get_tree().physics_frame
	waiter.call("cancel_command", "体检复位")
	# 【为什么要人为把落脚点设进家具】正常路径已经不擦家具了
	# （净空修好后实测最近也有 42px），点空地/点桌子都不会碰撞。
	# 但玩家**硬点家具里侧**时（视觉上分不清桌沿），落脚点就在碰撞盒深处，
	# 身体会一路顶上去 —— 这条最坏路径必须仍然是「沿面滑 + 到点放弃」，
	# 不能变成高频抖动或永久僵死。所以这里直接把落脚点指到桌面中心，
	# 用真实的碰撞法线跑一遍 A/C。
	var table: Node = Game.table_by_id(1)
	var centre: Vector2 = table.call("collision_rect_global").get_center()
	var start := Vector2(180, 700)          # 远处起点：会沿桌1 左侧压上去一段
	waiter.global_position = start
	waiter.set("_last_pos", start)
	waiter.call("command_move", centre, Callable(), "探针：压进桌子")
	var pf: Node = get_tree().get_first_node_in_group("pathfinder")
	var snapped: Array = pf.call("find_path", start, centre)
	var endp: Vector2 = snapped[snapped.size() - 1] if not snapped.is_empty() else start
	print("    夹具：起点 %s → 目标 %s（桌心），A* 终点 %s" % [
		str(start), str(centre.round()), str(endp.round())])

	var longest := 0
	var streak := 0
	var slide_frames := 0
	var travelled := 0.0
	var prev := start
	var collision := 0
	var osc := 0
	var last_dir := Vector2.ZERO
	for i in int(6.0 / STEP):
		await get_tree().physics_frame
		if Vector2(waiter.get("_slide_dir")) != Vector2.ZERO:
			slide_frames += 1
		var p: Vector2 = waiter.global_position
		collision = maxi(collision, waiter.get_slide_collision_count())
		travelled += p.distance_to(prev)
		prev = p
		var moved: float = p.distance_to(waiter.get("_last_pos"))
		var want: float = float(waiter.get("speed")) * STEP
		if bool(waiter.call("is_busy")) and moved > 0.0 and moved < want * BLOCKED_MOVE_RATIO:
			streak += 1
			longest = maxi(longest, streak)
		else:
			streak = 0
		# 抖动 = 走路方向高频反向（贴着家具时才会出现）
		if moved > 0.3:
			var dir := (p - prev).normalized()
			if last_dir != Vector2.ZERO and dir.dot(last_dir) < -0.5:
				osc += 1
			last_dir = dir
		if not bool(waiter.call("is_busy")):
			break
	# 夹具自检：得真的压上去才算覆盖到
	print("    夹具：结束位置 %s，离桌心 %.1fpx，滑行帧 %d" % [
		str(waiter.global_position.round()),
		waiter.global_position.distance_to(centre), slide_frames])

	_ok += 1
	if slide_frames > 0 or collision > 0:
		print("  [OK]   真的发生碰撞：滑行状态 %d 帧、同帧多碰撞最多 %d 次，走了 %.0fpx" % [
			slide_frames, collision, travelled])
	else:
		_bad += 1
		print("  [FAIL] 全程没碰到家具，这条用例没覆盖到 A/C")
	_ok += 1
	if longest <= MAX_STALL_FRAMES:
		print("  [OK]   压在桌子里侧时最长停滞 %d 帧（上限 %d），走路反向 %d 次" % [
			longest, MAX_STALL_FRAMES, osc])
	else:
		_bad += 1
		print("  [FAIL] 压着桌子时连续停滞 %d 帧（上限 %d）—— 又回到「顶着不动」" % [
			longest, MAX_STALL_FRAMES])
	waiter.call("cancel_command", "体检复位")


# ── 3. 真跑路线：量最长连续停滞帧数 ────────────────────────────────

func _test_routes(waiter: Node, router: Node) -> void:
	print("[3] 真路线：贴桌椅走时最长连续停滞")
	# 起点都是「直线过去必然擦到椅子」的位置：
	#   从桌子下方点座位/桌子 → 路径会贴椅子外沿；从桌子右侧点左边座位 → 要绕过整团家具
	# 目标点**必须落在空地上**：点到桌面上会被桌子的 interact() 吃掉
	# （空桌只会飘字「这桌是空的」），那样量到的是「根本没走」，不是走路卡顿。
	# 下面每个终点都在家具碰撞盒之外，但路线会贴着桌椅挤过去。
	var cases := [
		["桌1 下方 → 桌1 左上方", Vector2(150, 700), Vector2(230, 350)],
		["桌2 下方 → 桌2 右上方", Vector2(680, 700), Vector2(940, 300)],
		["桌3 右方 → 桌3 左上方", Vector2(1210, 470), Vector2(900, 300)],
		["桌2 右下 → 桌1 右侧", Vector2(680, 680), Vector2(330, 680)],
		["桌1 下方 → 桌2 上方空地", Vector2(150, 700), Vector2(680, 300)],
		["桌3 左下 → 桌3 上方空地", Vector2(960, 700), Vector2(1050, 300)],
	]
	for c in cases:
		await _run_case(waiter, router, String(c[0]), c[1], c[2])


func _run_case(waiter: Node, router: Node, name: String, from: Vector2,
		to: Vector2) -> void:
	waiter.call("cancel_command", "体检复位")
	await get_tree().physics_frame
	waiter.call("cancel_command", "体检复位")
	waiter.global_position = from
	waiter.set("_last_pos", from)
	router.call("handle_click", to)

	var longest := 0
	var streak := 0
	var stall_frames := 0
	var blocked_repaths := 0
	var min_clear := INF
	var clear_before_stop := INF
	# 到达后身体本来就允许贴着家具（那是「碰到才算到」，不是擦身），
	# 所以「压进家具」的判定只取停下来之前的那一段 —— 否则会把正常贴边算成 bug。
	var last_repath := int(waiter.get("_blocked_repath_count"))
	for i in int(12.0 / STEP):
		await get_tree().physics_frame
		var busy := bool(waiter.call("is_busy")) or bool(waiter.call("is_locked"))
		var p: Vector2 = waiter.global_position
		var clear := _clearance(p)
		min_clear = minf(min_clear, clear)
		if busy:
			clear_before_stop = minf(clear_before_stop, clear)
		var moved: float = p.distance_to(waiter.get("_last_pos"))
		var want: float = float(waiter.get("speed")) * STEP
		if busy and moved > 0.0 and moved < want * BLOCKED_MOVE_RATIO:
			streak += 1
			stall_frames += 1
			longest = maxi(longest, streak)
		else:
			streak = 0
		var now_repath := int(waiter.get("_blocked_repath_count"))
		if now_repath > last_repath:
			blocked_repaths += now_repath - last_repath
			last_repath = now_repath
		if not busy:
			break

	var dist: float = waiter.global_position.distance_to(to)
	# 「走到了」用较宽松的残差：擦边滑动本来就会留几像素
	var reached := dist <= 24.0
	# 身体半径 16：走动途中（不含到达贴边那一下）最近也不该压进家具
	var overlapping := clear_before_stop < 15.0
	if longest <= MAX_STALL_FRAMES and reached and not overlapping:
		_ok += 1
		print("  [OK]   %-24s 最长停滞 %2d 帧（%.2fs）停滞 %2d 帧 改道 %d 次 行走最近离家具 %.1fpx" % [
			name, longest, float(longest) * STEP, stall_frames, blocked_repaths, clear_before_stop])
	elif not reached:
		_bad += 1
		print("  [FAIL] %-24s 没走到：停在 %s，离目标 %.0fpx" % [
			name, str(waiter.global_position.round()), dist])
	elif overlapping:
		_bad += 1
		print("  [FAIL] %-24s 行走中身体压进家具：最近直线距离 %.1fpx（身体半径 16）" % [
			name, clear_before_stop])
	else:
		_bad += 1
		print("  [FAIL] %-24s 卡了 %d 帧（%.2fs，上限 %d 帧）改道 %d 次" % [
			name, longest, float(longest) * STEP, MAX_STALL_FRAMES, blocked_repaths])


## 圆心到所有家具碰撞盒的最近距离（= 身体外沿离家具还有多远）
func _clearance(p: Vector2) -> float:
	var best := INF
	for tb in Game.tables:
		var d: float = p.distance_to(
			EntityBase.nearest_point_on_rect(tb.call("collision_rect_global"), p))
		best = minf(best, d)
	return best


# ── 4. 预算会恢复：撞多几次之后不能永久失效 ────────────────────────

func _test_budget_recovers(waiter: Node, router: Node) -> void:
	print("[4] 撞住预算会回收（否则撞几次后又退回「必须再点一次」）")
	waiter.call("cancel_command", "体检复位")
	await get_tree().physics_frame
	waiter.call("cancel_command", "体检复位")
	waiter.set("_blocked_repath_count", 4)
	waiter.set("_progress_clock", 0.0)
	waiter.global_position = Vector2(560, 560)     # 门口附近的空地
	waiter.set("_last_pos", waiter.global_position)
	router.call("handle_click", Vector2(900, 560)) # 一条畅通路线

	var frames := 0
	for i in int(3.0 / STEP):
		await get_tree().physics_frame
		frames += 1
		if int(waiter.get("_blocked_repath_count")) < 4:
			break
		if not bool(waiter.call("is_busy")):
			break
	var after := int(waiter.get("_blocked_repath_count"))
	frames += 0
	_ok += 1
	if after < 4:
		print("  [OK]   畅通走了 %d 帧后预算 4 → %d" % [frames, after])
	else:
		_bad += 1
		print("  [FAIL] 走了 %d 帧预算仍是 %d（回收没生效）" % [frames, after])
	waiter.call("cancel_command", "体检复位")


func _eq(got: Variant, want: Variant, label: String) -> void:
	if got == want:
		_ok += 1
		print("  [OK]   %s" % label)
	else:
		_bad += 1
		print("  [FAIL] %s（期望 %s，实际 %s）" % [label, str(want), str(got)])
