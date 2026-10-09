extends Node2D
## 主场景。把 data/layout.json 里的坐标变成真正的场景树，并把各系统接起来。
##
## 【场景树由脚本搭，而不是手写 .tscn】
## 理由有三条：
##   1. 所有坐标本来就在 data/layout.json 里，手写 .tscn 等于把数字抄第二遍，
##      两份数字一旦不一致，就会出现「点得到但走不到」这种极难查的 bug；
##   2. 加一张桌子只要改 JSON，不用在编辑器里复制节点；
##   3. 这个工程是给 AI agent 维护的 —— 脚本里的结构可读、可 diff，
##      二进制式的场景改动不可读。
##
## 场景层级：
##   Level
##   ├── World          所有可点击家具（ClickRouter 在这里找命中目标）
##   │   ├── Table1..3 / KitchenWindow / DrinkMachine / Trash / Door
##   ├── Actors
##   │   ├── Waiter
##   │   └── Customers   运行时动态生成
##   ├── CustomerSpawner 每 1s 检测生成
##   └── ClickRouter     点击 → 走过去 → 到达时再检查

const ROUTER_SCRIPT := preload("res://scripts/core/click_router.gd")
const SPAWNER_SCRIPT := preload("res://scripts/level/customer_manager.gd")
const TABLE_SCRIPT := preload("res://scripts/world/table.gd")
const KITCHEN_SCRIPT := preload("res://scripts/world/kitchen_window.gd")
const DRINK_SCRIPT := preload("res://scripts/world/drink_machine.gd")
const TRASH_SCRIPT := preload("res://scripts/world/trash.gd")
const DOOR_SCRIPT := preload("res://scripts/world/door.gd")
const WAITER_SCRIPT := preload("res://scripts/actors/waiter.gd")
const CUSTOMER_SCRIPT := preload("res://scripts/actors/customer.gd")
const PATHFINDER_SCRIPT := preload("res://scripts/core/pathfinder.gd")
## 服务员身体半径：寻路外扩量要跟它对齐（见下面 build 的说明）
const WAITER_RADIUS := 16.0

## 地板 / 墙的图块层，由**编辑器摆放**（挂在 Level 下的 TileMapLayer 节点）。
##
## 【为什么用 @export 而不是写死 get_node("Floor")】
## 导出变量会在检查器里显示出来，节点改名或漏挂时一眼可见，
## 而不是静默拿到 null —— 那正是最难查的那类 bug。
##
## 【留空的兜底】没在检查器里指定时，自动找 Level 下名为 "Floor" 的子节点，
## 见 _resolve_floor_layer()。所以编辑器里那一栏不填也能跑。
@export var floor_layer: TileMapLayer = null
## 自动查找时用的子节点名。改名要跟这里一起改。
const FLOOR_LAYER_NAME := "Floor"

## 是否在开局弹出「开始界面」（点了开始游戏才进入游戏）。
##
## 【默认必须是 false，而且 main.tscn 里**不要**写 true】
## 这个字段的默认值就是「加载 main.tscn 的所有测试 / 工具脚本」的命运 ——
## 一旦在 main.tscn 里写死 true，**18 个工具全都会弹出开始界面并冻结世界**，
## 引擎又不会给暂停树里的节点发 `_process`，于是靠 `_process` 跑逻辑的测试
## 会被**静默冻死**（本轮实际踩到：客人生成器一次都没跑，工具却全绿）。
## 所以 main.tscn 保持不写这个字段，真正的入口判据放在 _ready 里同步算。
##
## 判据 = 「本节点是 root 的直接子节点」+「本节点是 current_scene」——
##   引擎按 run/main_scene 启动：两个条件都成立 → 出开始界面
##   测试 / 工具加载同一个 main.tscn：至少有一个不成立 → 不出、不暂停
## 两条都算，是因为单看任一条都有反例（详见下面的注释）。
@export var show_start_screen: bool = false

