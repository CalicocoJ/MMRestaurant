extends Node2D
## 客人生成器（文档第三节 + 第十六节第 1 条）。
##
## 规则：
##   每 customer_spawn_check_interval 秒检测一次。
##   条件：存在空桌（干净且无人）且当前没有客人处于「走向座位」状态
##         且空桌出现已超过 empty_table_delay 秒。
##   动作：生成**一组**（1~2 人，整组同一帧创建），从门口走向同一张桌。
##
## 【「空桌出现已超过 2s」到底从哪算起】
## 文档没写得很细。这里的定义是：**这张桌子最近一次变成「干净且无人」的时刻**。
## 刚被收拾干净、客人刚气走空出桌子，都会刷新这个时刻。
## 含义唯一、可测，也不会出现「桌子空了半天却因为别的原因不能坐」。
##
## 【「正在生成的客人」是全局还是每桌一个】
## 取保守解（更贴近字面）：**整组人在全部坐下之前，不再开新组**。
## 这样客人一定排队进场，不会三桌同时来人把开局压力拉满。
##
## 【判断依据是「客人的状态」，不是一个计数器】
## 曾经用一个 _group_size 计数器表达「上一组还没走完」，结果忘了复位，
## 整局只生成第一组客人。现在一律直接查场上客人的 state —— 见 _attempt_spawn。

var customers: Node2D = null   ## 客人容器
var level: Node = null

var _check_clock: float = 0.0
var _interval: float = 1.0


func setup(p_container: Node2D, p_level: Node) -> void:
	customers = p_container
	level = p_level
	_interval = maxf(0.05, Config.num("customer_spawn_check_interval"))


func _process(delta: float) -> void:
	_check_clock += delta
	if _check_clock < _interval:
		return
	_check_clock = 0.0
	_attempt_spawn()


# ── 查询 ───────────────────────────────────────────────────────────

## 店里的人数（含正在走来的，不含正在离场的）
func in_store_count() -> int:
	if customers == null:
		return 0
	var n := 0
	for child in customers.get_children():
		var st: int = int(child.get("state"))
		if st == Constants.State.LEAVING or st == Constants.State.ANGRY_LEAVING:
			continue
		n += 1
	return n


func any_walking_in() -> bool:
	if customers == null:
		return false
	for child in customers.get_children():
		if int(child.get("state")) == Constants.State.WALKING_IN:
			return true
	return false


# ── 生成 ───────────────────────────────────────────────────────────

## 每 1s 检测一次：有空位就放**一组**客人进来（1~2 人）。
##
## 【为什么按「组」而不是按「座位」生成】
## 现实里客人是结伴来的：一组 1~2 人，整组坐同一张桌子。
## 按座位一个个找会出现「陌生人被拼到同一桌、共享一张票」这种不合理情况。
## 整组同桌也正好和「桌级共享订单」的语义对得上。
##
## 【订单在生成这一刻就整组定好】
## 见 Config.roll_group_orders() —— 它保证整桌至少点够
## `min_main_per_group` 份主食（已与用户确认：客人不能只点饮料）。
##
## 【一组客人现在「同一帧全部创建」（用户要求）】
## 原来是「前一位落座之后，下一位才生成」（靠 _group_seats 排队）。
## 改成同时创建有两条理由：
##   1. 用户明确要求「一组客人必须同时生成」；
##   2. 整桌订单要**一起**校验、一起重摇。成员若先后生成，
##      「整桌缺主食就重摇」只能事后补摇某一位，会天然偏向先坐的那位。
## 门口表现：两人沿 x 轴错开 group_entry_stagger 像素（Door.next_group_spawn），
## 各走各的路径，看着是结伴进门而不是一个人。
func _attempt_spawn() -> void:
	if customers == null:
		return
	# 【不要再加「上一组还没走完」这种需要手动复位的标志位】
	# 这里原来有一句 `if _group_size > 0: return`，而 _group_size 是在
	# spawn_group 末尾赋的、**没有任何地方清回 0**（旧代码是靠
	# 「_group_seats 排空时顺手归零」复位的，改成同帧生成时那个复位点没了）。
	# 后果是**第一组客人之后整局再也不生成客人** —— 一个不报错的死锁。
	#
	# 现在改成直接问场上状态：只要还有客人处于「走向座位」，就不开新组。
	# 这个状态由客人自己维护、随它落座自动消失，不存在「谁忘了复位」的问题。
	if any_walking_in():
		return
	if _has_unseated_customer():
		return

	# 掷这一组几个人
	var size := Config.roll_group_size()
	# 要有能容纳**整组**的桌子（不够就在门口等，不拆）
	var slot := SeatManager.pick_group(size)
	if slot.is_empty():
		_diag("pick_group 没找到能坐下 %d 人的桌（tables=%d）" % [size, Game.tables.size()])
		return	# 条件：这张桌「空桌出现」已超过 empty_table_delay 秒
	var t: Node = slot["table"]
	if t.available_duration() < Config.num("empty_table_delay"):
		_diag("桌子还没空够 %.2fs（当前 %.2fs）" % [
			Config.num("empty_table_delay"), t.available_duration()])
		return

	spawn_group(t, slot["seats"])


