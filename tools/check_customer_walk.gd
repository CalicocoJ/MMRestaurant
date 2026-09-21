extends Node
## 「客人不从桌子上走过去」验收。
##
## 用法：
##   godot --headless --path <project> res://tools/check_customer_walk.tscn
##
## 【要抓的 bug（玩家反馈）】
## 客人从门口走向座位时会**从桌面上穿过去**。
## 成因：座位分左右两侧，左侧座位在桌子的「背面」，
## 从门口直线过去必然穿过桌子。
##
## 判定标准（用**真实碰撞盒**量，不用肉眼看）：
## 客人身体（半径 15）在整个走位过程中，与任一桌子的**桌面碰撞盒**
## 都不该重叠 —— 即中心到桌面矩形的距离应 ≥ 15px。
##
## 注意：和**椅子**重叠是正常的（客人本来就坐在椅子上），所以只查桌面。

const STEP := 1.0 / 60.0
const BODY_R := 15.0

var _ok := 0
var _bad := 0


func _ready() -> void:
	await get_tree().process_frame
	var lv: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(lv)
	var spawner: Node = lv.get_node("CustomerSpawner")
	spawner.set_process(false)
	await get_tree().physics_frame

	print("")
	print("======== 客人走向座位：会不会穿过桌子 ========")

	# 每个座位都测：从门口走到座位，全程采样
	for t in Game.tables:
		for si in t.seat_count():
			var seat = t.seats[si]
			var sit: Vector2 = t.call("seat_sit_point", seat)
			var c: Node = spawner.call("spawn_at_seat", t, seat)
			var from: Vector2 = Door.spawn_point()
			# 【注意】必须在 add_child 之后设位置：客人的 _ready 会重置位置
			# 并按当时的位置算路径（见 customer.gd 里的时机说明）。
			# spawn_at_seat 内部已经按门口位置 setup 好了，这里不用再动。
			# 位置以 setup 时传入的 from 为准。

			# 逐帧推进，采样「离桌面最近的距离」，并记下侵入桌面的帧
			var min_hit := INF
			var frames := 0
			var hits: PackedStringArray = []
			while frames < int(20.0 / STEP):
				frames += 1
				c.call("_process", STEP)
				var p: Vector2 = c.global_position
				for tb in Game.tables:
					var shapes: Array = tb.call("collision_shapes_global")
					if shapes.is_empty():
						continue
					var d: float = p.distance_to(
						EntityBase.nearest_point_on_rect(shapes[0], p))
					if d < min_hit:
						min_hit = d
					if d < BODY_R and hits.size() < 3:
						hits.append("f%d pos=%s 离%s=%.1f" % [frames, str(p), tb.label, d])
				if int(c.get("state")) != Constants.State.WALKING_IN:
					break

			var arrived: bool = c.global_position.distance_to(sit) <= 2.0
			var label := "%s 座%d" % [t.label, si + 1]
			# 客人身体半径 15px：中心离桌面 < 15 就算压上去了。
			if min_hit >= BODY_R:
				_ok += 1
				print("  [OK]   %-8s 全程离桌面最近 %.1fpx → 没穿桌子" % [label, min_hit])
			else:
				_bad += 1
				print("  [FAIL] %-8s 最近只离桌面 %.1fpx → 穿桌子了" % [label, min_hit])
				print("         座位=%s 停=%s 走了%d帧" % [str(sit), str(c.global_position), frames])
				for h in hits:
					print("         " + h)
			if arrived:
				_ok += 1
			else:
				_bad += 1
				print("         [FAIL] 没走到座位：停放 %s，座位 %s" % [
					str(c.global_position), str(sit)])

			c.call("go_angry")
			c.queue_free()
			await get_tree().physics_frame

	print("--------------------------------")
	print("通过 %d / 失败 %d" % [_ok, _bad])
	print("================================")
	get_tree().quit(1 if _bad > 0 else 0)