## 强制按 data/layout.json 生成整套家具，**忽略 World 下已经摆好的东西**。
##
## 【为什么必须有这个开关】这是「设计场景」和「测试」共存的唯一办法。
##
## 从这一步起，`main.tscn` 变成**你设计关卡的地方**：World 下会逐渐摆满家具。
## 但那 40 多个工具脚本实例化的**正是同一个 main.tscn**
## （实测：World 里只放了一张桌子，测试通过数就从 206 掉到 166）——
## 因为工具的断言全都建立在「layout.json 那套坐标」上。
##
## 两种用途对同一个场景的要求是**互斥**的：
##   游戏要跑 → 用你摆的家具
##   测试要跑 → 用 layout.json 那套（断言写的是它）
## 所以用一个显式开关把两者分开，而不是让它们互相污染。
##
## 【用法（工具脚本里）】实例化之后、add_child 之前设成 true：
##     var lv := (load("res://scenes/main.tscn") as PackedScene).instantiate()
##     lv.set("force_generated_layout", true)   # ← 必须在 add_child 之前
##     get_tree().root.add_child(lv)
## 顺序很重要：`_ready()` 在 add_child 时同步触发，而这套搭建逻辑跑在 _ready 里。
@export var force_generated_layout: bool = false

var world: Node2D = null
var actors: Node2D = null
var customers: Node2D = null
var waiter: Node = null
var router: Node = null
var spawner: Node = null
var pathfinder: Node = null

var _hud_clock: float = 0.0
var _hud_interval: float = 0.1

## 这一局累计有多少位客人**坐下了**（只在 _ready 归零，不随客人离场减少）。
##
## 【为什么需要这个计数】客人到门口就 queue_free，「当前有几个客人」随时可能回到 0，
## 于是「整局只来了头一组客人」这种死锁从当前数量上看不出来。
## 有了这个累计值，测试就能断言「30 秒内至少坐下过 3 位」——
## 这正是那个 bug（_group_size 忘了复位）唯一可靠的判据。
var seated_total: int = 0


func _ready() -> void:
	Game.reset()
	_setup_background()
	_build_world()
	_build_actors()
	_build_systems()

	# UI 依赖 router，router 依赖 waiter，所以顺序不能换
	UI.setup(router)
	router.ui = UI
	# 走路失败要有提示，别让玩家面对「点了没反应」
	router.call("watch_waiter")

	# 【开始界面：判据必须是「主场景 + root 直接子节点」两条都成立】
	#
	# 需求是「点了开始游戏才能进入游戏」，所以游戏启动必须先停在标题画面。
	# 但 tools/ 下有 18 个脚本都 `load("res://scenes/main.tscn").instantiate()`
	# 之后立刻驱动世界。开始界面要是把它们也挡住并且冻结世界，
	# 靠 _process 跑逻辑的测试会被**静默冻死** —— 引擎不给暂停树里的节点发 _process，
	# 而工具照样打印「全部通过」。本轮真的踩到了这条（客人生成器一次都没跑）。
	#
	# 【为什么两条判据都要】
	#   ① 父节点是不是 root —— run_tests.gd / scan_reach.gd / diag_detour.gd
	#      也是 `root.add_child(level)`，父节点**就是** root，单看这条会误判。
	#   ② current_scene == self —— **引擎是在 _ready 跑完之后才赋值 current_scene 的**
	#      （实测 _ready 同步 / 同帧 deferred / 下一帧三个时点读到的都还不是自己），
	#      _ready 里同步读它必然为假。
	# 两条合起来：主场景两个都成立；上面那三个工具只满足 ①，被 ② 挡掉。
	#
	# 【为什么暂停要同步做，而界面切换可以延后】
	# 同步能保证世界从第一帧起就是冻住的；
	# 但「延后一帧再切界面」会让工具多跑一帧未暂停的世界（无用功）。
	# 所以：同步判定 + 同步暂停，只有界面显示这一步放到帧末（那时 HUD 已搭完）。
	#
	# 想强制指定（工具里想看开始界面）：instanceiate 之后直接设这个字段即可。
	show_start_screen = show_start_screen or _is_game_entry()
	UI.begin(show_start_screen)
	# 【一局的开始由 UI 通知】玩家按「开始游戏」/ 结算界面按「下一关」时，
	# UIManager 发 run_requested；这里负责真正把一局跑起来
	# （清客人、清桌子、营收归零、倒计时装满）。
	# 为什么不让 UI 直接改 Game：清场是场景的职责，UI 越界会让
	# 「谁负责重置」变得含糊 —— 那正是「上一局的东西残留到下一局」的温床。
	if not UI.run_requested.is_connected(_start_level_run):
		UI.run_requested.connect(_start_level_run)
	Game.orders_changed.connect(_on_orders_changed)
	_on_orders_changed()
	_pump_hud()


