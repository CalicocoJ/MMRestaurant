extends Node
## 移动回归：把每个可交互物件的 walk_to 都走一遍，确认「还能走到」。
##
## 用法：
##   godot --headless --path <project> res://tools/check_routes.tscn
##
## 【为什么需要它】布局（layout.json）是数据，改坐标很容易把某件家具的
## 站位推到碰撞盒里面去，表现就是「点了没反应」。
## 这个脚本把每件家具的 walk_to 从服务员出生点真走一遍，逐个报告。

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
	var world: Node = lv.get_node("World")
	var spawn: Vector2 = Vector2(560, 500)

	print("")
	print("======== 各物件站位可达性 ========")
	for child in world.get_children():
		if child.kind == Constants.Kind.DOOR:
			continue          # 门口不挡人，站位概念不适用
		var name := String(child.name)
		var point: Vector2 = child.call("walk_to")
		waiter.global_position = spawn
		var arrived := [false]
		var cb := func() -> bool:
			arrived[0] = true
			return true
		waiter.call("command_move", point, cb, "走 " + name)
		await _settle(waiter, 10.0)
		var d: float = waiter.global_position.distance_to(point)
		if arrived[0]:
			_ok += 1
			print("  [OK]   %-14s 到达（停位距目标 %.1fpx）" % [name, d])
		else:
			_bad += 1
			print("  [FAIL] %-14s 没到达：停在 %s，目标 %s（差 %.1fpx）" % [
				name, _v(waiter.global_position), _v(point), d])

	# 再验一遍「从后厨能走回桌子」
	var t1: Node = Game.table_by_id(1)
	waiter.global_position = Vector2(540, 250)
	var hit2 := [false]
	var cb2 := func() -> bool:
		hit2[0] = true
		return true
	waiter.call("command_move", t1.call("walk_to"), cb2, "回桌1", t1)
	await _settle(waiter, 10.0)
	if hit2[0]:
		_ok += 1
		print("  [OK]   %-14s 从后厨能走回桌子" % "后厨→桌1")
	else:
		_bad += 1
		print("  [FAIL] %-14s 从后厨走不回桌子：停在 %s" % [
			"后厨→桌1", _v(waiter.global_position)])

	print("--------------------------------")
	print("通过 %d / 失败 %d" % [_ok, _bad])
	print("================================")
	get_tree().quit(1 if _bad > 0 else 0)


func _settle(waiter: Node, seconds: float) -> void:
	for i in int(seconds / STEP):
		await get_tree().physics_frame
		if not bool(waiter.call("is_busy")) and not bool(waiter.call("is_locked")):
			return


func _v(p: Vector2) -> String:
	return "(%.0f,%.0f)" % [p.x, p.y]
