@tool
extends EntityBase
## 柜台上的一份食物（**可点击的取餐点**）。
##
## 【它替代了什么】原来是「点餐铃 → 弹出后厨 UI → 点菜加入制作队列 →
## 等 3 秒 → 出餐口取餐」这一整条链路。现在改成：
## **柜台上直接摆着做好的食物，点它就取一份。** 制作过程整个去掉。
##
## 【节点怎么摆】
##   CounterFood (StaticBody2D)   ← 挂在 **World** 下，挂本脚本
##   └── Sprite2D                 ← 食物贴图
##
## 【两个必须遵守的约定，否则会静默失效】
##   1. **必须挂在 `World` 下**（不能挂在柜台节点下）—— ClickRouter 只遍历
##      `World` 的直接子节点来找可点物件。挂在柜台下就**点不到，且不报错**。
##   2. **不挡人**（本脚本的碰撞盒返回空矩形）。柜台的阻挡由**柜台自己的
##      `StaticBody2D` + `CollisionShape2D`** 负责，两者分工。
##
## 【和订单的关系】`item_id` 用的是和 `data/menu.json` / 订单票**同一个 id**
## （`fries`、`burger`…）。上菜时 `Table.assign_delivery()` 按 id 找到
## 「还没拿到这道菜的客人」，所以只要 id 对得上，整条上菜链路完全复用。
##
## ⚠️ **【重要约束】柜台上必须摆齐本关菜单里的每一道菜。**
## 客人是从「本关可用的全部餐品」里随机点单的（`Config.pool_at(关卡)`），
## 所以**少摆一样，点到它的那桌就永远上不了菜**——客人会一直等、最后气走，
## 而**不会报任何错**。加菜单时记得同时在柜台上加一个节点。

## 这道菜是什么（对应 `data/menu.json` 里的 id）。
##
## 【为什么是下拉而不是手输】手输字符串一旦拼错（`fries` 打成 `fires`），
## 后果是**这道菜永远送不出去、也不报错**——属于最难查的一类问题。
## 下拉的候选值直接从 `Config.kitchen_items` 来，所以**加了新菜会出现在列表里**。
## 下拉由本文件底部的 `_get_property_list()` 动态生成（见那里的说明）。
##
## 【为什么不写成 `@export`】因为下面的 `_get_property_list()` 会用同名属性
## 覆盖它来生成下拉，两者同时存在时 setter 的调用时机不确定。
## 干脆不用 setter —— 颜色在 `_draw()` 里现算，省掉一个状态同步点。
var item_id: String = ""

## 服务员来取餐时站的位置（相对本节点原点的偏移）。
##
## 【为什么必须有它】食物本身不挡人，而柜台挡人。如果站位点就在食物正上方，
## 服务员会被柜台挡住、停在柜台边，却以为"还没到"→ 卡住或反复找落脚点。
## 所以把站位点设在**柜台朝房间那一侧的外沿**，服务员就停在你能看到的位置。
## 编辑器视口里显示为绿十字。
@export var walk_offset: Vector2 = Vector2(0, 20)

## 从第几关开始出现在柜台上（1 = 一开始就有）。
##
## 【为什么在这里而不是只读 menu.json】关卡内容属于**场景摆放**的一部分
## ——「第一关柜台左边放薯条」这句话，描述的是场景。放一个数字在节点上，
## 复制粘贴食物节点时也跟着走。
## 关卡进阶时，代码会把未解锁的节点隐藏（连点击一起失效）。
@export var start_level: int = 1

var _walk: Vector2 = Vector2.ZERO


## 碰撞盒：**空**。食物不挡人。
##
## 【为什么可以没有碰撞盒】柜台的阻挡由柜台自己的碰撞体负责。
## 食物只是"贴在柜台上的可点标记"，让它也挡人会导致
## 「柜台边缘多出一堆小碰撞盒」，服务员贴边时会莫名其妙地卡。
func collision_box_local() -> Rect2:
	return Rect2()


func _ready() -> void:
	super._ready()
	if Engine.is_editor_hint():
		return
	# 开局先按当前关卡决定自己在不在柜台上
	_apply_level_visibility()


## 编辑器摆放后的自绑定。Level 在 _build_world() 里对 World 的每个子节点调用。
func setup_from_editor() -> void:
	kind = Constants.Kind.COUNTER
	label = ""
	display_label = ""
	# 先把尺寸同步到贴图，再建几何（这里碰撞盒是空的，所以只是同步 rect）
	_apply_geometry()
	_walk = global_position + walk_offset
	_apply_level_visibility()


