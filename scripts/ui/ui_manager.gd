extends CanvasLayer
## UI 总管（autoload 名 = UI）。
##
## 【职责】
##   1. 建 HUD、按需建两个弹窗
##   2. 拥有「暂停」这件事：弹窗开着 → get_tree().paused = true
##
## 【暂停为什么不用 process_mode 分给每个节点去管】
## 文档第十七节要求「暂停期间：客人耐心不减少、后厨计时暂停、
## 服务员停止移动、客人停止移动、飘字提示不消失」。
## 前四条 = 整个场景树停住，就是 get_tree().paused。
## 第五条 = Stickers 是 PROCESS_MODE_ALWAYS 且自己冻结生命周期。
## 所以暂停只需要两处配合，弹窗这边只管开关。

const HUD_SCRIPT := preload("res://scripts/ui/hud.gd")
const KITCHEN_POPUP_SCRIPT := preload("res://scripts/ui/kitchen_popup.gd")
const DRINK_POPUP_SCRIPT := preload("res://scripts/ui/drink_popup.gd")
const START_SCREEN_SCRIPT := preload("res://scripts/ui/start_screen.gd")
const RESULT_PANEL_SCRIPT := preload("res://scripts/ui/result_panel.gd")

## 玩家按下「开始游戏」/ 结算界面按下「下一关」时发出。
## 【为什么需要这个信号】「一局什么时候开始计时」这件事只有 UI 知道
## （开始按钮在它手里），而「计时归谁推进」是 Level 的事。
## 让 Level 订阅这个信号，两边就不用互相持有引用。
signal run_requested

var router: Node = null
var hud: Control = null

var _root: Control = null
var _popup_root: Control = null
var _popup_layer: CanvasLayer = null
var _kitchen: Control = null
var _drink: Control = null
var _start: Control = null
## 开始界面自己的层。见 _ready 里「三层」那段说明。
var _start_layer: CanvasLayer = null
var _result: Control = null
var _result_layer: CanvasLayer = null


func _ready() -> void:
	layer = 10
	# 暂停时 UI 必须还能点，否则「完成/取消」按钮按不动，游戏永远卡在暂停
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 【本关倒计时由这里推进，而不是 Level._process】
	# 已与用户确认：打开后厨 / 饮料机弹窗时**倒计时照走**。
	# 但弹窗会把整棵树 paused = true，而引擎**不给暂停树里的节点发 _process** ——
	# 所以放在 Level._process 里的计时代码在弹窗期间根本不会执行。
	# UiManager 是 PROCESS_MODE_ALWAYS，是唯一能在暂停期间继续跑的地方。
	set_process(true)
	# 【这根线不能少】本局结束（时间到）时 Game 会发 level_finished，
	# 结算界面由这里弹出来。
	# 曾经漏掉它，表现是「时间到了什么都不发生」——而且因为结算面板的标题
	# 在 build() 里已有默认文字，界面上看着还挺正常，非常能骗人。
	if not Game.level_finished.is_connected(_on_level_finished):
		Game.level_finished.connect(_on_level_finished)

	_root = Control.new()
	_root.name = "UIRoot"
	# 不用锚点：见下面「关键 2」。尺寸统一由 _sync_root_size() 显式给。
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_root)

	# 【关键 1】CanvasLayer 的 Control 子节点**不会**自动被撑满视口。
	# 锚点只有在父 Control 有真实尺寸时才算得对；父尺寸是 0 的时候，
	# 锚点全部退化到原点 ——「手上：空手」于是被算到 y=-54，
	# 安静地跑到屏幕外面，不报错、不警告，单纯看不见。
	#
	# 【关键 2】set_anchors_preset 只改锚点，**不会**把 0 尺寸的节点撑开；
	# 而且给「锚点非对称」的节点赋 size 会被引擎在 _ready 后覆盖掉
	# （"Nodes with non-equal opposite anchors will have their size overridden"）。
	# 所以这里干脆不用锚点，root / hud 全部显式摆位，行为完全确定。
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.process_mode = Node.PROCESS_MODE_ALWAYS
	hud = Control.new()
	hud.set_script(HUD_SCRIPT)
	hud.name = "HUD"
	_root.add_child(hud)

	# 弹窗单独一层，图层号比 HUD 高。
	# 【为什么必须分开】
	# 同一个 CanvasLayer 里，兄弟节点的绘制顺序按树序来 ——
	# 但 HUD 在弹窗之前建好，弹窗的遮罩就盖不住 HUD。
	# 结果是弹窗打开时左上角的钱、订单栏还是亮的，
	# 「游戏已暂停、点外面没反应」这件事在视觉上说不通。
	#
	# 【为什么开始界面要自己的第三层】
	# 开始界面必须盖住 HUD（标题画面不该露出钱和订单栏），
	# 但它本身在游戏开始后就永远不再出现，不该占用 layer+5 ——
	# 那个数字是「弹窗盖住一切」用的。所以：
	#   layer+2  开始界面  >  HUD（同一层，但树序在后）
	#   layer+5  弹窗      >  开始界面
	# 于是弹窗仍然盖得住所有东西，而这个层级关系是三行配置就能读出来的。
	_popup_root = Control.new()
	_popup_root.name = "PopupRoot"
	_popup_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_popup_root.process_mode = Node.PROCESS_MODE_ALWAYS
	_popup_layer = CanvasLayer.new()
	_popup_layer.name = "PopupLayer"
	_popup_layer.layer = layer + 5
	_popup_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_popup_layer)
	_popup_layer.add_child(_popup_root)

	_start = Control.new()
	_start.set_script(START_SCREEN_SCRIPT)
	_start.name = "StartScreen"
	_start.process_mode = Node.PROCESS_MODE_ALWAYS
	_start.mouse_filter = Control.MOUSE_FILTER_STOP
	_start.visible = false
	_start_layer = CanvasLayer.new()
	_start_layer.name = "StartLayer"
	_start_layer.layer = layer + 2
	_start_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_start_layer)
	_start_layer.add_child(_start)
	_start.call("build")
	_start.connect("action_pressed", _on_start_pressed)

	# 结算界面：单独一层，排在弹窗之上。
	# 【为什么比弹窗还高】时间到时如果玩家正开着后厨 UI，结算必须盖住它 ——
	# 否则「一局已经结束了」而弹窗还挂在上面，玩家会以为还能操作。
	# 层序：HUD(10) < 开始界面(12) < 弹窗(15) < 结算(16)
	_result = Control.new()
	_result.set_script(RESULT_PANEL_SCRIPT)
	_result.name = "ResultPanel"
	_result.process_mode = Node.PROCESS_MODE_ALWAYS
	_result.mouse_filter = Control.MOUSE_FILTER_STOP
	_result.visible = false
	_result_layer = CanvasLayer.new()
	_result_layer.name = "ResultLayer"
	_result_layer.layer = layer + 6
	_result_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_result_layer)
	_result_layer.add_child(_result)
	_result.call("build")
	_result.connect("action_pressed", _on_result_action)

	_sync_root_size()

	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_viewport_resized):
		vp.size_changed.connect(_on_viewport_resized)


