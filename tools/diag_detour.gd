extends Node
## 寻路外扩量取舍诊断：外扩小 → 贴得近（体积可能重叠）；外扩大 → 绕远路。
## 这个脚本扫几个值，把「绕路比」和「路径离家具最近距离」列出来，用来选值。
##
## 用法：
##   godot --headless --path <project> res://tools/diag_detour.tscn

func _ready() -> void:
	await get_tree().process_frame
	var lv: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(lv)
	lv.get_node("CustomerSpawner").set_process(false)
	await get_tree().physics_frame

	var pf: Node = lv.get_node("Pathfinder")
	var obstacles := _obstacles(lv)
	var cases := [
		["桌1右→桌1左", Vector2(340, 410), Vector2(120, 410)],
		["左下→右上", Vector2(150, 600), Vector2(1000, 250)],
		["桌2下→桌2上", Vector2(600, 520), Vector2(600, 220)],
		["桌3右→桌3左", Vector2(1060, 410), Vector2(820, 410)],
	]

	print("")
	print("===== 外扩量对比 =====")
	print("  外扩   各路线绕路比                       最差   路径离家具最近")
	for inflate in [0.0, 4.0, 8.0, 12.0, 18.0]:
		pf.call("build", obstacles, inflate)
		var worst := 0.0
		var minclear: float = INF
		var parts: PackedStringArray = []
		for c in cases:
			var from: Vector2 = c[1]
			var to: Vector2 = c[2]
			var pts: Array = pf.call("find_path", from, to)
			var prev := from
			var total := 0.0
			for p in pts:
				total += prev.distance_to(p)
				prev = p
			var ratio := total / from.distance_to(to)
			worst = maxf(worst, ratio)
			parts.append("%.2f" % ratio)
			# 沿这条路径采样，量离家具（真实碰撞盒）最近能到多少
			for i in pts.size():
				var a: Vector2 = (from if i == 0 else pts[i - 1])
				var b: Vector2 = pts[i]
				for k in 21:
					var p: Vector2 = a.lerp(b, float(k) / 20.0)
					for tb in Game.tables:
						minclear = minf(minclear, p.distance_to(
							EntityBase.nearest_point_on_rect(
								tb.call("collision_rect_global"), p)))
		print("  %5.1f  [%s]  %.2f   %.1fpx" % [
			inflate, ", ".join(parts) + "        ", worst, minclear])

	print("")
	print("说明：服务员身体半径 16px。第三列若小于 16 就是「体积重叠」。")
	get_tree().quit(0)


func _obstacles(lv: Node) -> Array:
	var out: Array = []
	for child in lv.get_node("World").get_children():
		if child.has_method("nav_rect_global"):
			var b: Rect2 = child.call("nav_rect_global")
			if b.size.x > 0.0 and b.size.y > 0.0:
				out.append(b)
	return out
