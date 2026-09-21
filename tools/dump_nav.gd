extends Node
## 导航网格体检：把网格打印出来，确认障碍（尤其是桌子+椅子）标对了。
##
## 用法：
##   godot --headless --path <project> res://tools/dump_nav.tscn
##
## 【为什么必须这一步】
## 之前我在网格里做「窄缝填充」，加完没验证就继续改别的，
## 结果那条失败路线依旧从缝里走 —— 白忙一轮。
## 网格是纯数据，直接打出来看最快，不该靠推测。

const STEP := 1.0 / 60.0


func _ready() -> void:
	await get_tree().process_frame
	var level: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(level)
	level.get_node("CustomerSpawner").set_process(false)
	await get_tree().physics_frame

	var pf: Node = level.get_node_or_null("Pathfinder")
	print("")
	print("======== 导航网格 ========")
	if pf == null:
		print("没有 Pathfinder 节点！")
		get_tree().quit(1)
		return

	# 1) 每件家具喂给寻路的矩形
	print("-- 家具尺寸 / 标签是否放得下 --")
	var world: Node = level.get_node("World")
	var font: Font = UiFont.get_font()
	for child in world.get_children():
		var box: Rect2 = child.call("nav_rect_global")
		var lbl := String(child.get("label"))
		var need := 0.0
		if font != null and lbl != "":
			need = font.get_string_size(lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		var avail: float = box.size.x - 8.0
		var okk := "OK" if need <= avail else "放不下（会换行/竖排）"
		print("  %-14s 宽 %.0f  标签「%s」需 %.0f  可用 %.0f  → %s" % [
			String(child.name), box.size.x, lbl, need, avail, okk])

	# 2) 桌3 一带的网格（原来那条失败路线走的 x=870 缝就在这里）
	print("")
	print("-- 桌3 一带网格（# = 不可通行，. = 可走）--")
	print(pf.call("dump_region", Vector2(820, 340), Vector2(1060, 480)))

	# 3) 直接问：从那条失败路线的起点，路径怎么走
	print("")
	print("-- 路径：左下 → 桌子右上方 --")
	print("  " + str(pf.call("find_path", Vector2(150, 600), Vector2(1000, 250))))

	get_tree().quit(0)
