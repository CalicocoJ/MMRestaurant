extends SceneTree
## 【一次性试算】Counter.sort_y_offset = -20 时的排序预演（只读，不动磁盘、不改代码）。
##
## 用法： godot --headless --path . --script res://tools/trial_sort_offset.gd
##
## 排序键 = 归一化后的脚底 y + sort_y_offset
##   Counter 脚底 263，offset -20 → 排序键 243
## 断言（用户点名 4 条 + 1 条对照）：
##   A. 三份 Food 全部盖住 Counter
##   B. 服务员在柜台前（y=200，在食物站位带上）盖住 Counter
##   C. 服务员在柜台后（y=280 以南）被 Counter 盖住
##   D. 客人在柜台前（y=280）盖住 Counter

const COUNTER_OFFSET := -20.0


func _initialize() -> void:
	var packed: Variant = load("res://scenes/main.tscn")
	var level: Node = (packed as PackedScene).instantiate()
	root.add_child(level)
	for i in 3:
		await process_frame

	var statics: Array = _statics(level)
	print("=== 试算：Counter.sort_y_offset = %.0f ===" % COUNTER_OFFSET)
	# 【必须先应用 offset，再做任何排序断言】第一版把断言写在这一步之前，
	# 用的还是未修改的 key(263)，于是 B/A 必然失败 —— 白跑一轮。
	print("\n静态物排序键（脚底 y + offset）：")
	for s in statics:
		var off := COUNTER_OFFSET if String(s["name"]) == "Counter" else 0.0
		s["key"] = float(s["y"]) + off
		var extra := ""
		if off != 0.0:
			extra = "   ← 应用 offset %.0f（脚底 %.0f → 键 %.0f）" % [off, s["y"], s["key"]]
		print("    %-22s 脚底 y=%6.1f   排序键=%6.1f%s"
			% [s["label"], s["y"], s["key"], extra])

	# 断言用的几个站位
	var cases := [
		{"title": "B  服务员在柜台前（y=200）", "actor": "Waiter", "y": 200.0,
			"must_be_after": ["Counter"], "must_be_before": []},
		{"title": "C  服务员在柜台后（y=280，以南）", "actor": "Waiter", "y": 280.0,
			"must_be_after": [], "must_be_before": ["Counter"]},
		{"title": "C2 服务员站在柜台碰撞盒底边（y=261）", "actor": "Waiter", "y": 261.0,
			"must_be_after": [], "must_be_before": ["Counter"]},
		{"title": "D  客人在柜台前（y=280）", "actor": "Customer", "y": 280.0,
			"must_be_after": ["Counter"], "must_be_before": []},
	]

	print("\n---------- 逐站位判定 ----------")
	# 【调试】把参与排序的条目原样打出来 —— 断言失败时先看这个，
	# 别去猜"是不是又被过滤掉了"（这个脚本已经因此白跑三轮）。
	print("  [调试] statics 共 %d 条：" % statics.size())
	for i in statics.size():
		print("    #%d name=%s label=%s key=%.1f"
			% [i, statics[i]["name"], statics[i]["label"], statics[i]["key"]])
	var fails: Array[String] = []
	for c in cases:
		var order: Array = _order(statics, String(c["actor"]), float(c["y"]))
		var idx := _index_of(order, String(c["actor"]))
		var ci := _index_of(order, "Counter")
		# 【判据写清楚：名字序列里 i 越大 = 画得越晚 = 盖在上面】
		#   "必须在 X 之后"（要盖住 X）→ idx > index(X)
		#   "必须在 X 之前"（被 X 盖住）→ idx < index(X)
		var ok_after := true
		for nm in c["must_be_after"]:
			var j_after := _index_of(order, String(nm))
			print("      [比较] idx(%s)=%d  index(%s)=%d  → 需要 idx > %d ? %s"
				% [c["actor"], idx, nm, j_after, j_after, str(idx > j_after)])
			if idx <= j_after:
				ok_after = false
		var ok_before := true
		for nm in c["must_be_before"]:
			var j_before := _index_of(order, String(nm))
			print("      [比较] idx(%s)=%d  index(%s)=%d  → 需要 idx < %d ? %s"
				% [c["actor"], idx, nm, j_before, j_before, str(idx < j_before)])
			if idx >= j_before:
				ok_before = false
		var verdict := "✓ 通过" if (ok_after and ok_before) else "★ 不通过"
		print("\n%s   %s" % [c["title"], verdict])
		print("    绘制顺序（从下到上）：%s" % _brief(order))
		print("    %s 在第 %d 位，Counter 在第 %d 位   [ok_after=%s ok_before=%s 名字序列=%s]"
			% [c["actor"], idx + 1, ci + 1, str(ok_after), str(ok_before),
				",".join(_names(order))])
		if not (ok_after and ok_before):
			fails.append(String(c["title"]))

	# 断言 A：食物 vs 柜台
	print("\n---------- A  三份食物 vs 柜台 ----------")
	var food_ok := true
	for f in ["Food_Cake", "Food_Burger", "Food_Hotdog"]:
		var fi := _index_of(_order(statics, "Waiter", 200.0), f)
		var ci := _index_of(_order(statics, "Waiter", 200.0), "Counter")
		var ok := fi > ci
		if not ok:
			food_ok = false
		print("    %-14s 第 %d 位   Counter 第 %d 位   %s"
			% [f, fi + 1, ci + 1, "✓ 食物盖住柜台" if ok else "★ 柜台盖住食物"])
	if not food_ok:
		fails.append("A 食物未全部盖住柜台")

	print("\n\n=== 试算结论 ===")
	if fails.is_empty():
		print("✓ 全部通过 —— 可以动手")
	else:
		print("★ 未通过 %d 项：" % fails.size())
		for f in fails:
			print("    - %s" % f)
	print("\n（提醒：这是「排序键」层面的判定；实际画面还受 Wall 层 z_index 影响 ——")
	print("  它必须 >= -65 才不会盖住门，建议 -50。）")
	quit(0)


