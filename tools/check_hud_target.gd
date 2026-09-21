extends Node
## 顶部「关卡目标栏」体检：位置、尺寸、不压家具、星星点亮逻辑。

var _ok := 0
var _bad := 0


func _ready() -> void:
	await get_tree().process_frame
	var lv: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(lv)
	lv.get_node("CustomerSpawner").set_process(false)
	for i in 5:
		await get_tree().physics_frame

	print("")
	print("======== 顶部目标栏体检 ========")
	var bar: Control = _find(UI, "TargetBar")
	if bar == null:
		_bad += 1
		print("  [FAIL] 找不到 TargetBar 节点")
		get_tree().quit(1)
		return
	print("  目标栏 rect = (%.0f,%.0f %.0fx%.0f)" % [
		bar.position.x, bar.position.y, bar.size.x, bar.size.y])

	# ① 水平居中（屏幕宽 1280）
	var cx: float = bar.position.x + bar.size.x * 0.5
	_check(absf(cx - 640.0) <= 12.0, "水平居中：中心 x=%.0f（屏幕中心 640）" % cx)

	# ② 不压后厨（它的点击框从 y=96 开始）与饮料机
	_check(bar.position.y + bar.size.y <= 96.0,
		"整块收在后厨上沿（y=96）以上：底边 y=%.0f" % (bar.position.y + bar.size.y))
	_check(bar.position.x + bar.size.x <= 735.0,
		"不撞到饮料机（x=735 起）：右边界 x=%.0f" % (bar.position.x + bar.size.x))
	_check(bar.position.y >= 0.0, "没有跑出屏幕上方：顶边 y=%.0f" % bar.position.y)

	# ③ 不吃鼠标（否则顶部中间的场地就点不动了）
	_check(bar.mouse_filter == Control.MOUSE_FILTER_IGNORE, "目标栏不吃鼠标事件（可点场景）")

	# ④ 三星 + 数字：按 1★→3★ 排，金额递增
	var texts: Array = []
	for l in _collect_labels(bar, [], "num"):
		texts.append(String(l.text))
	print("  星下面的数字：%s" % str(texts))
	var g1 := int(Game.star_target(1))
	var g2 := int(Game.star_target(2))
	var g3 := int(Game.star_target(3))
	_check(texts.size() == 3 and texts[0] == "0/%d" % g1 and texts[1] == "0/%d" % g2
		and texts[2] == "0/%d" % g3,
		"三档目标按 1★→3★ 显示：%s（本关 %d/%d/%d）" % [str(texts), g1, g2, g3])
	_check(g1 < g2 and g2 < g3, "金额从左到右递增：%d < %d < %d" % [g1, g2, g3])

	# ⑤ 点亮逻辑：0 元 → 全暗；到 1★ → 只亮第一颗；到 3★ → 全亮
	var stars: Array = _collect_stars(bar)
	_check(stars.size() == 3, "找到三颗星控件（实际 %d）" % stars.size())
	if stars.size() == 3:
		Game.money = 0
		_pump(lv)
		_check(not bool(stars[0].get("lit")) and not bool(stars[2].get("lit")),
			"0 元：三颗星全暗")
		Game.money = g1
		_pump(lv)
		_check(bool(stars[0].get("lit")) and not bool(stars[1].get("lit")),
			"到 1★（%d 元）：只亮第一颗" % g1)
		Game.money = g3
		_pump(lv)
		_check(bool(stars[2].get("lit")) and bool(stars[1].get("lit")),
			"到 3★（%d 元）：三颗全亮" % g3)
		var t3: Array = []
		for l in _collect_labels(bar):
			t3.append(String(l.text))
		_check(t3[0] == "%d/%d" % [g1, g1], "数字显示改为「当前/目标」：%s" % str(t3))

	# ⑥ 左上角不再有重复的星级文字行
	var dup := 0
	for l in _collect_labels(UI):
		if String(l.text).begins_with("★"):
			dup += 1
	_check(dup == 0, "左上角没有残留的「★3 …」旧文字行（找到 %d 个）" % dup)

	# ⑦ 七行状态已按玩家要求删除，左上角只剩「第 N 关 · 倒计时 · 钱」
	var banned := ["钱：", "已接待人数", "空桌数", "待收拾数", "在店人数", "出餐口：", "后厨队列"]
	var leftovers: Array = []
	for l in _collect_labels(UI):
		var t := String(l.text)
		for b in banned:
			if t.begins_with(String(b)):
				leftovers.append(t)
	print("  左上角剩下的文字：%s" % str(_left_texts(bar)))
	_check(leftovers.is_empty(), "七行状态栏数据已从 HUD 删除（残留 %s）" % str(leftovers))
	var level_text := ""
	for l in _collect_labels(UI):
		if String(l.text).begins_with("第 ") and String(l.text).contains("关"):
			level_text = String(l.text)
			break
	_check(level_text != "", "左上角保留了「第 N 关 …」那一行：%s" % level_text)
	_check(String(level_text).contains("收入") or String(level_text).contains("准备中"),
		"这一行带收入（倒计时开跑后是「第 N 关 · ⏱ m:ss · 收入 N 元」）")

	# ⑧ 订单栏不再依赖状态栏高度：固定在 y=88
	var op: Control = _find(UI, "OrderPanel")
	_check(op != null, "订单栏节点还在（第一张票要显示在这里）")
	if op != null:
		_check(absf(op.position.y - 88.0) < 0.5,
			"订单栏固定在 y=88（实测 %.0f）" % op.position.y)

	print("--------------------------------")
	print("通过 %d / 失败 %d" % [_ok, _bad])
	print("================================")
	get_tree().quit(1 if _bad > 0 else 0)


## 让 HUD 用当前数值刷新一次（直接喂快照，不依赖 Level 的私有方法）
func _pump(lv: Node) -> void:
	UI.apply_snapshot(Game.hud_snapshot(0))


func _check(cond: bool, what: String) -> void:
	if cond:
		_ok += 1
		print("  [OK]   " + what)
	else:
		_bad += 1
		print("  [FAIL] " + what)


func _find(root: Node, node_name: String) -> Control:
	if root == null:
		return null
	if root.name == node_name and root is Control:
		return root
	for c in root.get_children():
		var r := _find(c, node_name)
		if r != null:
			return r
	return null


func _collect_labels(root: Node, out: Array = [], mode: String = "all") -> Array:
	for c in root.get_children():
		if c is Label:
			var t := String(c.text)
			if mode == "num" and not t.contains("/"):
				pass                      # 只收「当前/目标」那种数字行
			else:
				out.append(c)
		_collect_labels(c, out, mode)
	return out


## 顶部目标栏里的文字（用来报告它现在只显示什么）
func _left_texts(bar: Control) -> Array:
	var out: Array = []
	for l in _collect_labels(bar):
		out.append(String(l.text))
	return out


func _collect_stars(root: Node, out: Array = []) -> Array:
	for c in root.get_children():
		if c.get_script() != null and String(c.get_script().resource_path).ends_with("star_icon.gd"):
			out.append(c)
		_collect_stars(c, out)
	return out
