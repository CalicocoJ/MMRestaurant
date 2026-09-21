extends Node
## 全局可达性扫描：从世界各处出发，能不能走到每一个**客人座位**。
##
## 用法：
##   godot --headless --path <project> res://tools/scan_reach.tscn
##
## 【为什么单独一个工具】
## 「走不到座位」是最致命的手感问题（表现为「点了客人没反应」），
## 而它在单点测试里很容易漏。这个工具做网格化穷举，
## 直接把「哪条走不到」列出来，比一条条试快得多。
## 之前实测 48 条里有 8~9 条失败，是寻路和窄缝问题的直接来源。

const STEP := 1.0 / 60.0


func _ready() -> void:
	await get_tree().process_frame
	var level: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(level)
	var spawner: Node = level.get_node("CustomerSpawner")
	spawner.set_process(false)
	await get_tree().physics_frame

	var waiter: Node = level.get_node("Actors/Waiter")

	# 出发网格：覆盖餐厅里玩家可能待着的位置。
	# 【注意规模】这是「座位数 × 出发点数」条路线，每条都要真跑物理帧，
	# 点数给多了会跑成十几分钟。12 个点 × 6 个座位 = 72 条，够说明问题。
	var origins: Array = [
		Vector2(200, 250), Vector2(600, 250), Vector2(1000, 250),
		Vector2(200, 550), Vector2(600, 550), Vector2(1000, 550),
		Vector2(140, 400), Vector2(1150, 400),
		Vector2(420, 480), Vector2(760, 480), Vector2(560, 620), Vector2(300, 660),
	]

	print("")
	print("======== 座位可达性扫描 ========")
	var bad := 0
	var total := 0
	var fails: PackedStringArray = []
	for t in Game.tables:
		for si in t.seat_count():
			var seat = t.seats[si]
			var sit: Vector2 = t.call("seat_sit_point", seat)
			var cust: Node = spawner.call("spawn_at_seat", t, seat)
			cust.global_position = sit
			for o in origins:
				total += 1
				waiter.global_position = o
				var hit := [false]
				var cb := func() -> bool:
					hit[0] = true
					return true
				waiter.call("command_move", sit, cb, "scan", cust)
				await _settle(waiter, 5.0)
				if not hit[0]:
					bad += 1
					fails.append("%s 座%d 从 %s" % [t.label, si + 1, str(o)])
			# 清掉这位客人，好测下一个座位
			cust.call("go_angry")
			cust.queue_free()
			await get_tree().physics_frame

	print("  失败 %d / 共 %d 条路线" % [bad, total])
	for f in fails:
		print("    - " + f)
	print("================================")
	get_tree().quit(1 if bad > 0 else 0)


func _settle(waiter: Node, seconds: float) -> void:
	var n := int(seconds / STEP)
	for i in n:
		await get_tree().physics_frame
		if not bool(waiter.call("is_busy")) and not bool(waiter.call("is_locked")):
			return
