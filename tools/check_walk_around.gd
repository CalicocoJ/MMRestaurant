extends Node
## 专门验证玩家反馈：「点空地时撞到桌子不会自己绕开」。
##
## 用法：
##   godot --headless --path <project> res://tools/check_walk_around.tscn
##
## 做法：把服务员放在桌子右边，点桌子左边的空地。
## 直线过去必然撞桌子；会寻路就应该绕过去。

const STEP := 1.0 / 60.0

var _bad := 0
var _ok := 0


func _ready() -> void:
	await get_tree().process_frame
	var level: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(level)
	level.get_node("CustomerSpawner").set_process(false)
	await get_tree().physics_frame

	var waiter: Node = level.get_node("Actors/Waiter")
	var router: Node = level.get_node("ClickRouter")

	print("")
	print("======== 点空地绕行测试 ========")

	# 几组：起点 → 点的空地。都在家具的另一侧。
	# 【坐标要跟着 layout.json 走】桌子挪过位置，写死的旧坐标会失效，
	# 所以这里按新布局（桌1 x=270、桌2 x=640、桌3 x=1010，y=440）来取点。
	var cases := [
		["桌1 右侧 → 桌1 左边空地", Vector2(430, 470), Vector2(210, 470)],
		["桌2 下方 → 桌2 上方空地", Vector2(680, 580), Vector2(680, 280)],
		["桌3 右侧 → 桌3 左边空地", Vector2(1170, 470), Vector2(930, 470)],
		["右边 → 桌2/桌3 之间空位", Vector2(1150, 560), Vector2(860, 560)],
		["左下 → 桌子右上方", Vector2(150, 600), Vector2(900, 250)],
	]

	for c in cases:
		var name: String = c[0]
		var from: Vector2 = c[1]
		var to: Vector2 = c[2]

		waiter.global_position = from
		var pf0: Node = get_tree().get_first_node_in_group("pathfinder")
		var raw_path: Array = pf0.call("find_path", from, to) if pf0 != null else []
		router.call("handle_click", to)      # 点空地：player 真的会走的那条路
		var wps: Array = waiter.get("_waypoints")
		print("  --- %s" % name)
		print("      A*原始: %s" % str(raw_path))
		print("      实际走: %s" % str(wps))

		# 一边走一边量「身体离最近的家具还有多远」，以及走了多长
		var min_clear: float = INF
		var travelled := 0.0
		var prev: Vector2 = waiter.global_position
		for i in int(12.0 / STEP):
			await get_tree().physics_frame
			var p: Vector2 = waiter.global_position
			travelled += p.distance_to(prev)
			prev = p
			for tb in Game.tables:
				var d: float = p.distance_to(
					EntityBase.nearest_point_on_rect(tb.call("collision_rect_global"), p))
				min_clear = minf(min_clear, d)
			if not bool(waiter.call("is_busy")) and not bool(waiter.call("is_locked")):
				break

		var dist: float = waiter.global_position.distance_to(to)
		var straight: float = from.distance_to(to)

		var verdict := dist <= 24.0
		if verdict:
			_ok += 1
			print("  [OK]   %-24s 残差 %.1fpx  最近离桌 %.1fpx  走了 %.0fpx（直线 %.0fpx）" % [
				name, dist, min_clear, travelled, straight])
			# 身体半径 16：最近距离不该小于 15（否则就是「体积重叠」）
			if min_clear < 15.0:
				_bad += 1
				print("         [FAIL] 擦到桌子了：最近只有 %.1fpx（身体半径 16）" % min_clear)
			else:
				_ok += 1
		else:
			_bad += 1
			var pf: Node = get_tree().get_first_node_in_group("pathfinder")
			var dbg := []
			if pf != null:
				dbg = pf.call("find_path", from, to)
			print("  [FAIL] %-24s 停在 %s，离目标 %.1fpx（应该走到 %s）" % [
				name, str(waiter.global_position), dist, str(to)])
			print("         路径=%s" % str(dbg))

	# 判定标准：终点误差在 24px 内算「走到了」
	# （贴边滑动会有几个像素残差，这是正常的）
	print("--------------------------------")
	print("通过 %d / 失败 %d" % [_ok, _bad])
	print("================================")
	get_tree().quit(1 if _bad > 0 else 0)


## 等指令结束；返回是否结束（false = 超时）
func _settle(waiter: Node, seconds: float) -> bool:
	var n := int(seconds / STEP)
	for i in n:
		await get_tree().physics_frame
		if not bool(waiter.call("is_busy")) and not bool(waiter.call("is_locked")):
			return true
	return false
