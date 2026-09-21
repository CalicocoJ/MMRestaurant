extends Node
## UI 布局体检：把每个 Control 的真实屏幕矩形打出来。
##
## 用法：
##   godot --path <project> --resolution 1280x720 res://tools/dump_ui.tscn
##
## 【为什么需要它】
## Control 的锚点 / 容器布局是「声明式」的，肉眼看代码很难判断
## 某个标签最后落在哪 —— 尤其 nested container + 手写 position 混用的时候。
## 直接打印 get_global_rect()，一眼就能看出「跑到屏幕外面去了」。
## 「手上：空手」那次就是这么发现的：它安静地待在了 y≈722，
## 刚好在 720 高的视口下方一像素 —— 不报错、不警告，就是看不见。

const W := 1280
const H := 720


func _ready() -> void:
	await get_tree().process_frame

	var vp := SubViewport.new()
	vp.size = Vector2i(W, H)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)

	for autoload_name in ["Stickers", "UI"]:
		var layer := get_tree().root.get_node_or_null(NodePath(autoload_name))
		if layer != null:
			get_tree().root.remove_child(layer)
			vp.add_child(layer)

	var level: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	vp.add_child(level)

	# 推进几帧，让容器完成布局
	for i in 12:
		await get_tree().process_frame
	# 触发一次 HUD 刷新
	_walk(level, "_process", 1.0 / 60.0)
	for i in 4:
		await get_tree().process_frame

	# 可选：把弹窗打开，检查它们的定位
	var argv := OS.get_cmdline_user_args()
	if argv.size() > 0 and String(argv[0]) == "popups":
		UI.open_kitchen()
		for i in 10:
			await get_tree().process_frame
		print("")
		print("════════ 后厨弹窗打开后 ════════")
		_dump(UI.kitchen_popup(), 0)
		UI.close_popups()
		UI.open_drink_machine()
		for i in 10:
			await get_tree().process_frame
		print("")
		print("════════ 饮料机弹窗打开后 ════════")
		_dump(UI.drink_popup(), 0)
		UI.close_popups()
	print("")
	print("════════ CanvasLayer 图层顺序 ════════")
	_dump_layers(vp)
	print("")
	print("════════ UI 布局体检（视口 %dx%d）════════" % [W, H])
	_dump(UI, 0)
	print("════════════════════════════════════════")
	get_tree().quit(0)


func _dump_layers(node: Node, depth: int = 0) -> void:
	if node is CanvasLayer:
		var cl: CanvasLayer = node
		print("%s%-18s layer=%d vis=%s" % [
			"  ".repeat(depth), String(cl.name), cl.layer, str(cl.visible)])
	for c in node.get_children():
		_dump_layers(c, depth + 1)


func _walk(node: Node, method: String, delta: float) -> void:
	if node.has_method(method):
		node.call(method, delta)
	for c in node.get_children():
		_walk(c, method, delta)


func _dump(node: Node, depth: int) -> void:
	if node is Control:
		var c: Control = node
		var r := c.get_global_rect()
		var flags := ""
		if r.position.y + r.size.y > float(H) + 0.5 or r.position.y < -0.5 \
				or r.position.x < -0.5 or r.position.x + r.size.x > float(W) + 0.5:
			flags = "   <== 超出视口！"
		var extra := ""
		if c is Label and (c as Label).text != "":
			extra = "  text=\"%s\"" % (c as Label).text
		print("%s%-22s %-18s pos=(%6.1f,%6.1f) size=(%6.1f,%6.1f) vis=%s%s%s" % [
			"  ".repeat(depth), String(c.name), c.get_class(),
			r.position.x, r.position.y, r.size.x, r.size.y,
			str(c.is_visible_in_tree()), extra, flags])
	for child in node.get_children():
		_dump(child, depth + 1)