## 按当前关卡显示/隐藏自己。
##
## 【为什么隐藏还要连点击一起失效】只把 `visible` 设成 false，节点仍然在
## `World` 下、仍然会被 `ClickRouter` 遍历到 —— 于是**你看不到它，却能点到它**。
## 那种「点了空气却取到一份餐」的 bug 极难理解，所以隐藏时把点击范围也清空。
func _apply_level_visibility() -> void:
	if Engine.is_editor_hint():
		# 编辑器里不按关卡隐藏，否则你没法摆后面关卡才出现的食物
		visible = true
		queue_redraw()
		return

	# 【先从旧值自愈，再校验】
	# 早期版本的 `item_id` 下拉把显示文本整段存了进来（`"burger:汉堡"`），
	# 原因见 _item_hint_string 的说明。这里自动取冒号前的部分，
	# 让已经摆好的节点不用手工返工。
	_heal_item_id()

	# 【最要紧的一条：id 必须真实存在于菜单里】
	# `item_id` 填错（拼错、大小写不对、或误填成下拉的显示文本 "burger:汉堡"）
	# 的后果是**静默**的：这份餐取到手上之后，和订单里的 id 对不上，
	# 于是**永远送不出去** —— 客人一直等到气走，而控制台一个字都不报。
	# 所以这里主动校验并吼出来，让摆场景的人 F5 一眼就能看到。
	if item_id == "":
		visible = false
		queue_redraw()
		return
	if not Config.has_item(item_id):
		push_error("[柜台食物] %s 的 item_id=\"%s\" 不在菜单里 —— 这份餐将永远无法送出。%s"
			% [name, item_id, _suggest_item_id()])
		visible = false          # 摆一份取不出来的假食物没有意义
		queue_redraw()
		return

	visible = Config.item_available_at(item_id, Game.level_index)
	queue_redraw()


## 把「值:显示名」这种旧格式还原成纯 id（`"burger:汉堡"` → `"burger"`）。
##
## 【为什么要自愈而不是只报错】旧场景文件里存的是这种值，那些节点已经摆好了。
## 只报错的话，每份食物都要人去逐个返工；自愈则让它们**直接可用**，
## 同时打一条 warning 说明发生了什么 —— 既不留坑，也不制造返工。
##
## 【为什么只写回一次】`_apply_level_visibility()` 会被多次调用
## （`setup_from_editor()` 一次、`_ready()` 一次）。用静态标记避免刷屏。
static var _healed_reported: bool = false

func _heal_item_id() -> void:
	var v := item_id.strip_edges()
	if not v.contains(":"):
		return
	var head := v.split(":")[0].strip_edges()
	if not Config.has_item(head):
		return                  # 不是这个毛病，交给下面的校验去报错
	item_id = head
	if not _healed_reported:
		_healed_reported = true
		push_warning("[柜台食物] 检测到旧格式的 item_id（带显示名），已自动改为纯 id。"
			+ "请到场景里确认 %s 的值现在是 \"%s\"。" % [name, head])


## 猜一个"你大概想填什么"，附在错误信息里，省得去翻 menu.json。
##
## 常见成因是误把下拉的显示文本存了进来（`burger:汉堡` 而不是 `burger`），
## 所以先按冒号切一刀，再看切出来的前半段是不是合法 id。
func _suggest_item_id() -> String:
	var trimmed := item_id.strip_edges()
	if trimmed.contains(":"):
		var head := trimmed.split(":")[0]
		if Config.has_item(head):
			return "应该是 \"%s\"（你填的是下拉的显示文本）。" % head
	var best := ""
	for it in Config.kitchen_items:
		var id := String(it.get("id", ""))
		# 子串命中就提示，比如填了 "burgerr"、"cheese" 也能给出方向
		if best == "" and (id.begins_with(trimmed) or trimmed.begins_with(id)):
			best = id
	if best != "":
		return "菜单里有 \"%s\"，是不是想填它？" % best
	return "菜单里的 id 是：%s。" % ", ".join(_menu_ids())


## 菜单里现有全部餐品的 id（拼成错误提示用）。
func _menu_ids() -> Array[String]:
	var out: Array[String] = []
	for it in Config.kitchen_items:
		out.append(String(it.get("id", "")))
	for it in Config.drink_items:
		out.append(String(it.get("id", "")))
	return out


## 现在能不能点（ClickRouter 会调它）。
func accepts_click() -> bool:
	if item_id == "":
		return false          # 还没填菜名，别吃掉点击
	if Engine.is_editor_hint():
		return false
	if not visible:
		return false
	return true


## 点击范围 = 贴图范围（所见即所得）。没填贴图或没填菜名时返回空 → 不可点。
func click_rect() -> Rect2:
	if item_id == "":
		return Rect2()
	if not (Engine.is_editor_hint()) and not visible:
		return Rect2()
	return rect


func walk_to() -> Vector2:
	return _walk


## 点击：手上有空位就走过去取，满了就原地飘字。
##
## 【为什么"走过去再取"而不是"点了立刻拿到"】这是这个游戏的核心手感
## （跑腿时间就是压力来源）。而且饮品机、垃圾桶都是这个模式，保持一致。
func interact(router: Node) -> int:
	if not accepts_click():
		return RouterResult.NO_ACTION
	if Game.hand_is_full():
		router.say(Constants.MSG_HANDS_FULL)
		return RouterResult.NO_ACTION
	router.go_then(_walk, Callable(self, "_do_take"), "去取" + _display_name())
	return RouterResult.ACCEPTED