## 本节点是「引擎按 run/main_scene 直接跑起来」的那个场景吗？
func _is_game_entry() -> bool:
	var tree := get_tree()
	if tree == null:
		return false
	return get_parent() == tree.root and tree.current_scene == self


# ── 搭建 ───────────────────────────────────────────────────────────

## 背景：地板 / 墙由编辑器摆的 TileMapLayer 负责，这里只做「找图块层 + 兜底」。
##
## 【为什么图块层没铺满时要垫一个纯色底】
## 图块层是**稀疏**的 —— 没刷格子的地方是透明的。不垫底的话，
## 边缘没铺到的区域会露出引擎默认的清屏色（近黑），看起来像「贴图丢了」。
## 垫一层 COLOR_BG 就只是「深色地板」，不像故障。
##
## 【为什么用 CanvasLayer(layer=-10) 而不是 z_index】
## 它要垫在**所有**默认层内容之下，包括以后可能加的其他图层；
## CanvasLayer 的层级是绝对的，不会被后续节点的 z_index 意外盖住。
func _setup_background() -> void:
	_resolve_floor_layer()
	if not _has_visible_tiles():
		var bg := ColorRect.new()
		bg.name = "Background"
		bg.color = Constants.COLOR_BG
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var cl := CanvasLayer.new()
		cl.name = "BackgroundLayer"
		cl.layer = -10
		cl.add_child(bg)
		add_child(cl)


## 拿到图块层引用：先看检查器里指定的，没有再按名字自动找。
##
## 【为什么要有自动查找这一步】编辑器那边「新建节点 + 拖引用」是两件事，
## 漏掉第二件就会静默变回纯色底，而人只会看到「地板没生效」。
## 自动查找让「节点名对了就生效」，把两件事减成一件。
func _resolve_floor_layer() -> void:
	if floor_layer != null and is_instance_valid(floor_layer):
		return
	var found := get_node_or_null(NodePath(FLOOR_LAYER_NAME))
	if found is TileMapLayer:
		floor_layer = found


## 图块层上有没有已经刷好的格子？
##
## 【为什么要先问这个】把「该不该垫底色」和「有没有真的铺地板」解耦：
##   - 还没建 TileMap   → 垫底，游戏照常能玩（**迁移期必须**）
##   - 建了但一格没刷   → 垫底，不会变成一片黑
##   - 刷了至少一格     → 不垫底，纯看贴图
##
## 【为什么取不到格子时保守返回 false】
## 「有没有刷格子」的 API 名在不同 Godot 小版本里改过。这里不赌版本：
## 取不到就当成「没刷」，宁可多垫一层（垫层是隐形的，图块不透明时完全被盖住），
## 也不要因为方法不存在而报错 —— 那会让游戏直接跑不起来。
func _has_visible_tiles() -> bool:
	if floor_layer == null or not is_instance_valid(floor_layer):
		return false
	if floor_layer.has_method("get_used_cells"):
		var used: Array = floor_layer.call("get_used_cells")
		return not used.is_empty()
	if floor_layer.has_method("get_used_cells_by_id"):
		var used2: Array = floor_layer.call("get_used_cells_by_id", 0)
		return not used2.is_empty()
	return false


## 家具统一的「由编辑器摆放后自绑定」入口名。
##
## 【为什么用具名常量而不是散落的字符串】家具脚本和这里必须约定同一个名字，
## 拼错就会**静默**变成「没采纳、走了生成分支」——那种 bug 不报错、只是
## 你摆的东西不生效。放在一处，改的时候只改一个地方。
const EDITOR_SETUP := "setup_from_editor"


