extends Node
## 对局状态（autoload 名 = Game）。
##
## 【职责】
## 钱、已接待人数、出餐口、后厨队列、玩家手上的餐品、桌子登记处。
## 它是唯一持有「进度」的地方；场景里的节点只负责表现和输入。
##
## 【为什么桌子登记处也放这里】
## 客人生成、HUD 统计、订单栏都需要遍历桌子。
## 让桌子在 _ready() 时自己注册进来，就不用在任何脚本里手工登记
## （以后加桌子只要改 data/layout.json）。

signal money_changed(money: int)
signal hand_changed(item_id: String)
signal orders_changed
signal queue_changed
## 本局结束（时间到）。UI 收到后弹结算界面。
## 【为什么由 Game 发信号】它是唯一知道「一局什么时候开始/结束」的地方；
## 让 Level 轮询再回调 UI 也能做，但那样「谁负责判定终局」就有两处说法。
signal level_finished

## 后厨对象被换了一个（开新一局会重建 Kitchen）。
##
## 【为什么必须有这个信号】出餐口的**视觉刷新**靠订阅
## `Kitchen.counter_changed`（见 kitchen_window.gd）。而开新一局时
## `reset_progress()` 会 **new 一个新的 Kitchen** —— 出餐口还挂在旧对象上，
## 新对象的信号没人听，于是「把餐取走后图标不消失，要动一下鼠标才更新」
## （玩家实测报的 bug：延迟 1~2 秒）。拿到新 Kitchen 的订阅者必须重绑。
signal kitchen_changed

var money: int = 0
var served_count: int = 0
var angry_count: int = 0

## 当前第几关（从 1 开始）。一局 = 一关。
var level_index: int = 1
## 本关剩余时间（秒）。只在「本局进行中」递减 —— 见 Level._process。
var time_left: float = 0.0
## 本局是否正在进行（已开始、且尚未结算）。
## 【它和 get_tree().paused 是两件事】暂停是「世界不推进」，
## 而本局的倒计时**在弹窗期间照走**（已与用户确认）。
## 所以判断「要不要扣时间」只能看这个标志，不能看 paused。
var run_active: bool = false

## 玩家手上：一个**列表**，最多 hand_capacity() 份（默认 2）。
## 空列表 = 空手。
var hand: Array[String] = []

var kitchen: Kitchen = null

## 桌子登记处（Table 节点会自己 append）
var tables: Array = []

var rng := RandomNumberGenerator.new()


func _ready() -> void:
	rng.randomize()
	kitchen = Kitchen.new(Config.num("kitchen_cook_time"), int(Config.config.get("counter_capacity", 1)))


## 由 Level 在建立对局时调用，**只在场景第一次搭起来时**用。
##
## 【注意它会清空 tables 注册表】桌子是在 Level._ready 里逐个 register 的，
## 所以这个函数**不能**在「重开一局」时用 —— 那时 Level 不会重新注册桌子，
## 清空之后 Game.tables 就一直是空的，客人再也生不出来（真踩过：
## 点「开始游戏」后店里永远 0 位客人）。
## 重开一局请用 reset_progress()。
func reset() -> void:
	reset_progress()
	tables.clear()
	orders_changed.emit()
	queue_changed.emit()


## 只重置「本局的进度」，**不碰桌子注册表**。
##
## 【为什么必须和 reset() 分开】「重开一局」要清的是钱、接待数、手上的菜、
## 后厨队列；而桌子、寻路网格这些是**场景结构**，重建它们既没必要也危险
## （见 reset() 的说明）。两件事混在一起就会出现「新一局一张桌子都没有」。
##
## 【换 Kitchen 必须广播 kitchen_changed】见那个信号的说明：
## 出餐口的视觉刷新订阅在 Kitchen 上，换了对象不重绑就会「图标不消失」。
func reset_progress() -> void:
	money = 0
	served_count = 0
	angry_count = 0
	hand.clear()
	kitchen = Kitchen.new(Config.num("kitchen_cook_time"), int(Config.config.get("counter_capacity", 1)))
	money_changed.emit(money)
	hand_changed.emit(hand_name())
	kitchen_changed.emit()
	orders_changed.emit()
	queue_changed.emit()


# ── 一局的生命周期（关卡模式）───────────────────────────────────────
##
## 【一条规则：每关的营收从 0 重新算】已与用户确认。
## 所以开始一关时 money 归零，赚到 level.target_money 就算过关。
## 这也让「结算界面显示营业额」= 「这一关赚了多少」，语义唯一。