func _on_viewport_resized() -> void:
	_sync_root_size()


## 每帧推进本关倒计时。
##
## 【为什么在 UI 这边】见 _ready 里的说明：唯一能在「世界暂停」期间
## 继续跑的地方就是 PROCESS_MODE_ALWAYS 的节点。
## 【为什么开场界面期间不会走】Game.is_run_active() 为 false
## （标题画面时本局还没开始），所以这里直接返回。
## 【为什么结算界面期间也不会走】时间到时 Game 已经把 run_active 置 false。
func _process(delta: float) -> void:
	if not Game.is_run_active():
		return
	if Game.tick(delta):
		# 本局刚刚结束。show_result 由 level_finished 信号触发（见 _ready），
		# 这里只负责把 HUD 的最后一帧刷成 0:00 —— 否则结算前那一瞬
		# 玩家看到的是 0.1 秒而不是 0。
		if hud != null:
			hud.call("apply", Game.hud_snapshot(0))


## 本局结束：弹结算界面。
func _on_level_finished() -> void:
	show_result(true)


func _sync_root_size() -> void:
	var s := Vector2(1280, 720)
	var vp := get_viewport()
	if vp != null:
		var vr := vp.get_visible_rect().size
		if vr.x > 0.0 and vr.y > 0.0:
			s = vr
	if _root != null:
		_root.position = Vector2.ZERO
		_root.size = s
	if hud != null:
		hud.position = Vector2.ZERO
		hud.size = s
	if _popup_root != null:
		_popup_root.position = Vector2.ZERO
		_popup_root.size = s
	if _start != null:
		_start.call("apply_size", s)
	if _result != null:
		_result.call("apply_size", s)
	if _kitchen != null:
		_kitchen.position = Vector2.ZERO
		_kitchen.size = s
	if _drink != null:
		_drink.position = Vector2.ZERO
		_drink.size = s
	# 遮罩要跟着一起撑满，否则「点 UI 外面无反应」在视觉上没有着落，
	# 场景看起来像还能点（尤其是弹窗后面的桌子和客人）。
	_size_dimmer(_kitchen)
	_size_dimmer(_drink)


