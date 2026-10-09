extends SceneTree
## 读 main.tscn，把**实际运行时的场景结构**打印出来。
##
## 【为什么需要它】main.tscn 是文本格式，但 `tile_map_data` 之类字段是打包的
## 二进制（base64），靠肉眼/正则解析容易猜错格式。让引擎自己实例化一遍、
## 读它内存里的真实数据，才是最可靠的。
##
## 用法：
##   godot --headless --path <project> --script res://tools/report_scene.gd
##
## 【注意】这里**不设** force_generated_layout —— 目的正是看「设计场景本身」。


func _initialize() -> void:
	var packed := load("res://scenes/main.tscn") as PackedScene
	if packed == null:
		print("无法加载 main.tscn")
		quit(1)
		return
	var lv: Node = packed.instantiate()
	root.add_child(lv)

	print("")
	print("========== 设计场景结构 ==========")
	_dump(lv, 0)

	print("")
	print("========== 地板（TileMapLayer）==========")
	for c in lv.get_children():
		if c is TileMapLayer:
			_dump_tilemap(c)

	print("")
	print("========== 家具几何（World 下的节点）==========")
	var world := lv.get_node_or_null("World")
	if world != null:
		for child in world.get_children():
			_dump_furniture(child)
	else:
		print("  没有 World 节点！")

	print("")
	print("========== 自绑定检查（会报出沉默失效的地方）==========")
	_check_binding(lv)

	quit(0)


## 打印节点树（只到两层，带位置/脚本/size）
func _dump(n: Node, depth: int) -> void:
	var pad: String = "  ".repeat(depth)
	var extra: String = ""
	if n is Node2D:
		extra += "  pos=%s" % str((n as Node2D).position)
	if n is Sprite2D:
		var sp := n as Sprite2D
		var ts: Vector2 = Vector2.ZERO
		if sp.texture != null:
			ts = sp.texture.get_size()
		extra += "  centered=%s offset=%s 贴图尺寸=%s" % [str(sp.centered), str(sp.offset), str(ts)]
	var scr: Variant = n.get_script()
	var scrName: String = "无脚本"
	if scr != null:
		scrName = str((scr as Script).resource_path).get_file()
	var exported: String = ""
	if "rect_size" in n:
		exported = "  rect_size=%s" % str(n.get("rect_size"))
	print("%s%s (%s)  脚本=%s%s%s" % [pad, n.name, n.get_class(), scrName, extra, exported])
	for c in n.get_children():
		if depth < 3:
			_dump(c, depth + 1)


func _dump_tilemap(tm: TileMapLayer) -> void:
	var cells: Array = tm.get_used_cells()
	print("  节点名: %s" % tm.name)
	print("  tile_set: %s" % ("已设置" if tm.tile_set != null else "**未设置！**"))
	print("  已铺格子数: %d" % cells.size())
	if cells.is_empty():
		print("  （一格都没有）")
		return
	var minX: int = 1 << 30
	var maxX: int = -(1 << 30)
	var minY: int = 1 << 30
	var maxY: int = -(1 << 30)
	for cell in cells:
		var c: Vector2i = cell
		minX = mini(minX, c.x)
		maxX = maxi(maxX, c.x)
		minY = mini(minY, c.y)
		maxY = maxi(maxY, c.y)
	print("  格子范围: x %d..%d  y %d..%d  ->  %d x %d 格" % [
		minX, maxX, minY, maxY, maxX - minX + 1, maxY - minY + 1])
	if tm.tile_set != null:
		var ts := tm.tile_set.tile_size
		print("  图块尺寸: %s  ->  像素范围: x %d..%d  y %d..%d  ->  %d x %d 像素" % [
			str(ts),
			minX * int(ts.x), (maxX + 1) * int(ts.x),
			minY * int(ts.y), (maxY + 1) * int(ts.y),
			(maxX - minX + 1) * int(ts.x), (maxY - minY + 1) * int(ts.y)])
	# 形状图
	print("  形状（# = 有格子）:")
	for y in range(minY, maxY + 1):
		var line := "%4d |" % y
		for x in range(minX, maxX + 1):
			var probe := Vector2i(x, y)
			line += "#" if cells.has(probe) else "."
		print(line)