## 开一局：把「本局状态」全部初始化。
##
## 【为什么必须是一个函数，而且必须在这里】
## 「本局」有四个互相关联的字段：关卡号、剩余时间、是否进行中、营收。
## 散在各处初始化一定会漏一个 —— 漏掉 run_active 的表现是
## 「倒计时永远不动」（时间到不了，关卡永远不结束），而且不报任何错。
## 所以由 Level 在搭完场景后、或工具在测试前，统一调这一个入口。
##
## 【为什么 level_index 单独一个参数】真实流程里它是「玩到第几关」的进度，
## 而 reset() 不该动它（重试本关不能把进度打回第 1 关）。
func start_level(index1: int, clock_on: bool = true) -> void:
	level_index = maxi(1, index1)
	var lv := Config.level_at(level_index)
	# 【倒计时初始值 = 本关时长，而不是 0】HUD 在开局前要显示「准备中」，
	# 而结算/暂停期间也读这个值；给 0 会让界面闪一下 0:00。
	time_left = float(lv.get("time_limit", 0.0))
	run_active = clock_on
	money = 0
	money_changed.emit(money)


## 把倒计时临时放行（真实游戏：玩家按下「开始游戏」时）。
## 【和 reset() 的区别】reset 是「清空一局的进度」，这里是「让钟开始走」。
## 分成两个动作是因为真实游戏里它们发生在不同时刻
## （搭场景时清空 → 玩家点开始时放行），而工具里两者同时发生。
func enable_run_clock() -> void:
	if Config.level_count() <= 0:
		return
	var lv := Config.level_at(level_index)
	if time_left <= 0.0:
		time_left = float(lv.get("time_limit", 0.0))
	run_active = true


## 推进倒计时。返回值 = 本局是否**刚刚**结束（用于「只结算一次」）。
##
## 【为什么把「时间到」判定放在这里而不是 Level】终局判定只能有一处；
## Level 每帧调它，UI 只管在收到 level_finished 后弹结算。
func tick(delta: float) -> bool:
	if not run_active:
		return false
	time_left -= delta
	if time_left > 0.0:
		return false
	time_left = 0.0
	run_active = false
	level_finished.emit()
	return true


func is_run_active() -> bool:
	return run_active


## 本关目标（元）
func target_money() -> int:
	return int(Config.level_at(level_index).get("target_money", 0))


func level_name() -> String:
	return String(Config.level_at(level_index).get("name", ""))


func level_time_limit() -> float:
	return float(Config.level_at(level_index).get("time_limit", 0.0))


## 本关达标了吗（结算界面用它决定显示「下一关」还是「重试本关」）
func passed() -> bool:
	return money >= target_money()


## 本关拿到几星（0~3）。
##
## 【1 星就是过关线】target_money 既是"过关"也是"1 星"的门槛，
## 所以两个概念不会打架：passed() 等价于 stars() >= 1。
## 门槛从高往低比，第一个够到的就是所得星级。
func stars() -> int:
	for s in [3, 2, 1]:
		if money >= Config.star_money(level_index, s):
			return s
	return 0


## 第 star 星的门槛金额（结算界面 / HUD 提示用）
func star_target(star: int) -> int:
	return Config.star_money(level_index, star)


func has_next_level() -> bool:
	return level_index < Config.level_count()


## 结束本局（结算）。由 Level 在时间到时调用；也允许工具/测试直接结束。
func finish_run() -> void:
	if not run_active:
		return
	run_active = false
	time_left = 0.0
	level_finished.emit()


## 进度：第 index1 关（只改「玩到第几关」，不重置本局数据）
func set_level_index(index1: int) -> void:
	level_index = maxi(1, index1)


# ── 桌子 ───────────────────────────────────────────────────────────

func register_table(t: Node) -> void:
	if not tables.has(t):
		tables.append(t)
	tables.sort_custom(func(a, b): return a.table_id < b.table_id)


func table_by_id(id: int) -> Node:
	for t in tables:
		if t.table_id == id:
			return t
	return null


## 「空桌」= 干净、无人、**而且不在收拾中**。
## 【为什么要把「收拾中」也算进去】HUD 的「空桌数」是给玩家的承诺：
## 写着有几张空桌，就该有几张真的能来客人。正在被收拾的桌子确实不能坐，
## 所以不算空桌。判断统一走 TableRules.is_seatable（唯一入口）。
func available_tables() -> Array:
	var out: Array = []
	for t in tables:
		if TableRules.is_seatable(t):
			out.append(t)
	return out


func dirty_tables() -> Array:
	var out: Array = []
	for t in tables:
		if t.state == TableRules.State.DIRTY:
			out.append(t)
	return out


func empty_table_count() -> int:
	return available_tables().size()


func dirty_table_count() -> int:
	return dirty_tables().size()