func _build_world() -> void:
	# 【World 节点的来路有两条】
	#   ① main.tscn 里已经有（模块化之后的正规形态）→ 直接复用
	#   ② 没有 → 运行时创建（保证 35 个工具脚本照旧能跑）
	# 两条都必须支持：工具是 `load("res://scenes/main.tscn").instantiate()`，
	# 它们拿到的是同一个 main.tscn，不能因为改成编辑器摆放就全体失效。
	world = get_node_or_null("World") as Node2D
	if world == null:
		world = Node2D.new()
		world.name = "World"
		add_child(world)

	# 【按种类补齐，而不是「有摆放就全不生成」】
	#
	# 你可以在编辑器里只摆一部分家具（比如先只摆 1 张桌子试试），
	# 没摆的那些仍然按 layout.json 生成一个能用的占位版。
	#
	# 【为什么必须这样】早先的判据是「World 下有子节点就只采纳编辑器家具」，
	# 于是你摆了 1 张桌子之后，**后厨台 / 饮料机 / 垃圾桶 / 门口全都不再生成**：
	#   门口不生成 → Door.setup() 没被调用 → 客人从硬编码的默认坐标冒出来；
	#   柜台不生成 → 取餐、点单铃全都没了。
	# 整局直接玩不了，而且**不报错**。按种类补齐就没有这个断层：
	# 你摆一件、就接管一件，其余照旧。
	if force_generated_layout:
		# 测试模式：把你摆的家具整个让开，全部按 layout.json 生成 ——
		# 工具的断言写的是 layout.json 那套坐标，不能被设计场景干扰。
		# 【为什么用 free() 而不是 queue_free()】queue_free 是「本帧末再删」，
		# 而下面的生成是**同步**进行的：那些节点这时还在树里，
		# _has_kind() 会照样看见它们 → 又变成「不生成」，测试依旧失败。
		# 这里要的是「立刻让开」，所以用立即释放。
		for child in world.get_children():
			world.remove_child(child)
			child.free()
	else:
		_adopt_authored_furniture()
	_generate_missing_furniture()

	# table_id 必须在**选座和寻路之前**定下来：客人落座靠 Game.tables 的顺序，
	# 而寻路网格吃掉的是家具的碰撞盒。
	_renumber_tables()
	_build_pathfinder()


## 采纳编辑器摆好的家具：逐个自绑定 + 注册。
##
## 【为什么按索引取 child，而不是取名字】家具名可以随你改，
## 名称不参与任何逻辑；唯一有语义的是「挂在 World 下」和「实现了自绑定入口」。
func _adopt_authored_furniture() -> void:
	var kids := world.get_children()
	for i in kids.size():
		var child := kids[i]
		if not child.has_method(EDITOR_SETUP):
			# 不是家具（比如你摆的装饰物）→ 跳过，不报错
			continue
		child.call(EDITOR_SETUP)
		_register_if_table(child)


## 采纳之后：World 里还缺哪几种家具，就按 layout.json 生成哪几种。
##
## 【判据是 kind，不是名字】`kind` 是家具自己声明的「我是什么」
## （桌子 = TABLE、柜台 = COUNTER…），ClickRouter 也靠它分辨点击目标。
## 用 kind 判断意味着：**你把柜台节点改名叫「点餐台」也照样认得出来**。
func _generate_missing_furniture() -> void:
	var lay := Config.layout

	if not _has_kind(Constants.Kind.TABLE):
		for entry in lay.get("tables", []):
			var t := StaticBody2D.new()
			t.set_script(TABLE_SCRIPT)
			t.name = "Table%d" % int(entry.get("id", 0))
			world.add_child(t)
			t.call("setup", int(entry.get("id", 0)),
				EntityBase.from_array(entry.get("rect", [])),
				_parse_seats(entry.get("seats", [])),
				1)   # 1 = 顺便生成椅子碰撞盒（这条路径没有 Chair 节点）
			_register_if_table(t)

	if not _has_kind(Constants.Kind.COUNTER):
		var kw: Dictionary = lay.get("kitchen_window", {})
		var kw_node := StaticBody2D.new()
		kw_node.set_script(KITCHEN_SCRIPT)
		kw_node.name = "KitchenWindow"
		world.add_child(kw_node)
		kw_node.call("setup",
			EntityBase.from_array(kw.get("rect", []), Rect2(420, 20, 240, 60)),
			EntityBase.from_array(kw.get("pickup_rect", []), Rect2(498, 50, 84, 30)),
			EntityBase.point_from_array(kw.get("walk", []), Vector2(540, 150)),
			EntityBase.point_from_array(kw.get("pickup_walk", []), Vector2(540, 140)),
			EntityBase.from_array(kw.get("bell_rect", []), Rect2(0, 0, 0, 0)))

	if not _has_kind(Constants.Kind.DRINK):
		var dm: Dictionary = lay.get("drink_machine", {})
		var dm_node := StaticBody2D.new()
		dm_node.set_script(DRINK_SCRIPT)
		dm_node.name = "DrinkMachine"
		world.add_child(dm_node)
		dm_node.call("setup",
			EntityBase.from_array(dm.get("rect", []), Rect2(860, 20, 80, 60)),
			EntityBase.point_from_array(dm.get("walk", []), Vector2(840, 150)))

	if not _has_kind(Constants.Kind.TRASH):
		var tr: Dictionary = lay.get("trash", {})
		var tr_node := StaticBody2D.new()
		tr_node.set_script(TRASH_SCRIPT)
		tr_node.name = "Trash"
		world.add_child(tr_node)
		tr_node.call("setup",
			EntityBase.from_array(tr.get("rect", []), Rect2(180, 640, 60, 60)),
			EntityBase.point_from_array(tr.get("walk", []), Vector2(270, 660)))

	if not _has_kind(Constants.Kind.DOOR):
		var dr: Dictionary = lay.get("door", {})
		var dr_node := StaticBody2D.new()
		dr_node.set_script(DOOR_SCRIPT)
		dr_node.name = "Door"
		world.add_child(dr_node)
		dr_node.call("setup",
			EntityBase.from_array(dr.get("rect", []), Rect2(560, 640, 120, 40)),
			EntityBase.point_from_array(dr.get("walk", []), Vector2(620, 600)),
			EntityBase.point_from_array(dr.get("spawn", []), Vector2(620, 600)))


