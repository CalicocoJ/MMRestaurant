extends SceneTree
## 检查编辑器摆放的柜台食物：item_id 是否合法、是否可见、位置是否和贴图对齐、
## 以及「柜台上的菜」是否覆盖了「本关菜单池」。
##
## 用法：
##   godot --headless --path <project> --script res://tools/check_counter_food.gd
##
## 【本脚本故意不设 force_generated_layout】别的体检脚本都设它来隔离设计场景，
## 而这里要检查的**正是**那批手工摆放的节点 —— 必须走
## `_adopt_authored_furniture()` / `setup_from_editor()` 那条路。
##
## 【为什么用 root.get_node("Config") 而不是裸 Config】
## `--script` 模式下 autoload 节点**会被创建**（root 的子节点里有 Config/Game），
## 但它们**不作为全局标识符注册** —— 直接写 `Config` 会编译失败
## （`Identifier not found: Config`）。所以从场景树里取。

var _cfg: Node = null
var _game: Node = null


func _initialize() -> void:
	_cfg = root.get_node_or_null("Config")
	_game = root.get_node_or_null("Game")
	if _cfg == null or _game == null:
		print("✗ 拿不到 Config / Game autoload")
		quit(1)
		return

	var scene: Variant = load("res://scenes/main.tscn")
	if scene == null:
		print("✗ main.tscn 加载失败")
		quit(1)
		return
	var level: Node = (scene as PackedScene).instantiate()
	root.add_child(level)
	# 等几帧，让 _ready() / setup_from_editor() 把状态定下来
	for i in 3:
		await process_frame
	_report(level)
	quit(0)


func _report(level: Node) -> void:
	var world: Node = level.get_node_or_null("World")
	if world == null:
		print("✗ 找不到 World")
		return

	print("\n=== 柜台食物逐份检查 ===")
	var found := 0
	var on_counter: Array[String] = []
	for child in world.get_children():
		if child.get("item_id") == null:
			continue                      # 不是柜台食物
		found += 1
		var id := String(child.get("item_id"))
		var legal: bool = _cfg.call("has_item", id)
		var vis: bool = (child as Node2D).visible
		print("\n[%s]" % child.name)
		print("  item_id    = \"%s\"   %s" % [id, "✓ 菜单里有" if legal else "✗ 菜单里没有！"])
		if legal:
			print("  名称/价格  = %s / %d 元"
				% [_cfg.call("item_name", id), _cfg.call("item_price", id)])
			print("  本关可用   = %s   （start_level=%d，当前第 %d 关）"
				% [str(_cfg.call("item_available_at", id, _game.get("level_index"))),
					_cfg.call("item_start_level", id), _game.get("level_index")])
			on_counter.append(id)
		print("  运行时可见 = %s   %s"
			% [str(vis), "✓" if vis else "✗ 会被隐藏（id 非法或本关未解锁）"])

		# 位置对齐：节点原点应当和贴图左上角重合，否则点击范围和看到的差一截
		var sp: Node = child.get_node_or_null("Sprite2D")
		if sp is Sprite2D:
			var off: Vector2 = (sp as Sprite2D).position
			print("  贴图偏移   = %s   %s" % [str(off),
				"✓ 已对齐" if off == Vector2.ZERO
				else "✗ 未归零 → 点击范围和贴图错位 %s" % str(off)])

	print("\n共找到 %d 份柜台食物。" % found)

	# ── World 下有什么：确认代码没有再偷偷生成家具 ──────────────────
	# 设计场景模式下，代码**一件都不该生成**（后厨台/饮料机/垃圾桶会凭空
	# 多出三个落在房间外的节点，不显示却会被遍历、被寻路当障碍）。
	print("\n=== World 下的子节点（编辑器摆放 + 代码生成）===")
	# 【显式标注类型，不能用 :=】本项目开了「警告当错误」，
	# 而 `child.get("kind")` 的静态类型是 Variant —— 用 := 会因为
	# "type is being inferred from a Variant value" 直接解析失败。
	var kinds: Dictionary = {}
	for child in world.get_children():
		var k: Variant = child.get("kind")
		var kn: String = "（无 kind，装饰物）" if k == null else str(k)
		var scr: Variant = child.get_script()
		var rn: String = "（无脚本）" if scr == null else String((scr as Script).resource_path).get_file()
		print("  %-16s kind=%-14s 脚本=%s" % [child.name, kn, rn])
		if k != null:
			kinds[kn] = int(kinds.get(kn, 0)) + 1
	print("  各 kind 数量：%s" % str(kinds))

	# ── 菜单池 vs 柜台：少摆一样，点到它的那桌就永远上不了菜（且不报错）──
	var lv: int = _game.get("level_index")
	var pool: Array = _cfg.call("pool_at", lv)
	print("\n=== 菜单池 vs 柜台（第 %d 关）===" % lv)
	print("  本关客人可能点：%s" % ", ".join(pool))
	print("  柜台上确实有：  %s" % ", ".join(on_counter))
	var missing: Array[String] = []
	for id in pool:
		if not on_counter.has(String(id)):
			missing.append(String(id))
	if missing.is_empty():
		print("  ✓ 齐全")
	else:
		print("  ✗ 缺 %d 样：%s" % [missing.size(), ", ".join(missing)])
		print("    后果：点到这些菜的桌子永远上不了菜（客人等到气走，且不报错）")