## 把所有桌子的「空桌计时」归零 = 重新从「现在」开始算「空桌出现多久了」。
##
## 【为什么需要这个入口】
## 客人生成规则里有一条「空桌出现超过 empty_table_delay(2s) 才能坐人」
## （见 customer_manager.gd）。它算的是 `Time.get_ticks_msec()` 的差值 ——
## **墙上时钟**，场景树暂停它照走。
## 开始界面会把世界冻住（get_tree().paused），而桌子是在 Level 建树时
## 就 `mark_available()` 的。不归零的话，玩家在标题画面待多久，
## 那 2 秒就被提前消耗掉多久：点开始的一瞬间客人就涌进来。
##
## 【为什么不做进 reset()】
## reset() 是「开一局新的」，会把钱、接待数、手上的餐全部清空 ——
## 那是另一个语义。这里只动计时，不碰任何进度。
func reset_table_availability() -> void:
	for t in tables:
		if is_instance_valid(t) and t.has_method("mark_available"):
			t.call("mark_available")


# ── 订单 ───────────────────────────────────────────────────────────

## 所有还没结清的订单（按桌号）
func active_orders() -> Array:
	var out: Array = []
	for t in tables:
		if t.order != null:
			out.append(t.order)
	return out


func active_order_count() -> int:
	return active_orders().size()


# ── 钱 ─────────────────────────────────────────────────────────────

func add_money(amount: int) -> void:
	money += amount
	money_changed.emit(money)


# ── 玩家手上 ───────────────────────────────────────────────────────
##
## 【为什么是列表而不是单个字符串】
## 已与用户确认：手上**最多同时拿 2 份**餐。
##
## 【为什么容量判断只留一个入口（hand_is_full）】
## 「手上只有一份」这个假设原来散落在取餐、饮料机、上菜、垃圾桶等好几处，
## 每处各写一遍 `hand_is_empty()`。改成 2 份以后，如果还各写各的，
## 漏掉一处就会出现「拿了 1 份以后再也拿不了第二份」这种难查的 bug。
## 所以容量相关的判断只从 hand_is_full() 走。

## 手上容量（以后要改成 3 就改 config.json 这一项）
func hand_capacity() -> int:
	return maxi(1, int(Config.config.get("hand_capacity", 2)))


func hand_items() -> Array[String]:
	return hand.duplicate()


func hand_is_empty() -> bool:
	return hand.is_empty()


## 手上还有空位吗（取餐 / 拿饮品的前置条件）
func hand_has_room() -> bool:
	return hand.size() < hand_capacity()


func hand_is_full() -> bool:
	return not hand_has_room()


## 手上有没有这一样
func hand_has(item_id: String) -> bool:
	return hand.has(item_id)


## 往手上加一份。满了就不加，返回是否成功。
func hand_take(item_id: String) -> bool:
	if not hand_has_room():
		return false
	hand.append(item_id)
	hand_changed.emit(hand_name())
	return true


## 从手上拿走一份（送达 / 丢弃）
func hand_remove(item_id: String) -> bool:
	var idx := hand.find(item_id)
	if idx < 0:
		return false
	hand.remove_at(idx)
	hand_changed.emit(hand_name())
	return true


## 清空（扔垃圾桶）
func clear_hand() -> void:
	if hand.is_empty():
		return
	hand.clear()
	hand_changed.emit(hand_name())


## 兼容旧调用：直接设置成「一份」。容量为 1 时等价，容量 >1 时会丢东西，
## 所以只留给测试和工具用；正式流程请用 hand_take / hand_remove。
func set_hand(item_id: String) -> void:
	hand.clear()
	if item_id != "":
		hand.append(item_id)
	hand_changed.emit(hand_name())


func hand_name() -> String:
	if hand.is_empty():
		return "空手"
	var parts: PackedStringArray = []
	for id in hand:
		parts.append(Config.item_name(id))
	return "、".join(parts)


# ── 后厨每帧 ───────────────────────────────────────────────────────

func update_kitchen(delta: float) -> void:
	var before := kitchen.queue_count()
	kitchen.update(delta)
	if kitchen.queue_count() != before:
		queue_changed.emit()


## 后厨 UI 点「完成」
func enqueue_kitchen(items: Array) -> void:
	kitchen.enqueue(items)
	queue_changed.emit()


# ── HUD 需要的一整屏状态 ───────────────────────────────────────────

func hud_snapshot(in_store_count: int) -> Dictionary:
	return {
		"money": money,
		"served": served_count,
		"empty_tables": empty_table_count(),
		"dirty_tables": dirty_table_count(),
		"in_store": in_store_count,
		"counter": kitchen.counter_name(),
		# 【用 pending_count 而不是 queue_count】后者只数「还没开始做的」；
		# 后厨改成「不阻塞」之后，已做好、等在出餐口排队的那些也要算进来，
		# 否则玩家会看到「后厨队列：0」却还在不断冒出新菜。
		"queue": kitchen.pending_count(),
		# 关卡模式的四项：第几关、还剩几秒、目标、本关是否进行中
		"level": level_index,
		"level_name": level_name(),
		"time_left": time_left,
		"target": target_money(),
		"run_active": run_active,
		# 星级门槛（HUD 在倒计时那一行上方显示）+ 当前星数
		"star1": star_target(1),
		"star2": star_target(2),
		"star3": star_target(3),
		"stars": stars(),
	}