## World 下有没有至少一件某种 kind 的家具？
func _has_kind(k: int) -> bool:
	for child in world.get_children():
		if int(child.get("kind")) == k:
			return true
	return false


## 是桌子就登记进 Game.tables，其余不登记。
##
## 【为什么按「有没有 table_id」判断类型，而不是判 is Table】
## 全工程一贯用鸭子类型（没有任何一处 is/as 具体家具类型），这里保持一致：
## 只有桌子才有 table_id 字段，所以「有这个字段」就是「是桌子」。
## 好处是以后你新加一种「也能坐人」的家具（比如吧台），只要给它 table_id
## 就自动被这套逻辑接纳，不用改这里。
func _register_if_table(child: Node) -> void:
	if child.get("table_id") == null:
		return
	Game.register_table(child)


## 编号用的排序键：先按 y 分行（行内视为同一排），行内再按 x 从左到右。
##
## 【为什么要抽成函数，而不是写在排序 lambda 里】
## lambda 的参数是 `Node`，`a.global_position` 拿到的静态类型是 Variant，
## GDScript 无法据此推断局部变量的类型 —— 会直接**解析失败**
## （`Cannot infer the type of "ay"`）。抽成一个返回 float 的函数就没有这个问题。
##
## 【为什么 y 要量化到 20px 的倍数】
## 同一排的桌子 y 未必严格相等（手摆时差一两个像素），
## 直接比较浮点会让「同一排」的判定变得随机。按半个格子量化，
## 同一排稳定归为同一个键。
static func _table_sort_key(t: Node) -> float:
	var pos: Vector2 = t.global_position
	var row := floorf(pos.y / 20.0)
	return row * 100000.0 + pos.x


## 给桌子定 table_id：手工优先，其余自动编号。
##
## 【为什么需要自动编号】Table.tscn 会被实例化多次（3 张桌 = 3 个实例），
## 而「实例之间必须有不同的 table_id」这件事没法写在一个 .tscn 里。
## 让代码按位置自动编号，你复制粘贴桌子时就不需要记得改编号。
##
## 【手工覆盖怎么生效】Table 上有个 `auto_table_id`（默认 true）。
## 把它关掉并手填 `table_id`，那张桌就跳过编号 —— 例如你要让某张桌固定叫「桌1」。
## 自动编号只会分配**没被手工占用**的号，所以两种方式能混用。
##
## 【为什么是「全部自动」而不是「只要有一个手填就整体放弃」】
## 后者是个陷阱：你手填了一张桌的编号，另外两张悄悄保留重复的 0，
## 而 0 也是合法编号 —— 不报错，只是选座顺序变得不可预期。
##
## 【排序规则：先按 y 分行、再按 x 从左到右】
## 复刻 layout.json 里「左/中/右三列 × 上/下两排」的既有约定，
## 让编号顺序可预期、可测试（不依赖场景树顺序）。
func _renumber_tables() -> void:
	var tables: Array = []
	for child in world.get_children():
		if child.get("table_id") != null:
			tables.append(child)
	if tables.is_empty():
		return

	tables.sort_custom(func(a: Node, b: Node) -> bool:
		return _table_sort_key(a) < _table_sort_key(b))

	# 先记下手工占用的编号（关掉 auto_table_id 的那些）
	var taken: Array[int] = []
	for t in tables:
		if not bool(t.get("auto_table_id")):
			taken.append(int(t.get("table_id")))

	# 再按位置顺序，给自动的那些分配未被占用的最小可用编号
	var next := 1
	for t in tables:
		if bool(t.get("auto_table_id")):
			while taken.has(next):
				next += 1
			t.set("table_id", next)
			taken.append(next)
			next += 1
		# 标签由编号推出，必须在编号定下来之后刷新
		# （HUD 和左侧订单票显示的就是它）
		var label := "桌%d" % int(t.get("table_id"))
		t.set("label", label)
		t.set("display_label", label)



