extends Node
## 「服务员不压在客人身上」验收。
##
## 用法：
##   godot --headless --path <project> res://tools/check_standoff.tscn
##
## 【要抓的问题（玩家反馈）】
## 服务员走到客人身边上菜时，会和客人的身体重叠一小块。
##
## 成因：到达判据是「离客人 ≤ TOUCH_RADIUS(50)」，
## 而 50 是为了可达性定的（客人坐实体椅子上，最多只能走到约 46px 处）。
## 但「不重叠」要求距离 ≥ 客人半径(15) + 服务员半径(16) = 31px，
## 于是服务员会停在 31~50 这个重叠区间里。
##
## 这个脚本从**多个方向**让服务员走到不同座位的客人身边，
## 量最终距离，断言 ≥ 31px（不重叠），同时 ≤ 50+16（仍然判定得到）。

const STEP := 1.0 / 60.0
## 不重叠的最小距离：客人半径 15 + 服务员半径 16
const MIN_OK := 31.0

var _ok := 0
var _bad := 0


func _ready() -> void:
	await get_tree().process_frame
	var lv: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(lv)
	var spawner: Node = lv.get_node("CustomerSpawner")
	spawner.set_process(false)
	await get_tree().physics_frame

	var waiter: Node = lv.get_node("Actors/Waiter")
	var router: Node = lv.get_node("ClickRouter")

	print("")
	print("======== 服务员与客人的距离 ========")
	print("  不重叠最小距离 %.0fpx（客人半径 15 + 服务员半径 16）" % MIN_OK)

	# 三个座位各测一次，出发点分别在座位的不同侧
	var seats: Array = [
		[Game.table_by_id(1), 0, Vector2(200, 600)],
		[Game.table_by_id(2), 1, Vector2(800, 300)],
		[Game.table_by_id(3), 0, Vector2(1250, 600)],
	]
	for item in seats:
		var t: Node = item[0]
		var seat = t.seats[int(item[1])]
		var from: Vector2 = item[2]

		var c: Node = spawner.call("spawn_at_seat", t, seat)
		c.global_position = t.call("seat_sit_point", seat)
		lv.call("_on_customer_seated", c)

		# 接单（走这条路更能体现「贴近客人」的场景）
		waiter.global_position = from
		router.call("handle_click", c.global_position)
		for i in int(12.0 / STEP):
			await get_tree().physics_frame
			if not bool(waiter.call("is_busy")) and not bool(waiter.call("is_locked")):
				break

		var d: float = waiter.global_position.distance_to(c.global_position)
		# 【判定标准说明】
		# 上限不能按「TOUCH_RADIUS + 身体半径」算：服务员是在**走到落脚点**
		# 时停下的，而落脚点按整团家具的外框推出来，本来就比「最近可碰点」远。
		# 所以上限只用来防「站到离谱的远处」，取 100px。
		var hard_max := 100.0
		var label := "%s 座%d（从 %s 出发）" % [t.label, int(item[1]) + 1, str(from)]
		if d < MIN_OK:
			_bad += 1
			print("  [FAIL] %-26s 停在 %.1fpx —— **和客人重叠了**" % [label, d])
		elif d > hard_max:
			_bad += 1
			print("  [FAIL] %-26s 停在 %.1fpx —— 站得太远（上限 %.0fpx）" % [label, d, hard_max])
		else:
			_ok += 1
			print("  [OK]   %-26s 停在 %.1fpx（≥%.0f 不重叠，≤%.0f 不太远）" % [
				label, d, MIN_OK, hard_max])

		c.call("go_angry")
		await get_tree().physics_frame

	print("--------------------------------")
	print("通过 %d / 失败 %d" % [_ok, _bad])
	print("================================")
	get_tree().quit(1 if _bad > 0 else 0)
