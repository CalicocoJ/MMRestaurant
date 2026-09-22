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
const FLOOR_SCRIPT := preload("res://scripts/level/floor_art.gd")
const PATHFINDER_SCRIPT := preload("res://scripts/core/pathfinder.gd")
## 服务员身体半径：寻路外扩量要跟它对齐（见下面 build 的说明）
const WAITER_RADIUS := 16.0

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
	_build_background()
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

func _build_background() -> void:
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

	var floor_art := Node2D.new()
	floor_art.set_script(FLOOR_SCRIPT)
	floor_art.name = "FloorArt"
	add_child(floor_art)


func _build_world() -> void:
	world = Node2D.new()
	world.name = "World"
	add_child(world)

	var lay := Config.layout
	# 家具都要挡人，所以统一建成 StaticBody2D（= WorldObject 的原生类型）

	# 桌子（自带座位 / 椅子）
	for entry in lay.get("tables", []):
		var t := StaticBody2D.new()
		t.set_script(TABLE_SCRIPT)
		t.name = "Table%d" % int(entry.get("id", 0))
		world.add_child(t)
		t.call("setup", int(entry.get("id", 0)),
			EntityBase.from_array(entry.get("rect", [])),
			_parse_seats(entry.get("seats", [])))
		Game.register_table(t)

	# 后厨 / 出餐口
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

	# 饮料机
	var dm: Dictionary = lay.get("drink_machine", {})
	var dm_node := StaticBody2D.new()
	dm_node.set_script(DRINK_SCRIPT)
	dm_node.name = "DrinkMachine"
	world.add_child(dm_node)
	dm_node.call("setup",
		EntityBase.from_array(dm.get("rect", []), Rect2(860, 20, 80, 60)),
		EntityBase.point_from_array(dm.get("walk", []), Vector2(840, 150)))

	# 垃圾桶
	var tr: Dictionary = lay.get("trash", {})
	var tr_node := StaticBody2D.new()
	tr_node.set_script(TRASH_SCRIPT)
	tr_node.name = "Trash"
	world.add_child(tr_node)
	tr_node.call("setup",
		EntityBase.from_array(tr.get("rect", []), Rect2(180, 640, 60, 60)),
		EntityBase.point_from_array(tr.get("walk", []), Vector2(270, 660)))

	# 门口
	var dr: Dictionary = lay.get("door", {})
	var dr_node := StaticBody2D.new()
	dr_node.set_script(DOOR_SCRIPT)
	dr_node.name = "Door"
	world.add_child(dr_node)
	dr_node.call("setup",
		EntityBase.from_array(dr.get("rect", []), Rect2(560, 640, 120, 40)),
		EntityBase.point_from_array(dr.get("walk", []), Vector2(620, 600)),
		EntityBase.point_from_array(dr.get("spawn", []), Vector2(620, 600)))

	_build_pathfinder()


## 建立寻路网格。
##
## 【为什么在摆完家具以后建】
## 障碍就是家具的碰撞盒，必须先全部就位。
## 网格是**静态**的：这个场景里没有任何家具会移动
## （脏/净、有无客人都不改变碰撞盒），所以只需要建一次。
## 以后要是加了会动的家具，记得在这里重建。
func _build_pathfinder() -> void:
	var obstacles: Array = []
	for child in world.get_children():
		# 每件家具的**每一个碰撞形状**分别作为障碍（桌子 + 每把椅子）。
		#
		# 【不要用合并矩形】曾经把桌子和椅子并成一块喂进来，想消灭它们之间
		# 那条 8px 窄缝；结果椅子那块也被封死，座位在网格里变得不可达，
		# 目标点落在障碍内部 → A* 只能给斜线（玩家反馈的「靠近桌椅就出斜线」）。
		# 现在分开喂：椅子下方开放、座位可达，而那条窄缝靠「外扩 ≥ 服务员半径」
		# 自动被吃掉（它本来也过不去）。
		if child.has_method("collision_shapes_global"):
			for box in child.call("collision_shapes_global"):
				if box.size.x > 0.0 and box.size.y > 0.0:
					obstacles.append(box)
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
	actors = Node2D.new()
	actors.name = "Actors"
	add_child(actors)

	customers = Node2D.new()
	customers.name = "Customers"
	actors.add_child(customers)

	waiter = CharacterBody2D.new()
	waiter.set_script(WAITER_SCRIPT)
	waiter.name = "Waiter"
	waiter.position = EntityBase.point_from_array(Config.layout.get("waiter_spawn", []), Vector2(560, 500))
	actors.add_child(waiter)


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
		waiter.global_position = EntityBase.point_from_array(
			Config.layout.get("waiter_spawn", []), Vector2(560, 500))
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
