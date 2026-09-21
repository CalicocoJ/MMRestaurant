extends Node
## 出餐口方块消失的像素回归测试。
##
## 用法：
##   godot --path <project> --resolution 1280x720 res://tools/check_counter.tscn
##
## 【为什么必须用像素，不能用普通断言】
## 这个 bug 是「逻辑对了，画面没跟上」：
## counter_slot 早就变空了，是**画出来的方块**没消失。
## 而 headless 模式下 _draw 只在进树时调一次，之后再也不会被调用 ——
## 所以数 _draw 次数是观测不到的。
## 唯一能证明「方块真的没了」的办法，就是把画面渲到离屏视口、
## 直接取样出餐口那几像素的颜色。

const W := 1280
const H := 720

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
	level.get_node("CustomerSpawner").set_process(false)
	for i in 10:
		await get_tree().process_frame

	var kw: Node = level.get_node("World/KitchenWindow")
	# 出餐口小矩形的中心（世界坐标）
	var centre: Vector2 = kw.to_global(kw.get("pickup_rect").get_center())
	# 【别只取一个点】餐品圆块中心有一圈半透明白描边，
	# 单点采样很容易正好落在描边上，导致「有餐」和「没餐」差得很小。
	# 所以取圆块内部一小片区域的平均色，结果稳定得多。
	var box := Rect2i(int(centre.x) - 5, int(centre.y), 11, 3)

	print("")
	print("======== 出餐口方块消失测试 ========")

	# ── 1) 空出餐口 ──
	var empty_a := await _sample(box)
	print("  1) 空出餐口       %s" % str(empty_a))

	# ── 2) 做一道汉堡放到出餐口 ──
	Game.kitchen.enqueue(["burger"] as Array[String])
	Game.kitchen.fast_forward(3.1)
	for i in 3:
		await get_tree().process_frame
	var with_food := await _sample(box)
	print("  2) 有汉堡         %s   出餐口=%s" % [
		str(with_food), Game.kitchen.counter_name()])

	# ── 3) 取走（这一步就是玩家点出餐口）──
	var taken := Game.kitchen.take_from_counter()
	for i in 3:
		await get_tree().process_frame
	var after_take := await _sample(box)
	print("  3) 取走后         %s   取出=%s 出餐口=%s" % [
		str(after_take), taken, Game.kitchen.counter_name()])

	print("")
	var fail := 0

	# 有餐时，采样区域必须和空的时候明显不同（说明方块画出来了）
	var diff_food := _dist(empty_a, with_food)
	if diff_food > 0.03:
		print("  OK  有餐时出餐口确实画出了东西（色差 %.3f）" % diff_food)
	else:
		print("  FAIL 有餐时出餐口看不出变化（色差 %.3f）" % diff_food)
		fail += 1

	# 取走后，必须回到「空」的样子 —— 这就是用户报的 bug
	var diff_after := _dist(empty_a, after_take)
	if diff_after <= 0.02:
		print("  OK  取走后方块立刻消失，画面与空出餐口一致（色差 %.3f）" % diff_after)
	else:
		print("  FAIL 取走后出餐口还留着东西（色差 %.3f）—— 方块没消失！" % diff_after)
		fail += 1

	print("===================================")
	get_tree().quit(1 if fail > 0 else 0)


func _sample(box: Rect2i) -> Color:
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	var sum := Vector3.ZERO
	var n := 0
	for x in range(box.position.x, box.position.x + box.size.x):
		for y in range(box.position.y, box.position.y + box.size.y):
			var c := img.get_pixel(x, y)
			sum += Vector3(c.r, c.g, c.b)
			n += 1
	if n == 0:
		return Color(0, 0, 0, 1)
	sum /= float(n)
	return Color(sum.x, sum.y, sum.z, 1.0)


func _dist(a: Color, b: Color) -> float:
	return maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), absf(a.b - b.b))
