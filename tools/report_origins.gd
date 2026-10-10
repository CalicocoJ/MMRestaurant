extends SceneTree
## 【一次性诊断】原点归一化 dry-run：
## 把每个"可遮挡物"的**当前原点**和**目标原点（脚底中心）**量出来，
## 告诉你需要位移多少。**只读，不改任何文件。**
##
## 用法： godot --headless --path . --script res://tools/report_origins.gd
##
## 【约定】节点原点 = 视觉包围盒（自己 + 直接子 Sprite2D / AnimatedSprite2D）
## 的水平中点 + 垂直底边。见输出里的"位移"一列。


func _initialize() -> void:
	var packed: Variant = load("res://scenes/main.tscn")
	if not (packed is PackedScene):
		print("✗ 加载 main.tscn 失败")
		quit(1)
		return
	var level: Node = (packed as PackedScene).instantiate()
	root.add_child(level)
	for i in 3:
		await process_frame

	var targets: Array = _collect_targets(level)
	print("=== 原点归一化 dry-run ===")
	print("约定：节点原点应落在「视觉包围盒的水平中点 + 垂直底边」")
	print("（正数位移 = 原点需要往右下挪；同时子贴图会往反方向挪，画面不变）\n")
	print("%-18s %-10s %-22s %-22s %s" % ["节点", "类", "当前原点", "目标原点(脚底)", "位移"])
	print("-".repeat(96))

	var bad := 0
	for t in targets:
		var node: Node2D = t["node"]
		var vrect: Rect2 = t["visual"]
		var cur := node.global_position
		if vrect.size.x <= 0.0 or vrect.size.y <= 0.0:
			print("%-18s %-10s %-22s %-22s %s"
				% [node.name, node.get_class(), str(cur.round()), "—", "★ 量不到视觉范围（没有贴图？）"])
			continue
		var aim := Vector2(vrect.position.x + vrect.size.x * 0.5, vrect.end.y)
		var delta := aim - cur
		var flag := "✓ 已对齐" if delta.length() < 0.5 else "需位移 (%.1f, %.1f)" % [delta.x, delta.y]
		if delta.length() >= 0.5:
			bad += 1
		print("%-18s %-10s %-22s %-22s %s"
			% [node.name, node.get_class(), str(cur.round()), str(aim.round()), flag])
		# 顺便报一下视觉范围，方便你核对"脚底"取的位置对不对
		print("    视觉范围 = %s" % _fmt_rect(vrect))

	print("\n需要位移的节点数 = %d / %d" % [bad, targets.size()])

	# ── 排序预演：按「归一化后的脚底 y」排出完整绘制顺序 ──────────────
	_preview_snapshots(targets)
	quit(0)


## 5 个关键站位的排序预演。
##
## 【为什么不是简单列一张表】排序对不对**取决于站位**：同一张桌子，
## 服务员站桌子下沿和站桌子旁边，前后关系是相反的。所以要按**
## 实际会发生的站位**分别预演，才能提前发现"客人被椅子挡住""食物被柜台挡住"
## 这类只在特定站位暴露的问题。
func _preview_snapshots(targets: Array) -> void:
	# 静态物：排序键 = 归一化后的脚底 y
	var statics: Array = []          # [{name, y, rect}]
	for t in targets:
		var node: Node2D = t["node"]
		var vr: Rect2 = t["visual"]
		if vr.size.y <= 0.0:
			continue
		statics.append({
			"name": String(node.name),
			"y": vr.end.y,
			"rect": vr,
			"path": String(node.get_path()),
		})

	print("\n\n========== 排序预演（按归一化后的脚底 y）==========")
	print("静态物的脚底 y：")
	for s in statics:
		print("    %-16s y=%6.1f   x %.0f..%.0f" % [s["name"], s["y"],
			s["rect"].position.x, s["rect"].end.x])

	_snapshot(statics, "快照1  服务员站在 Table1 下沿（Waiter 脚底 y=200）",
		[{"name": "Waiter", "y": 200.0}])
	_snapshot(statics, "快照2  服务员站在 Table1 旁边（Waiter 脚底 y=150）",
		[{"name": "Waiter", "y": 150.0}])
	_snapshot(statics, "快照3  客人坐在 Table1 的 Chair1 上（Customer 脚底 y=170）",
		[{"name": "Customer", "y": 170.0}])
	_snapshot(statics, "快照4a 客人从门口走进来（Customer 脚底 y=50）",
		[{"name": "Customer", "y": 50.0}])
	_snapshot(statics, "快照4b 客人从门口走进来（Customer 脚底 y=100）",
		[{"name": "Customer", "y": 100.0}])
	_snapshot(statics, "快照5  客人站在 Counter 前点餐（Customer 脚底 y=280）",
		[{"name": "Customer", "y": 280.0}])

	# ── 两个重点问题的判定 ─────────────────────────────────────────
	print("\n\n========== 重点判定 ==========")
	var door_y: float = _y_of(statics, "Door")
	var counter_y: float = _y_of(statics, "Counter")
	var food := ["Food_Cake", "Food_Burger", "Food_Hotdog"]
	print("\n[1] 门 vs 客人（门框脚底 y=%.0f）" % door_y)
	for cy in [50.0, 100.0]:
		var door_in_front: bool = door_y > float(cy)   # 脚底更大 → 画得更后 → 盖住客人
		var verdict := "门盖住客人" if door_in_front else "客人盖住门（★ 穿模感）"
		var want := "✓ 期望如此" if (float(cy) < door_y) else "★ 期望相反"
		print("    客人 y=%.0f → %s   %s" % [cy, verdict, want])

	print("\n[2] 食物 vs 柜台（柜台脚底 y=%.0f）" % counter_y)
	for f in food:
		var fy: float = _y_of(statics, f)
		if fy <= 0.0:
			continue
		var counter_in_front: bool = counter_y > fy
		print("    %-14s 脚底 y=%.0f → %s"
			% [f, fy, "★ 柜台盖住食物（预演暴露的问题）" if counter_in_front else "食物盖住柜台 ✓"])

	# 静态物之间、以及和角色矩形是否真的重叠（不重叠就谈不上遮挡）
	print("\n[3] 静态物之间的矩形重叠检查（只有重叠才谈得上谁盖谁）")
	for i in statics.size():
		for j in range(i + 1, statics.size()):
			var a: Rect2 = statics[i]["rect"]
			var b: Rect2 = statics[j]["rect"]
			if a.intersects(b):
				print("    %s 与 %s 视觉范围重叠（y %.0f vs %.0f）→ 谁盖谁 = %s"
					% [statics[i]["name"], statics[j]["name"], statics[i]["y"], statics[j]["y"],
						statics[i]["name"] if statics[i]["y"] > statics[j]["y"] else statics[j]["name"]])