## 临时诊断：把「为什么没生成」打出来（`DEBUG_WALK` 开关控制，关掉零开销）。
## 【为什么要有它】「点了没反应」「一直不来客人」这类问题，
## 光看代码推不出来 —— 必须把当场的前置条件打出来。
var _diag_count: int = 0

func _diag(reason: String) -> void:
	if not DebugTrace.enabled():
		return
	_diag_count += 1
	if _diag_count <= 12:
		print("[spawn] 没有生成：%s（第 %d 次）" % [reason, _diag_count])


## 把整组客人一次性放到指定桌子上（同一帧全部创建）。
##
## 【订单在这里就已经定好】_rolled 就是这一组最终的菜，
## 之后客人入座、玩家接单都只是**揭晓**，不会再重摇。
func spawn_group(table: Node, seats: Array) -> Array:
	var out: Array = []
	if customers == null or level == null or table == null or seats.is_empty():
		return out
	var rolled := Config.roll_group_orders(seats.size())
	Door.begin_group()
	var stagger := Config.num("group_entry_stagger")
	for i in seats.size():
		var seat: Seat = seats[i]
		var items: Array[String] = rolled[i] if i < rolled.size() else ([] as Array[String])
		var c: Node = _spawn_one(table, seat, items)
		if c == null:
			continue
		# 第一位站门口中心，第二位偏开一小段 —— 同一帧创建，但身体不重叠。
		c.call("place_at", Door.next_group_spawn(stagger))
		out.append(c)
	# 【这一句必须在循环**外面**】
	# 放在循环里等于每生成一位就把序号复位，第二位又回到门口中心，
	# 两人完全重叠（本轮踩过：错开量实测 0px）。begin/end 是**一组一次**的配对。
	Door.end_group()
	return out


## 场上还有「没坐下」的客人吗（走向座位中）
func _has_unseated_customer() -> bool:
	if customers == null:
		return false
	for child in customers.get_children():
		var st: int = int(child.get("state"))
		if st == Constants.State.WALKING_IN:
			return true
	return false


## 立即在指定座位生成一位客人（测试里会直接调它，跳过 1s 检测节流）。
##
## 【这是「单人生成」入口，不参与整组主食校验】
## 14 个测试 / 工具脚本都用它来精确摆放客人，签名和行为必须保持不变。
## 正式玩法走 spawn_group() → _spawn_one() 那条路（整组订单一起来）。
func spawn_at_seat(table: Node, seat: Seat) -> Node:
	return _spawn_one(table, seat, Config.roll_order())


## 生成一位客人的共同部分：建节点、定单、挂信号。
## items 为空时兜底随机一张单，保证「客人不会白坐」。
func _spawn_one(table: Node, seat: Seat, items: Array[String]) -> Node:
	if customers == null or level == null or table == null or seat == null:
		return null
	var c: Node = level.make_customer()
	if c == null:
		return null
	customers.add_child(c)
	# 客人入座时就把单点好（玩家接单只是揭晓）
	c.call("set_pending_items", items if not items.is_empty() else Config.roll_order())
	c.call("setup", table, seat, Door.spawn_point(), table.call("seat_sit_point", seat))
	table.call("on_seat_taken", seat, c)
	c.reached_seat.connect(level._on_customer_seated)
	c.gone.connect(level._on_customer_gone)
	return c


## 兼容入口：在指定桌子上找第一个空座位
func spawn_at(table: Node) -> Node:
	var free: Array = table.call("free_seats")
	if free.is_empty():
		return null
	return spawn_at_seat(table, free[0])