func _dump_furniture(n: Node) -> void:
	print("  --- %s ---" % n.name)
	if "kind" in n:
		print("      kind = %d" % int(n.get("kind")))
	else:
		print("      **没有 kind 字段 —— 不是家具脚本！**")
	if "rect_size" in n:
		print("      rect_size = %s" % str(n.get("rect_size")))
	if "walk_offset" in n:
		print("      walk_offset = %s" % str(n.get("walk_offset")))
	if "spawn_offset" in n:
		print("      spawn_offset = %s" % str(n.get("spawn_offset")))
	# 贴图实际画在哪（和 rect 对比，查出「贴图和碰撞盒错位」）
	for c in n.get_children():
		if c is Sprite2D:
			var sp := c as Sprite2D
			if sp.texture == null:
				print("      Sprite2D(%s): **没有贴图**" % sp.name)
				continue
			var ts: Vector2 = sp.texture.get_size()
			var half: Vector2 = ts * 0.5
			var left: float = sp.position.x + sp.offset.x - (half.x if sp.centered else 0.0)
			var top: float = sp.position.y + sp.offset.y - (half.y if sp.centered else 0.0)
			print("      Sprite2D(%s): 贴图 %s  实际画在 (%.0f, %.0f)~(%.0f, %.0f)" % [
				sp.name, str(ts), left, top, left + ts.x, top + ts.y])
			if "rect_size" in n:
				var rs: Vector2 = n.get("rect_size")
				if absf(left) > 0.5 or absf(top) > 0.5:
					print("        **错位警告**：碰撞盒/点击范围是 (0,0)~(%d,%d)，和贴图差了 (%d, %d)" % [
						int(rs.x), int(rs.y), int(left), int(top)])
	# 座位
	var chairs: Array = []
	for c in n.get_children():
		var s: Variant = c.get_script()
		if s != null and str((s as Script).resource_path).ends_with("chair.gd"):
			chairs.append(c)
	if not chairs.is_empty():
		print("      椅子 %d 把:" % chairs.size())
		for ch in chairs:
			var line := "         %s pos=%s back=%s" % [ch.name, str(ch.position), str(ch.get("back"))]
			# 【必须算上 Sprite2D 的 position/offset】椅子本体画在哪，取决于
			# 子 Sprite2D 的变换；只看 Chair 自己的 position 会算错位置，
			# 得出「碰撞盒和椅子差很远」这种假警告。
			for g in ch.get_children():
				if g is Sprite2D and (g as Sprite2D).texture != null:
					var sp2 := g as Sprite2D
					var ts2: Vector2 = sp2.texture.get_size()
					var half2: Vector2 = ts2 * 0.5
					var l2: float = sp2.position.x + sp2.offset.x - (half2.x if sp2.centered else 0.0)
					var t2: float = sp2.position.y + sp2.offset.y - (half2.y if sp2.centered else 0.0)
					line += "  贴图(%.0f,%.0f)~(%.0f,%.0f)" % [l2, t2, l2 + ts2.x, t2 + ts2.y]
					break
			print(line)
	elif "table_id" in n:
		print("      **有 table_id（是桌子）但没有任何挂 chair.gd 的椅子**")


func _check_binding(lv: Node) -> void:
	var world := lv.get_node_or_null("World")
	if world == null:
		print("  ✗ 没有 World 节点 —— 家具不会生效")
		return
	var n := 0
	for child in world.get_children():
		var has_setup: bool = child.has_method("setup_from_editor")
		var has_kind: bool = "kind" in child
		var ok := has_setup and has_kind
		print("  %s %s  脚本=%s  setup_from_editor=%s  kind=%s" % [
			"✓" if ok else "✗", child.name,
			"有" if child.get_script() != null else "**无**",
			"有" if has_setup else "**无**",
			"有" if has_kind else "**无**"])
		if not ok:
			n += 1
	if n == 0:
		print("  全部家具都能被正确绑定 ✓")
	else:
		print("  有 %d 个节点不会被绑定（点了没反应、不挡人、也不报错）" % n)
