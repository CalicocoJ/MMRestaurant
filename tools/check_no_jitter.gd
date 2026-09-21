extends Node
## 抖动体检：站在家具边上时**不许高频来回**，也不许原地高频摆动。
##
## 用法：
##   godot --headless --path <project> res://tools/check_no_jitter.tscn
##
## 【它防的是哪个回归】玩家反馈：碰到桌子时偶尔会抖。
## 当时的机制是「落脚点落在碰撞盒里 → 每帧想压进去、被 move_and_slide 挤出，
## 叠加沿面滑行给的横向分量」，表现为人贴着桌沿以 60Hz 左右摆动
## 1~2px（实测 x 在 343.6↔344.8 之间），或干脆一帧掉头一帧掉回来。
##
## 【判据】逐帧看服务员位移：相邻两帧位移方向夹角 > 120° 记为一次「来回」。
## 抖动就是这种来回在短时间内反复出现（实测 bug 版本：连点桌子时 60Hz 摆动、
## 180 帧里 34 次来回）。绕家具时的正常掉头一次到达最多几次，所以上限取 6。
## 「走到目标」本身不在这里断言，那是 check_routes / check_level_mode 的事。
##
## 【为什么不用「没靠近目标就算摆动」】那个判据太糙：绕桌走的一整段本来就
## 不靠近目标（垂直于目标方向走），会把正常绕行全判成抖动。
##
## 【为什么要连点】抖动只在「玩家反复点同一张桌子」时最明显
## （每次点击都会重算落脚点），所以每个用例都以 0.15s 的节奏模拟连点。

const STEP := 1.0 / 60.0
## 允许的来回次数：一次到达过程中正常的掉头（绕家具）最多这么多次
const MAX_REVERSALS := 6

var _ok := 0
var _bad := 0
var _waiter: Node = null
var _router: Node = null


func _ready() -> void:
	await get_tree().process_frame
	var level: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(level)
	level.get_node("CustomerSpawner").set_process(false)
	await get_tree().physics_frame
	_waiter = level.get_node("Actors/Waiter")
	_router = level.get_node("ClickRouter")

	print("")
	print("======== 抖动体检（碰到桌子不许来回摆）========")
	await _case("点脏桌1（从下方，连点）", Vector2(310, 580), 1, Vector2(275, 468))
	await _case("点脏桌2（从下方，连点）", Vector2(680, 580), 2, Vector2(645, 468))
	await _case("点脏桌3（从下方，连点）", Vector2(1050, 580), 3, Vector2(1015, 468))
	await _case("点脏桌1（从左上，连点）", Vector2(150, 350), 1, Vector2(300, 430))
	await _case("点脏桌2（从右侧，连点）", Vector2(1210, 470), 2, Vector2(700, 455))
	await _case("点脏桌1（椅子边，连点）", Vector2(430, 500), 1, Vector2(300, 468))
	await _case("点空地贴桌沿（连点）", Vector2(310, 580), 1, Vector2(345, 468))

	print("--------------------------------")
	print("通过 %d / 失败 %d" % [_ok, _bad])
	print("================================")
	get_tree().quit(1 if _bad > 0 else 0)


## 一个用例：站到 from，然后每 0.15s 点一次 (px, py)，边走边量抖动
func _case(label: String, from: Vector2, table_id: int, click_pt: Vector2) -> void:
	_waiter.call("cancel_command", "体检复位")
	await get_tree().physics_frame
	_waiter.call("cancel_command", "体检复位")
	_waiter.global_position = from
	_waiter.set("_last_pos", from)

	var table: Node = Game.table_by_id(table_id)
	var reversals := 0
	var last_dirs: Array = []
	var prev: Vector2 = from
	var min_goal_dist := INF
	var clicks := 0
	for i in int(6.0 / STEP):
		if i % 9 == 0:                       # 每 0.15s 点一次（模拟玩家连点）
			table.state = TableRules.State.DIRTY
			table.call("_refresh_look")
			_router.call("handle_click", click_pt)
			clicks += 1
		await get_tree().physics_frame
		var p: Vector2 = _waiter.global_position
		var d := p - prev
		prev = p
		var goal: Vector2 = _waiter.get("_goal_pt")
		min_goal_dist = minf(min_goal_dist, p.distance_to(goal))
		if d.length() < 0.3:
			continue
		# 方向反转：与前两帧中任意一帧的方向接近相反（>120°）就算一次来回
		for d0 in last_dirs:
			if (d0 as Vector2).normalized().dot(d.normalized()) < -0.5:
				reversals += 1
				break
		last_dirs.append(d)
		if last_dirs.size() > 2:
			last_dirs.pop_front()
		if not bool(_waiter.call("is_busy")) and not bool(_waiter.call("is_locked")) \
				and i > 30:
			break

	var got_close := min_goal_dist <= 20.0
	if reversals <= MAX_REVERSALS and got_close:
		_ok += 1
		print("  [OK]   %-24s 来回 %d 次（上限 %d，%d 次点击，最近离目标 %.0fpx）" % [
			label, reversals, MAX_REVERSALS, clicks, min_goal_dist])
	else:
		_bad += 1
		print("  [FAIL] %-24s 来回 %d 次（上限 %d）、最近离目标 %.0fpx（%s）" % [
			label, reversals, MAX_REVERSALS, min_goal_dist,
			"没靠近目标" if not got_close else "来回超标＝抖动"])