## 建立寻路网格。
##
## 【为什么在摆完家具以后建】
## 障碍就是家具的碰撞盒，必须先全部就位。
## 网格是**静态**的：这个场景里没有任何家具会移动
## （脏/净、有无客人都不改变碰撞盒），所以只需要建一次。
## 以后要是加了会动的家具，记得在这里重建。
func _build_pathfinder() -> void:
	var obstacles: Array = []
	_collect_obstacles(world, obstacles)
	var pf := Node.new()
	pf.set_script(PATHFINDER_SCRIPT)
	pf.name = "Pathfinder"
	pf.add_to_group("pathfinder")
	add_child(pf)
	# 外扩量 = 服务员身体半径 + 余量。
	#
	# 【为什么必须 ≥ 服务员半径】
	# 网格只外扩了 6px 时，A* 会给出「圆心离家具只有 6~16px」的路径。
	# 服务员按这条线走，move_and_slide 会把他从家具里推出去 ——
	# 玩家看到的就是「擦着桌子走、体积重叠了一小部分」，
	# 而且被推开后还要重新调整，多走冤枉路。
	# 把外扩做成「身体半径 + 2」，算出来的路径本身就保证身体不碰家具，
	# 完全不需要物理去推 —— 贴边和绕路两个问题一起消失。
	pf.call("build", obstacles, WAITER_RADIUS + 2.0)
	pathfinder = pf