## 打一个快照：从下到上的完整绘制顺序
func _snapshot(statics: Array, title: String, actors: Array) -> void:
	var items: Array = []
	for s in statics:
		items.append({"name": s["name"], "y": s["y"], "rect": s["rect"], "actor": false})
	for a in actors:
		# 角色的视觉范围是 32×34、原点在脚底中心（归一化之后）
		var ay: float = a["y"]
		items.append({
			"name": a["name"], "y": ay,
			"rect": Rect2(Vector2(-16.0, ay - 34.0), Vector2(32.0, 34.0)),
			"actor": true,
		})
	items.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x["y"] < y["y"])

	print("\n\n---------- %s ----------" % title)
	print("  从下到上（先画的在下面）:")
	for i in items.size():
		var it: Dictionary = items[i]
		var r: Rect2 = it["rect"]
		# 标出和别的元素"视觉范围真的重叠"的那些，那些才需要关心先后
		var overlaps: Array[String] = []
		for j in items.size():
			if j == i:
				continue
			if r.intersects(items[j]["rect"]):
				overlaps.append(String(items[j]["name"]))
		var tag := ""
		if it["actor"]:
			tag = "   ← 角色"
		if not overlaps.is_empty():
			tag += "   [与 %s 重叠]" % ", ".join(overlaps)
		print("    %2d. %-16s y=%6.1f%s" % [i + 1, it["name"], it["y"], tag])


func _y_of(statics: Array, name: String) -> float:
	for s in statics:
		if String(s["name"]) == name:
			return float(s["y"])
	return 0.0


## 收集所有"会参与遮挡"的节点：家具 / 门 / 食物 / 柜台 / 角色
func _collect_targets(level: Node) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	# 【为什么把 Level 自己也算进来】柜台（Counter）是 Level 的直接子节点，
	# 不在 World 下 —— 漏掉它就无法判断 "Food 和 Counter 谁盖谁"。
	_scan(level, out, seen)
	return out


func _scan(node: Node, out: Array, seen: Dictionary) -> void:
	for child in node.get_children():
		if child is Node2D and not (child is TileMapLayer):
			var key := child.get_instance_id()
			if not seen.has(key):
				seen[key] = true
				var vr := _visual_rect(child)
				if vr.size.x > 0.0 and vr.size.y > 0.0:
					out.append({"node": child, "visual": vr})
		# 继续往下找（椅子挂在桌子下、贴图挂在角色下）
		if child.get_child_count() > 0 and not (child is TileMapLayer):
			_scan(child, out, seen)


## 一个 Rect2 的可读形式（Vector2 有 round()，Rect2 没有 —— 别想当然）
func _fmt_rect(r: Rect2) -> String:
	return "x%.0f y%.0f w%.0f h%.0f   底边 y=%.0f 中点 x=%.0f" % [
		r.position.x, r.position.y, r.size.x, r.size.y,
		r.end.y, r.position.x + r.size.x * 0.5]


## 一个节点的"视觉包围盒"（世界坐标）：自己 + 直接子 Sprite2D / AnimatedSprite2D
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
