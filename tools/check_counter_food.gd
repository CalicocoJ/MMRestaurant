extends SceneTree
## 检查 counter_food.gd 能否正常工作：编译、下拉候选值、按关卡显示。
##
## 用法：
##   godot --headless --path <project> --script res://tools/check_counter_food.gd
##
## 【为什么用 root.get_node("Config") 而不是裸 Config】
## `--script` 模式下 autoload 节点**会被创建**（root 的子节点里有 Config/Game），
## 但它们**不作为全局标识符注册** —— 直接写 `Config` 会编译失败
## （`Identifier not found: Config`）。所以从场景树里取。

var _cfg: Node = null


func _initialize() -> void:
	_cfg = root.get_node_or_null("Config")
	if _cfg == null:
		print("✗ 拿不到 Config autoload")
		quit(1)
		return

	var script: Variant = load("res://scripts/world/counter_food.gd")
	if script == null:
		print("✗ counter_food.gd 加载失败")
		quit(1)
		return
	print("✓ counter_food.gd 加载成功")

	var node: Node = (script as GDScript).new()
	if node == null:
		print("✗ new() 失败")
		quit(1)
		return
	print("✓ 实例化成功，节点类型 = %s" % node.get_class())

	# 下拉候选值（_get_property_list 生成）
	var props: Array = node.call("_get_property_list")
	for p in props:
		if String(p.get("name", "")) == "item_id":
			print("✓ item_id 下拉候选 = %s" % String(p.get("hint_string", "")))

	# 接口完整性（ClickRouter 需要这几个）
	for m in ["hit_test", "accepts_click", "interact", "setup_from_editor", "collision_shapes_global"]:
		var has_it: bool = node.has_method(m)
		print("  %s %s()" % ["✓" if has_it else "✗", m])

	# 碰撞盒必须是空的（不挡人）
	var col: Rect2 = node.call("collision_box_local")
	print("  碰撞盒 = %s  %s" % [str(col), "✓ 不挡人" if col.size == Vector2.ZERO else "✗ 会挡人！"])

	# 各关卡的可用餐品（用来核对「柜台上要摆齐」）
	for lv in range(1, 6):
		var pool: Array = _cfg.call("pool_at", lv)
		print("  第 %d 关菜单池（%d 样）: %s" % [lv, pool.size(), ", ".join(pool)])

	node.free()
	quit(0)
