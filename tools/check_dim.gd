extends Node
## 弹窗遮罩体检：在引擎内直接采样屏幕像素，判断遮罩到底盖住了哪些区域。
##
## 用法：
##   godot --path <project> --resolution 1280x720 res://tools/check_dim.tscn
##
## 【为什么要在引擎内采样】
## 截图 + 外部比图只能得到「变了 / 没变」，很难定位原因。
## 在同一个进程里，先拍一张「弹窗关闭」的基准，再打开弹窗拍一张，
## 逐点比较，就能直接列出「哪些区域被暗化了、哪些没有」，
## 从而一眼看出是图层顺序问题、尺寸问题还是 z_index 问题。

const W := 1280
const H := 720

## 采样点：(名字, 坐标) —— 覆盖各个关键区域
const POINTS := [
	["HUD 状态栏", 60, 90],
	["HUD 标题", 40, 30],
	["订单栏", 60, 260],
	["손/手上", 60, 650],
	["场景-桌1", 220, 410],
	["场景-空地", 700, 300],
	["弹窗中心", 640, 360],
	["场景-服务员", 560, 500],
]

var _vp: SubViewport


func _ready() -> void:
	await get_tree().process_frame

	_vp = SubViewport.new()
	_vp.size = Vector2i(W, H)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)

	for n in ["Stickers", "UI"]:
		var layer := get_tree().root.get_node_or_null(NodePath(n))
		if layer != null:
			get_tree().root.remove_child(layer)
			_vp.add_child(layer)

	var level: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	_vp.add_child(level)
	for i in 20:
		await get_tree().process_frame

	print("")
	print("════════ 弹窗遮罩体检 ════════")
	_report_layers()

	var before := await _shot()
	UI.open_kitchen()
	for i in 12:
		await get_tree().process_frame
	print("  KitchenPopup.visible = ", UI.kitchen_popup().visible)
	var after := await _shot()

	print("")
	print("  %-16s %-18s %-18s %s" % ["采样点", "遮罩前", "遮罩后", "结论"])
	for p in POINTS:
		var name := String(p[0])
		var x := int(p[1])
		var y := int(p[2])
		var a := before.get_pixel(x, y)
		var b := after.get_pixel(x, y)
		var la := (a.r + a.g + a.b) / 3.0
		var lb := (b.r + b.g + b.b) / 3.0
		var verdict := "未变"
		if la > 0.02:
			var ratio := lb / la
			if ratio < 0.75:
				verdict = "已暗化 (%.2f)" % ratio
			else:
				verdict = "没盖住 (%.2f)" % ratio
		print("  %-16s %-18s %-18s %s" % [name, str(a), str(b), verdict])

	print("═══════════════════════════════")
	get_tree().quit(0)


func _report_layers() -> void:
	for n in ["Stickers", "UI"]:
		var layer := _vp.get_node_or_null(NodePath(n))
		if layer == null:
			continue
		print("  %s: layer=%d" % [n, layer.layer])
		for c in layer.get_children():
			if c is CanvasLayer:
				print("    %s: layer=%d visible=%s" % [c.name, c.layer, c.visible])
	var ui := _vp.get_node_or_null("UI")
	if ui != null:
		var pop := ui.get_node_or_null("PopupLayer")
		if pop != null:
			print("    PopupLayer 子节点: ", pop.get_children())
			var pr := pop.get_node_or_null("PopupRoot")
			if pr != null:
				print("    PopupRoot: pos=%s size=%s" % [str(pr.position), str(pr.size)])
				var kp := pr.get_node_or_null("KitchenPopup")
				if kp != null:
					var dim := kp.get_node_or_null("Dim")
					print("    KitchenPopup: pos=%s size=%s visible=%s" % [
						str(kp.position), str(kp.size), kp.visible])
					if dim != null:
						print("    Dim: pos=%s size=%s visible=%s z=%d" % [
							str(dim.position), str(dim.size), dim.visible, dim.z_index])


func _shot() -> Image:
	await RenderingServer.frame_post_draw
	return _vp.get_texture().get_image()
