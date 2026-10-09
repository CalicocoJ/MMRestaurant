extends SceneTree
## 探测：在 `--script` 模式下，autoload（Config / Game）到底存不存在？


func _initialize() -> void:
	print("root = %s" % str(root))
	var names: Array[String] = []
	for c in root.get_children():
		names.append(c.name)
	print("root 的子节点: %s" % (", ".join(names) if not names.is_empty() else "（空）"))
	print("Config = %s" % str(root.get_node_or_null("Config")))
	print("Game   = %s" % str(root.get_node_or_null("Game")))
	print("current_scene = %s" % str(current_scene))
	quit(0)