func _size_dimmer(popup: Control) -> void:
	if popup == null:
		return
	var dim := popup.get_node_or_null("Dim") as Control
	if dim != null:
		dim.position = Vector2.ZERO
		dim.size = popup.size


## 由 Level 在搭好场景、拿到 router 之后调用
func setup(p_router: Node) -> void:
	router = p_router
	_sync_root_size()
	# HUD 的 build() 需要在 _ready 之后调，所以这里用 call_deferred 保险
	hud.call("build")

	_kitchen = Control.new()
	_kitchen.set_script(KITCHEN_POPUP_SCRIPT)
	_kitchen.name = "KitchenPopup"
	_kitchen.visible = false
	_kitchen.process_mode = Node.PROCESS_MODE_ALWAYS
	_kitchen.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(_kitchen)
	_kitchen.call("build", router)

	_drink = Control.new()
	_drink.set_script(DRINK_POPUP_SCRIPT)
	_drink.name = "DrinkPopup"
	_drink.visible = false
	_drink.process_mode = Node.PROCESS_MODE_ALWAYS
	_drink.mouse_filter = Control.MOUSE_FILTER_STOP
	_popup_root.add_child(_drink)
	_drink.call("build", router)

	# 两个全屏容器统一在这一处定尺寸（弹窗是 _popup_root 的子节点，一起撑满）
	_sync_root_size()


# ── 开始界面 ───────────────────────────────────────────────────────
#
# 【游戏一开始必须经过这里】
# Level 只在「主场景直接运行」时调 begin() —— 见 level.gd 里的说明。
# 工具脚本把 main.tscn 挂在自己的节点 / SubViewport 下，因此天然跳过
# 开始界面，18 个测试脚本一行都不用改。

## show_it = true：显示开始界面并把世界冻住（玩家还没开始）。
## show_it = false：直接进入游戏（工具脚本 / 主场景之外的地方用）。
##
## 【为什么这里要连 HUD 一起隐藏，而不是靠遮罩盖住】
## 实测：只靠 ColorRect 遮罩是盖不住的 —— 第一版遮罩给了 82% 不透明度，
## HUD 那几行白字在半透明黑底下依然清晰可见：截图里左上角还能看到
## 「钱：0 元 / 已接待人数：0 …」、左下角「手上：空手」。
## 「标题画面」于是变成了「游戏上面蒙了一层灰」。
##
## 所以职责分清楚：
##   遮罩     → 压暗**世界**（餐厅画面）。当前用户选择「一点餐厅都不露」，
##              所以它是 alpha = 1.0 的纯黑；将来想透出餐厅只改这一处。
##   HUD 显隐 → 由这里显式开关，一个字都不露。
##
## 【对称性提醒】隐藏 HUD 的出口有**两个**：本函数的 show_it = false，
## 以及 begin_game()。两处都必须恢复 HUD.visible，缺一处就会出现
## 「进游戏后没有 HUD」这种不报错的故障。
func begin(show_it: bool) -> void:
	if _start != null:
		_start.call("begin", show_it)
	if hud != null:
		hud.visible = not show_it
	_set_paused(show_it)


## 玩家点了「开始游戏」。
func _on_start_pressed() -> void:
	begin_game()


## 进入游戏：收起开始界面、解除冻结。
##
## 【为什么这里不直接开始计时】本局的重置与计时启动在 Level 那边
## （要清客人、清桌子、把服务员归位），UI 不该知道这些细节。
## 所以只发一个 run_requested，由 Level 订阅后调 _start_level_run()。
func begin_game() -> void:
	if _start != null:
		_start.call("begin", false)
	# 【HUD 必须在这里显式恢复】它是在 begin(true) 里被隐藏的，
	# 而本方法走的是「收起界面」这条路，不经过 begin() ——
	# 忘了这一行，玩家一点「开始游戏」就会进到一个**没有 HUD** 的游戏里
	# （钱、订单栏、手上的餐全都不显示，而且不会报任何错）。
	if hud != null:
		hud.visible = true
	_set_paused(false)
	Game.reset_table_availability()
	run_requested.emit()


## 开始界面还开着吗（工具 / 测试用）
func is_start_screen_open() -> bool:
	return _start != null and _start.visible


## 给工具 / 测试用：拿到开始界面节点
func start_screen() -> Control:
	return _start


## 给工具用：直接按一次「开始游戏」，走完整条按钮链路
func press_start() -> void:
	var btn: Button = null
	if _start != null:
		btn = _start.call("start_button")
	if btn != null:
		btn.emit_signal("pressed")
	else:
		begin_game()


# ── 结算界面 ───────────────────────────────────────────────────────

