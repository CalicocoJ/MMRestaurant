extends SceneTree
## 把 main.tscn 实例化后的**完整节点树**打出来，用来区分
## 「编辑器摆放的节点」和「代码生成的节点」。
##
## 用法：
##   godot --headless --path <project> --script res://tools/dump_runtime_tree.gd


func _initialize() -> void:
	var scene: Variant = load("res://scenes/main.tscn")
	if scene == null:
		print("✗ main.tscn 加载失败")
		quit(1)
		return
	var level: Node = (scene as PackedScene).instantiate()
	root.add_child(level)
	for i in 3:
		await process_frame
	print("\n=== 运行时完整节点树 ===")
	_walk(level, 0)

	# ── 占位美术开关检查 ────────────────────────────────────────────
	# `draw_placeholder` 默认开着时，代码画的色块会和 Sprite2D 叠画，
	# 而编辑器里看不出来（_draw() 在编辑器走参考线分支）——
	# 只有 F5 才暴露。所以这里逐个报一遍，免得再靠肉眼看截图猜。
	print("\n=== 占位美术开关（true = 会画代码色块）===")
	var bad := 0
	var world := level.get_node_or_null("World")
	if world != null:
		for child in world.get_children():
			_check_placeholder(child, "  ", [bad])
			for sub in child.get_children():
				if sub is Node2D and sub.get("draw_placeholder") != null:
					_check_placeholder(sub, "    ", [bad])
	print("  有贴图却仍开着占位色块的节点数：%d" % bad)
	quit(0)


func _check_placeholder(node: Node, indent: String, bad: Array) -> void:
	var v: Variant = node.get("draw_placeholder")
	if typeof(v) != TYPE_BOOL:
		return
	var has_sprite := false
	for c in node.get_children():
		if c is Sprite2D and (c as Sprite2D).texture != null:
			has_sprite = true
	var on := bool(v)
	var tag := ""
	if on and has_sprite:
		tag = "   ✗ 有贴图却还开着 → 色块会盖住贴图"
		bad[0] = int(bad[0]) + 1
	elif on:
		tag = "   （没有贴图，画色块是对的）"
	print("%s%s draw_placeholder=%s%s" % [indent, node.name, str(on), tag])


func _walk(node: Node, depth: int) -> void:
	var indent := "  ".repeat(depth)
	var k: Variant = node.get("kind")
	var extra := ""
	if k != null:
		extra += "  kind=%s" % str(k)
	var scr: Variant = node.get_script()
	if scr != null:
		extra += "  script=%s" % String((scr as Script).resource_path).get_file()
	if node is Node2D:
		extra += "  pos=%s" % str((node as Node2D).position)
	if not node.visible:
		extra += "  [隐藏]"
	print("%s%s (%s)%s" % [indent, node.name, node.get_class(), extra])
	for child in node.get_children():
		_walk(child, depth + 1)