## 递归收集所有家具的碰撞形状，喂给寻路网格。
##
## 【每件家具的每一个碰撞形状分别作为障碍】
## 【不要用合并矩形】曾经把桌子和椅子并成一块喂进来，想消灭它们之间
## 那条 8px 窄缝；结果椅子那块也被封死，座位在网格里变得不可达，
## 目标点落在障碍内部 → A* 只能给斜线（玩家反馈的「靠近桌椅就出斜线」）。
## 分开喂：椅子下方开放、座位可达，窄缝靠「外扩 ≥ 服务员半径」自动吃掉。
##
## 【为什么要递归，而不是只看 World 的直接子节点】
## 椅子现在是**挂在桌子下面的独立 StaticBody2D**（这样它才能自己拥有碰撞盒）。
## 只遍历直接子节点的话，所有椅子的碰撞盒都会被**静默漏掉** ——
## 表现是「服务员穿过椅子走过去」，不报错，很难查。
func _collect_obstacles(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child.has_method("collision_shapes_global"):
			for box in child.call("collision_shapes_global"):
				if box.size.x > 0.0 and box.size.y > 0.0:
					out.append(box)
		# 继续往下找（桌子的子节点里挂着椅子）
		if child.get_child_count() > 0:
			_collect_obstacles(child, out)


## 把 layout.json 里的 seats 数组解析成 Table.setup 要的形式
func _parse_seats(raw: Variant) -> Array:
	var out: Array = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for s in raw:
		if typeof(s) != TYPE_DICTIONARY:
			continue
		out.append({
			"pos": EntityBase.point_from_array(s.get("pos", []), Vector2.ZERO),
			"size": EntityBase.point_from_array(s.get("size", []), Vector2(40, 30)),
			"facing": int(s.get("facing", 0)),
		})
	return out


func _build_actors() -> void:
	# 【复用而不是无脑新建】这三个容器/节点原本全是代码运行时造的。
	# 但「家具改由编辑器摆放」之后，你有可能也想在编辑器里直接放 Actors/Waiter ——
	# 那时 add_child 一个同名节点会造成**重复**（两个 Waiter，一个在跑、一个在那儿）。
	# 所以先找已有的，找不到再建。
	actors = _ensure_node2d("Actors", self)
	customers = _ensure_node2d("Customers", actors)

	waiter = _ensure_waiter()


## 拿到指定名字的 Node2D 子节点；没有就新建一个。
func _ensure_node2d(node_name: String, parent: Node) -> Node2D:
	var existing := parent.get_node_or_null(node_name)
	if existing is Node2D:
		return existing as Node2D
	var made := Node2D.new()
	made.name = node_name
	parent.add_child(made)
	return made


## 服务员：复用 Actors 下已有的，没有才新建。
func _ensure_waiter() -> Node:
	var existing := actors.get_node_or_null("Waiter")
	if existing is CharacterBody2D:
		return existing
	var made := CharacterBody2D.new()
	made.set_script(WAITER_SCRIPT)
	made.name = "Waiter"
	made.position = _waiter_spawn_point()
	actors.add_child(made)
	return made


## 从编辑器摆好的出生点取坐标（**仅编辑器摆放模式**）。
##
## 【为什么要这个】出生点原先写死读 `layout.json` 的 `waiter_spawn`（= 640,240），
## 那是**旧 1280×720 布局的中心**。你把场景缩成左上角一小块之后，
## 那个坐标落在相机视野之外 —— 表现是「一开局服务员就卡在屏幕外」，而且不报错。
##
## 【怎么摆】在 Level 下加一个 Node2D，命名 `WaiterSpawn`，拖到你要的位置。
## 生成模式（工具/测试）找不到它时自动退回 JSON 坐标，行为完全不变。
func _authored_waiter_spawn() -> Variant:
	var probe := get_node_or_null("WaiterSpawn")
	if probe is Node2D:
		return (probe as Node2D).global_position
	return null


## 本局服务员该站在哪。三级优先：
##
##   1. **`WaiterSpawn` 节点**（你在编辑器里摆的 Node2D）—— 最可控，推荐
##   2. **相机视野中心** —— 保证「一定看得见」，不用你摆任何东西
##   3. `layout.json` 的 `waiter_spawn` —— 生成模式（工具/测试）的旧行为
##
## 【为什么需要 2 这个兜底】出生点原来是写死的 `layout.json` 坐标（640,240），
## 属于旧 1280×720 布局。你把场景缩到左上角一小块之后它就落到相机外了 ——
## 表现是「一开局服务员卡在屏幕外」，且**不报错**。
## 用相机视野中心兜底之后，**哪怕你什么都不摆，服务员也一定在画面里**。
func _waiter_spawn_point() -> Vector2:
	var authored: Variant = _authored_waiter_spawn()
	if authored != null:
		return authored
	var cam_center: Variant = _camera_view_center()
	if cam_center != null:
		return cam_center
	return EntityBase.point_from_array(
		Config.layout.get("waiter_spawn", []), Vector2(560, 500))


## 当前相机看到的区域中心（世界坐标）；没有相机时返回 null。
func _camera_view_center() -> Variant:
	var vp := get_viewport()
	if vp == null:
		return null
	var cam := vp.get_camera_2d()
	if cam == null:
		return null
	return cam.global_position


func _build_systems() -> void:
	router = Node.new()
	router.set_script(ROUTER_SCRIPT)
	router.name = "ClickRouter"
	router.waiter = waiter
	router.world = world
	router.customers = customers
	add_child(router)

	spawner = Node2D.new()
	spawner.set_script(SPAWNER_SCRIPT)
	spawner.name = "CustomerSpawner"
	add_child(spawner)
	spawner.call("setup", customers, self)


func make_customer() -> Node:
	var c := Node2D.new()
	c.set_script(CUSTOMER_SCRIPT)
	c.name = "Customer"
	return c


# ── 每帧 ───────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_update_hover()

	# 【倒计时不在这里推进】已与用户确认「弹窗期间倒计时照走」，
	# 而弹窗会把整棵树 paused，引擎不给暂停树里的节点发 _process ——
	# 所以计时放在 UIManager（PROCESS_MODE_ALWAYS）里，见那里的 _process。
	# 这里只保留「世界该不该推进」这一层。

	if not UI.should_process_world():
		return

	Game.update_kitchen(delta)

	_hud_clock += delta
	if _hud_clock >= _hud_interval:
		_hud_clock = 0.0
		_pump_hud()


## 由 UI 在结算界面按「下一关」时调用：推进关卡并重开一局。
func restart_at_level(index1: int) -> void:
	Game.set_level_index(index1)
	_start_level_run()


## 重开当前关（结算界面按「重试本关」）
func restart_current_level() -> void:
	_start_level_run()


## 把「一局的开始」收敛到这一处：
## 清世界（客人 / 桌子 / 手 / 后厨）→ 重置进度 → 开始本关倒计时。
##
## 【为什么每次都重建场景树里的东西】一局结束时不保证所有客人都走了
## （可能还有人在店里吃），桌子也可能是脏的。逐样清理一定会漏
## （漏了就会「新一局开局就是脏桌 / 有客人」），
## 所以这里直接复用 Level 自己的搭建流程重新来一遍。
func _start_level_run() -> void:
	# 清掉上一局残留的客人
	if customers != null:
		for c in customers.get_children():
			c.queue_free()
	# 桌子回到干净、无单、无客。
	# 【必须走 reset_to_clean() 而不是直接写 state】直接改字段只改数据、
	# 不刷新视觉（桌子的颜色/脏点靠 _refresh_look 里的 queue_redraw）——
	# 表现是「上一局的脏桌进了新一局还显示是脏的，要等鼠标动一下才变干净」
	# （玩家实测报的 bug）。
	for t in Game.tables:
		if not is_instance_valid(t):
			continue
		if t.has_method("reset_to_clean"):
			t.call("reset_to_clean")
	Game.reset_table_availability()
	# 手上的菜：**必须先同步服务员的视觉标记**
	# 走 router.clear_hand() 而不是 Game.clear_hand() ——
	# 后者只清数据；服务员肩上那两个方块是 router._sync_carried() 刷的，
	# 漏了它就会「小人手上还端着上一关的餐品，图标不消失」（玩家实测报的 bug）。
	if router != null and router.has_method("clear_hand"):
		router.call("clear_hand")
	# 进度：营收 / 接待 / 手 / 后厨 —— 用 reset_progress() 而**不是** reset()：
	# reset() 会连 tables 注册表一起清空，而桌子只在 Level._ready 里注册一次，
	# 清掉之后客人永远生不出来（真踩过：点开始后店里 0 位客人）。
	Game.reset_progress()
	# 服务员归位、解锁（上一局可能正卡在收拾中途）
	if waiter != null:
		# 【必须显式取消】上一局结束时服务员可能正走去收拾、或正在收拾。
		# 不取消的后果：新一局开局服务员还锁着（点什么都没反应），
		# 而且那张桌子会一直挂着「正在收拾」的登记 —— 永久不可坐。
		if waiter.has_method("cancel_command"):
			waiter.call("cancel_command", "")
		waiter.global_position = _waiter_spawn_point()
	# 兜底：把「正在收拾」登记表整个清掉。任何一处漏了解除都会让那张桌
	# 永久不可坐（不报错），而开局时本来就不可能有桌子在处理中。
	TableRules.clear_all_cleaning()
	# 【reset() 会把 run_active 清掉，所以「开一局」必须紧跟其后】
	# 顺序反了的表现是「点了下一关，倒计时却不动」—— 一个不报错的死局。
	Game.start_level(Game.level_index)
	_pump_hud()


func _update_hover() -> void:
	if world == null or router == null:
		return
	var popup_open: bool = bool(UI.is_any_popup_open())
	var locked: bool = bool(waiter.is_locked())
	var enabled: bool = not popup_open and not locked
	for child in world.get_children():
		if child.has_method("update_hover"):
			child.update_hover(router.mouse_world, enabled)


func _pump_hud() -> void:
	var snap := Game.hud_snapshot(spawner.call("in_store_count") if spawner != null else 0)
	snap["hand"] = Game.hand_items()
	UI.apply_snapshot(snap)


func _on_orders_changed() -> void:
	UI.refresh_orders(Game.active_orders())


# ── 客人生命周期回调 ───────────────────────────────────────────────

func _on_customer_seated(c: Node) -> void:
	# 客人落座 → 把自己的菜记在座位上，进入 WAITING_TO_ORDER。
	#
	# 【注意：这里**不建 Order、也不挂到桌上**】
	# 订单是**桌级共享**的，而且要等玩家真的来接单才开票。
	# 在这里建票的话，客人刚坐下、玩家还没动，左侧订单栏就冒出来了 ——
	# 文档第五节说的是「玩家接单 → 订单栏生成一张票」，票是接单的结果。
	seated_total += 1
	c.call("take_order")
	_on_orders_changed()
	Stickers.push_world(c.global_position + Vector2(0, -52), "来客人了", Constants.COLOR_TEXT_DIM)


func _on_customer_gone(c: Node) -> void:
	if is_instance_valid(c):
		c.queue_free()
	_on_orders_changed()
