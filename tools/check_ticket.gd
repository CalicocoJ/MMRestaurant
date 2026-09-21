extends Node
## 订单票「划红线」规则验收。
##
## 用法：
##   godot --headless --path <project> res://tools/check_ticket.tscn
##
## 【要抓的 bug（玩家报的）】
## 客人点了 3 杯可乐、玩家只上了 1 杯，票上却已经划了红线。
##
## 文档第七节只要求「**已送达**的菜划红线」。所以正确表现是：
##   - 送了一部分 → 减数量（可乐×3 → 可乐×2），**不划线**
##   - 全部送完   → 才划线
## 这里直接断言绘制路径上的判断结果（order_lines 给出的 done 标记），
## 并且额外用像素验证「部分送达时那一行确实没有红线」。

const STEP := 1.0 / 60.0

var _ok := 0
var _bad := 0


func _ready() -> void:
	await get_tree().process_frame
	print("")
	print("======== 订单票划红线规则 ========")

	# ── 逻辑层：order_lines 的 done 标记 ──
	var o := Order.new(1, ["cola", "cola", "cola"] as Array[String])
	var lines := o.lines()
	_check(lines.size() == 1, "3 杯可乐合成一行")
	_check(int(lines[0]["total"]) == 3, "这一行 total=3")
	_check(not bool(lines[0]["done"]), "刚开始：没送完 → 不划线")

	o.deliver("cola")
	lines = o.lines()
	_check(int(lines[0]["left"]) == 2, "上了 1 杯 → 还差 2")
	_check(not bool(lines[0]["done"]), "**上了 1 杯但不能划线**（这就是那个 bug）")

	o.deliver("cola")
	lines = o.lines()
	_check(int(lines[0]["left"]) == 1, "上了 2 杯 → 还差 1")
	_check(not bool(lines[0]["done"]), "还差 1 杯 → 仍然不能划线")

	o.deliver("cola")
	lines = o.lines()
	_check(int(lines[0]["left"]) == 0, "上了 3 杯 → 还差 0")
	_check(bool(lines[0]["done"]), "全部送完 → 才划线")

	# 不同菜品：送掉一样就该划线（那样是「整道送完」）
	var o2 := Order.new(1, ["burger", "cola"] as Array[String])
	o2.deliver("burger")
	var l2 := o2.lines()
	_check(bool(l2[0]["done"]), "汉堡（单份）送完 → 划线")
	_check(not bool(l2[1]["done"]), "可乐还没送 → 不划线")

	# 混合：汉堡×2 + 可乐
	var o3 := Order.new(1, ["burger", "cola", "burger"] as Array[String])
	o3.deliver("burger")
	var l3 := o3.lines()
	_check(not bool(l3[0]["done"]), "汉堡×2 只送 1 份 → 不划线（要减数量）")
	_check(int(l3[0]["left"]) == 1, "汉堡×2 只送 1 份 → 还差 1")

	# ── 像素层：部分送达时那一行不该有红线 ──
	await _pixel_check()

	print("--------------------------------")
	print("通过 %d / 失败 %d" % [_ok, _bad])
	print("================================")
	get_tree().quit(1 if _bad > 0 else 0)


## 渲染订单栏，比较「部分送达」和「全部送达」两种情况下那一行的像素，
## 确认红线的出现时机正确。
func _pixel_check() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(1280, 720)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	for n in ["Stickers", "UI"]:
		var layer := get_tree().root.get_node_or_null(NodePath(n))
		if layer != null:
			get_tree().root.remove_child(layer)
			vp.add_child(layer)
	var level: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	vp.add_child(level)
	level.get_node("CustomerSpawner").set_process(false)
	for i in 8:
		await get_tree().process_frame

	var t: Node = Game.table_by_id(1)
	var o := Order.new(1, ["cola", "cola", "cola"] as Array[String])
	t.order = o
	Game.orders_changed.emit()
	UI.refresh_orders(Game.active_orders())
	for i in 4:
		await get_tree().process_frame

	# 票的位置：HUD 的 OrderPanel；第一行文字在票内 y≈ HEAD_H + PAD + 9 处
	var panel: Control = UI.hud.get_node_or_null("OrderPanel")
	if panel == null:
		_check(false, "找得到 OrderPanel 节点")
		return
	# order_panel.gd 里：第一张票 y=0，行文字画在 ly+9（ly = HEAD_H + PAD - 4）
	var strike_y := int(panel.position.y + 22.0 + 8.0 - 4.0 + 9.0)
	var xs := range(int(panel.position.x) + 8, int(panel.position.x) + 60)

	var before := await _count_red(vp, xs, strike_y)

	o.deliver("cola")
	Game.orders_changed.emit()
	UI.refresh_orders(Game.active_orders())
	for i in 4:
		await get_tree().process_frame
	var part := await _count_red(vp, xs, strike_y)

	o.deliver("cola")
	o.deliver("cola")
	Game.orders_changed.emit()
	UI.refresh_orders(Game.active_orders())
	for i in 4:
		await get_tree().process_frame
	var all := await _count_red(vp, xs, strike_y)

	print("      红线像素数：未送 %d / 送1杯 %d / 送完 %d" % [before, part, all])
	_check(part <= before + 1, "只送 1 杯时**没有**出现红线（像素证据）")
	_check(all > part, "全部送完时**出现了**红线（像素证据）")


func _count_red(vp: SubViewport, xs, y: int) -> int:
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	var n := 0
	for x in xs:
		if y < 0 or y >= img.get_height():
			continue
		var c := img.get_pixel(x, y)
		# COLOR_STRIKE = ff5a5a：红明显高于绿蓝
		if c.r > 0.6 and c.g < 0.55 and c.b < 0.55:
			n += 1
	return n


func _check(cond: bool, what: String) -> void:
	if cond:
		_ok += 1
		print("  [OK]   " + what)
	else:
		_bad += 1
		print("  [FAIL] " + what)