## 到达时**再检查一遍**（这段时间里手可能满了、关卡可能换了）。
## 返回 false = 动作取消，服务员停在原地。
func _do_take(router: Node) -> bool:
	if not accepts_click():
		return false
	if Game.hand_is_full():
		router.say(Constants.MSG_HANDS_FULL)
		return false
	if not router.take_into_hand(item_id):
		return false
	router.say_at(global_position + Vector2(0, -12), "+1 " + _display_name(),
		Constants.COLOR_TEXT)
	return true


func _display_name() -> String:
	if item_id == "":
		return "食物"
	return Config.item_name(item_id)


## 占位美术：代码画的色块（还没有贴图时让你看得见东西），用菜单里的 color。
##
## 【默认 false：贴图优先】理由同 table.gd / chair.gd 的同名属性 ——
## 默认开着会让色块盖在贴图上，而且编辑器里看不出来（`_draw()` 走参考线分支）。
## 另外挂了 Sprite2D 的节点会被自动关掉，见
## `EntityBase.auto_disable_placeholder_if_sprite()`。
@export var draw_placeholder: bool = false


func _draw() -> void:
	if Engine.is_editor_hint():
		# 编辑器里只画参考线：站位点（绿）+ 可点范围（黄，由基类画）
		_draw_gizmo_walk(walk_offset)
		return
	if not draw_placeholder:
		return
	if item_id == "":
		return
	# 颜色现算（不缓存成字段），避免多一个需要同步的状态
	var r := Rect2(Vector2.ZERO, rect.size)
	draw_rect(r, Config.item_color(item_id), true)
	draw_rect(r, Color(0, 0, 0, 0.45), false, 1.5)


# ── 编辑器：把 item_id 做成下拉 ─────────────────────────────────────
##
## 【为什么要动态生成属性】`@export_enum` 要求候选值是**编译期常量**，
## 而我们的菜名来自 `data/menu.json`（运行时数据）。用 `_get_property_list`
## 就能在检查器里生成一个下拉，**加新菜之后自动出现在列表里**。
##
## 【为什么脚本是 @tool】非 tool 脚本在编辑器里不执行代码，
## `_get_property_list` 不会被调用，下拉也就不会出现。

func _get_property_list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.append({
		"name": "item_id",
		"type": TYPE_STRING,
		"usage": PROPERTY_USAGE_DEFAULT,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": _item_hint_string(),
	})
	return out


## 生成下拉候选：**只有 id，逗号分隔**。
##
## 【为什么不能写成 `burger:汉堡`】那种 `值:显示名` 的写法是给
## **`PROPERTY_HINT_ENUM` + 整数属性**用的。我们的属性是 `TYPE_STRING`，
## 类型和 hint 不匹配时 Godot 会把**整段显示文本**当成值存下来 ——
## 于是场景里出现 `item_id = "burger:汉堡"`，而它在菜单里根本不存在，
## 这份餐就永远送不出去了（还会连带触发下面的校验报错）。
##
## 【为什么空选项写成 `none` 而不是 `（未设置）`】同理：显示什么就存什么。
## 用一个明确的哨兵值，语义清楚，也不会因为中文括号出意外。
func _item_hint_string() -> String:
	var parts: Array[String] = ["none"]
	for it in _menu_defs():
		var id := String(it.get("id", ""))
		if id != "":
			parts.append(id)
	return ",".join(parts)


## 菜单定义（**直接读 data/menu.json，不依赖 Config autoload**）。
##
## 【为什么不直接用 Config.kitchen_items】`_get_property_list()` 在脚本
## 被检查器解析时就会调用，那时 autoload 的 `_ready()` 可能**还没跑** ——
## `Config.kitchen_items` 是空的，下拉就是空的（实测踩到过）。
## 生成属性清单这件事应该**自给自足**，不该依赖另一个节点的初始化时机。
##
## 【为什么缓存】检查器刷新时 `_get_property_list()` 会被反复调用，
## 每次读一遍文件没必要。菜单是静态数据，进程内读一次就够。
static var _menu_cache: Array = []


static func _menu_defs() -> Array:
	if not _menu_cache.is_empty():
		return _menu_cache
	var f := FileAccess.open("res://data/menu.json", FileAccess.READ)
	if f == null:
		return _menu_cache
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return _menu_cache
	var d: Dictionary = parsed
	var out: Array = []
	# 柜台卖的是"做好的餐点"，对应 menu.json 的 kitchen_items
	# （饮品走饮料机那条线，以后要改再调整）
	for key in ["kitchen_items", "drink_items"]:
		var arr: Variant = d.get(key, [])
		if typeof(arr) != TYPE_ARRAY:
			continue
		for it in arr:
			if typeof(it) == TYPE_DICTIONARY and it.has("id"):
				out.append(it)
	_menu_cache = out
	return _menu_cache