## 显示结算界面（本局结束）。由 Level 在时间到时调用。
##
## 【参数为什么要传进来而不是让面板自己读 Game】结算界面只负责显示。
## 让它自己去读 Game 会让「读的是不是结算那一刻的值」变得含糊 ——
## 时间到之后如果还有客人走到门口结账，money 会再变一次。
##
## 【这里必须把世界冻住】结算界面出现 = 本局结束，
## 不该再有人在店里走动，也不该再有客人被生成。
func show_result(_unused: bool = false) -> void:
	# 【必须把飘字清掉】飘字层（Stickers）在 layer 20，比结算层（16）还高；
	# 而暂停时它自己会冻结生命周期（那是既有设计：文档要求「暂停期间飘字不消失」）。
	# 两条合起来 = 本局最后一句飘字（比如「来客人了」）会**冻在结算界面上**，
	# 截图里能清楚看到。飘字是「这一局进行中」的即时反馈，本局已结束，
	# 留着它既没用又难看。
	Stickers.clear()
	var passed := Game.passed()
	var lv := Config.level_at(Game.level_index)
	if _result != null:
		_result.call("fill",
			Game.level_index,
			String(lv.get("name", "")),
			Game.money,
			Game.target_money(),
			Game.served_count,
			passed,
			Game.has_next_level(),
			Game.stars())
		_result.visible = true
	if hud != null:
		hud.visible = false
	_set_paused(true)


func is_result_open() -> bool:
	return _result != null and _result.visible


## 给工具 / 测试用：拿到结算界面节点
func result_panel() -> Control:
	return _result


## 给工具 / 测试用：按一次结算界面上的按钮（走完整条按钮链路）
func press_result_action() -> void:
	var btn: Button = null
	if _result != null:
		btn = _result.call("action_button")
	if btn != null:
		btn.emit_signal("pressed")
	else:
		_on_result_action()


## 结算界面的按钮被按下：按当前动作推进。
##   达标且有下一关 → 下一关
##   达标但已是最后一关 → 回第 1 关重玩（没有第 6 关，总得给个出口）
##   未达标 → 重试本关
func _on_result_action() -> void:
	var kind := ""
	if _result != null:
		kind = String(_result.call("action_kind"))
	var target_index := Game.level_index
	match kind:
		"next":
			target_index = Game.level_index + 1
		"retry":
			target_index = Game.level_index
		"replay":
			target_index = 1
	hide_result()
	request_run_at(target_index)


## 收起结算界面并恢复世界（真正的「开始本局」由 Level 收到信号后做）
func hide_result() -> void:
	if _result != null:
		_result.visible = false
	if hud != null:
		hud.visible = true
	_set_paused(false)
	Game.reset_table_availability()


## 请求从第 index1 关重新开始一局。
## 【为什么走信号而不是直接改 Game】开始一局要清客人、清桌子、把服务员
## 归位 —— 那些是 Level 的职责。UI 只发意图，不越过界去动场景。
func request_run_at(index1: int) -> void:
	Game.set_level_index(index1)
	run_requested.emit()


# ── 弹窗 ───────────────────────────────────────────────────────────

func open_kitchen() -> void:
	_drink.visible = false
	_kitchen.visible = true
	_set_paused(true)


func open_drink_machine() -> void:
	_kitchen.visible = false
	# 【打开时按当前关卡刷新菜单】饮品有 start_level 解锁（柠檬水第 3 关才有），
	# 而弹窗节点跨关卡复用 —— 不刷新就会拿上一关的菜单。
	if _drink != null and _drink.has_method("refresh_menu"):
		_drink.call("refresh_menu")
	_drink.visible = true
	_set_paused(true)


func close_popups() -> void:
	_kitchen.visible = false
	_drink.visible = false
	_set_paused(false)


func is_any_popup_open() -> bool:
	return (_kitchen != null and _kitchen.visible) or (_drink != null and _drink.visible)


## 给工具/测试用：拿到两个弹窗节点
func kitchen_popup() -> Control:
	return _kitchen


func drink_popup() -> Control:
	return _drink


func is_paused_by_ui() -> bool:
	return _paused


var _paused: bool = false


func _set_paused(v: bool) -> void:
	_paused = v
	var tree := get_tree()
	if tree != null:
		tree.paused = v


## 世界该不该按帧推进。
## 用显式标志位而不是 get_tree().paused，是为了让测试脚本
## 可以在不真正暂停场景树的情况下驱动整个游戏逻辑。
func should_process_world() -> bool:
	return not _paused


# ── 给 Level 转发的便捷方法 ────────────────────────────────────────

func apply_snapshot(snapshot: Dictionary) -> void:
	if hud != null and hud.has_method("apply"):
		hud.apply(snapshot)


func refresh_orders(orders: Array) -> void:
	if hud != null and hud.has_method("refresh_orders"):
		hud.refresh_orders(orders)