## 收集静态物（含 Counter）
## 【为什么把 Level 自己也算一遍】Counter 是 Level 的直接子节点，不是 World 的子节点；
## 漏掉它就没法判定"谁盖住柜台"，而且名字里会混进 Floor / Wall 两个图块层。
func _statics(level: Node) -> Array:
	var raw: Array = []
	var seen: Dictionary = {}
	_scan(level, raw, seen)
	var keep: Array = []
	for s in raw:
		var label := String(s["label"])
		if label.begins_with("Floor/") or label.begins_with("Wall/"):
			continue
		if label == "Floor" or label == "Wall" or label == "Camera2D":
			continue
		# 角色的初始化位置（Waiter 在场景里是 (0,0)）不算静态物
		if float(s["y"]) <= 1.0:
			continue
		# 【必须排除真实角色节点】否则列表里会出现两个 "Waiter"：
		# 场景里那个（脚底 16.9）和快照放的虚拟位置，
		# `_index_of` 只会找到前一个 —— 断言永远判错（踩过两次）。
		var nm := String(s["name"])
		if nm == "Waiter" or nm == "Customer":
			continue
		keep.append(s)
	return keep


func _scan(node: Node, out: Array, seen: Dictionary) -> void:
	for child in node.get_children():
		if child is Node2D and not (child is TileMapLayer):
			var key := child.get_instance_id()
			if not seen.has(key):
				seen[key] = true
				var vr := _visual_rect(child)
				if vr.size.x > 0.0 and vr.size.y > 0.0:
					out.append({
						"name": String(child.name),
						"label": _label(child),
						"y": vr.end.y,
						"key": vr.end.y,
						"rect": vr,
					})
		if child.get_child_count() > 0 and not (child is TileMapLayer):
			_scan(child, out, seen)


## 重名太多（两把 Chair1），用「父节点/自己」区分
func _label(node: Node) -> String:
	var p := node.get_parent()
	if p == null:
		return String(node.name)
	return "%s/%s" % [p.name, node.name]


func _visual_rect(node: Node2D) -> Rect2:
	var box := Rect2()
	var first := true
	for c in node.get_children():
		var r := Rect2()
		if c is Sprite2D:
			var s := c as Sprite2D
			if s.texture == null:
				continue
			var size: Vector2 = s.texture.get_size() * s.scale
			var org: Vector2 = node.to_global(s.position)
			if s.centered:
				org -= size * 0.5
			r = Rect2(org, size)
		elif c is AnimatedSprite2D:
			var a := c as AnimatedSprite2D
			if a.sprite_frames == null or a.sprite_frames.get_frame_count(a.animation) <= 0:
				continue
			var tex: Texture2D = a.sprite_frames.get_frame_texture(a.animation, 0)
			if tex == null:
				continue
			var size2: Vector2 = tex.get_size() * a.scale
			var org2: Vector2 = node.to_global(a.position)
			if a.centered:
				org2 -= size2 * 0.5
			r = Rect2(org2, size2)
		else:
			continue
		box = r if first else box.merge(r)
		first = false
	return box


## 排一次序，返回从下到上的名字列表（含一位角色）
func _order(statics: Array, actor_name: String, actor_y: float) -> Array:
	var items: Array = []
	for s in statics:
		items.append({"name": String(s["name"]), "label": String(s["label"]),
			"key": float(s["key"])})
	items.append({"name": actor_name, "label": actor_name, "key": actor_y})
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["key"] < b["key"])
	var names: Array = []
	for it in items:
		names.append(String(it["name"]))
	return names


func _index_of(names: Array, nm: String) -> int:
	for i in names.size():
		if String(names[i]) == nm:
			return i
	return -1


func _names(order: Array) -> Array[String]:
	var out: Array[String] = []
	for i in order.size():
		out.append("%d:%s" % [i, String(order[i])])
	return out


func _brief(order: Array) -> String:
	var parts: Array[String] = []
	for i in order.size():
		parts.append("%d.%s" % [i + 1, String(order[i])])
	return " ".join(parts)
