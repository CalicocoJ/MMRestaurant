extends Node2D
## 客人。状态机严格对应文档第四节。
##
## 状态            进入条件                耐心    头顶显示          超时行为
## WALKING_IN      生成                     —     无                 —
## WAITING_TO_ORDER 走到座位坐下            28s    耐心环 + !        气走
## ORDER_TAKEN     玩家点客人接单          45s    耐心环            气走
## ORDERED         玩家在后厨 UI 点「完成」  45s    耐心环            气走
## EATING          订单全部上齐            12s    「用餐中」        结账离开
## LEAVING         用餐结束                 —     无                走向门口，消失
## ANGRY_LEAVING   耐心归零                 —     无                走向门口，消失，不留脏桌
##
## 【订单是谁定的】
## 客人坐下时自己随机点好（1~2 样，允许重复）。玩家点客人接单时，
## 只是「揭晓」这张已经存在的订单 —— 所以接单不需要任何选择 UI。

signal gone(customer: Node)          ## 已到门口并该被移除
signal reached_seat(customer: Node)
signal order_taken(customer: Node)

const RADIUS := 15.0
const RING_RADIUS := 12.0
const RING_WIDTH := 3.0
const RING_LIFT := 20.0
const BUBBLE_LIFT := 34.0

var state: int = Constants.State.WALKING_IN
var table: Node = null
## 我坐的座位（Seat）。订单是桌级共享的，但「我拿到了哪几样」记在座位上。
var seat: Seat = null

var patience: float = 0.0
var patience_max: float = 0.0

var speed: float = 220.0

## 一张订单还没生成时用它兜底
var _pending_items: Array[String] = []

var _target := Vector2.ZERO
## 这单是否已经了结（结账或气走），防止重复结算
var _resolved := false
## 是否已经报过「到家了」，防止重复发 gone
var _gone_sent := false
## 自己那份吃完了（但可能还要等同桌其他人）
var _meal_done := false
## 是否已经被桌子叫走，防止重复触发
var _leave_sent := false
## 走向座位时的拐点队列（客人也走寻路，不从桌子上穿过去）
var _in_waypoints: Array = []


## p_seat 是我要坐的那个 Seat；p_sit 是座位中心的世界坐标（走过去的目标点）
func setup(p_table: Node, p_seat: Seat, from: Vector2, p_sit: Vector2) -> void:
	table = p_table
	seat = p_seat
	global_position = from
	_target = p_sit
	state = Constants.State.WALKING_IN
	_resolved = false
	_gone_sent = false
	speed = Config.num("customer_speed")
	# 路径必须在**进树之后**才算（那时 get_world_2d() 才有物理世界，
	# 射线检测才有效 —— 否则直角化会静默失效，客人斜穿桌子）。
	_pending_path_from = from
	_pending_path_to = p_sit
	if is_inside_tree():
		# 【注意两种调用顺序都要照顾到】
		# Level 的流程是 add_child 之后再 setup，此时 _ready 已经跑过一遍
		# （按 (0,0) 算的路径），必须在这里重算；
		# 若将来改成先 setup 再 add_child，则由 _ready 去算。
		# 曾经只写了 _ready，结果 add_child 在前时路径按 (0,0) 算出来，
		# 客人从原点走向座位（截图里凭空出现在左上角）。
		global_position = from
		_compute_walk_in_path(from, p_sit)


func _ready() -> void:
	# 进树了，现在可以安全地做射线检测
	_compute_walk_in_path(_pending_path_from, _pending_path_to)


## 进树之后再算路径（见 setup 里的说明）
var _pending_path_from := Vector2.ZERO
var _pending_path_to := Vector2.ZERO

## 算一条从门口到座位的路径。
##
## 【为什么客人也需要寻路】
## 座位分左右两侧，**左侧座位在桌子的"背面"**：从门口直线过去必然穿过桌子。
## 玩家看到的就是「客人从桌子上走过去」。
##
## 【为什么直接复用服务员那套寻路，而不是另写一套】
## 我一度给客人单独写了「客用网格 + 直角化 + 安全拐角」，多出几百行新代码，
## 结果引入了好几个新 bug（路径退化成直线、拐角贴着桌沿、客人从原点出发）。
## 服务员那套 `find_path` 已经是**正交网格 + 直角化**的成品，
## 直接拿来用即可 —— 少一套代码就少一类 bug。
##
## 【座位落在障碍格里怎么办】
## 服务员的网格外扩 18px，会把椅子那格也封死，于是「座位」这个目标
## 落到障碍里，A* 会把终点吸附到最近的可走格 —— 客人会停在座位旁边
## 差一点点的地方。
## 所以这里在路径**末尾补上真实座位点**：沿最后一个格子中心 → 座位
## 这一小段（最多十几像素）直接走过去。那段路本来就在椅子附近，
## 是客人本来就该坐进去的位置。
func _compute_walk_in_path(from: Vector2, to: Vector2) -> void:
	_in_waypoints.clear()
	var pf := get_tree().get_first_node_in_group("pathfinder")
	if pf == null:
		return
	if from.distance_to(to) < 1.0:
		return
	var pts: Array = pf.call("find_path_for_customer", from, to)
	# 【关键】A* 自己就可能返回**斜线段**（它的终点被吸附到"最近可走格"，
	# 从那儿连到真实座位往往是一条斜线）。实测：
	#   桌3 座2 → (930,610) → (930,370) → (1114,430)，最后一段横穿桌3。
	# 所以不能只"补最后一点"，要对**整条路径**做正交化：
	# 逐段检查，斜的段就拆成横+竖（两个候选拐角，哪个不碰桌子用哪个）。
	_in_waypoints = _orthogonalize(pts)
	_append_to_seat(to)
	var seat_desc := "?"
	if table != null and is_instance_valid(table) and seat != null:
		var idx: int = table.seats.find(seat)
		seat_desc = "%s 座%d" % [table.label, idx + 1]
	DebugTrace.note_path("客人进场 → %s" % seat_desc, from, to, pts, _in_waypoints)


## 把路径上的**每一段**都变成横或竖。
##
## 斜线段对客人是硬穿 —— 客人没有碰撞体（不然会挡住服务员）。
## 服务员那边靠 move_and_slide 兜底，客人只能靠这里保证。
func _orthogonalize(pts: Array) -> Array:
	var out: Array = []
	if pts.is_empty():
		return out
	out.append(pts[0])
	for i in range(1, pts.size()):
		var a: Vector2 = out[out.size() - 1]
		var b: Vector2 = pts[i]
		# 已经轴对齐 → 直接用
		if absf(a.x - b.x) < 0.5 or absf(a.y - b.y) < 0.5:
			out.append(b)
			continue
		# 斜的 → 插一个直角拐角，两个候选哪个不碰桌子用哪个
		var done := false
		for corner in [Vector2(b.x, a.y), Vector2(a.x, b.y)]:
			if not _blocked(a, corner) and not _blocked(corner, b):
				out.append(corner)
				out.append(b)
				done = true
				break
		if not done:
			# 两个候选都碰桌子 → 用「安全落脚点」绕开（见 _safe_staging）
			var safe := _safe_staging(b)
			if safe != Vector2.INF:
				out.append(safe)
			out.append(b)
	return out


## 把真实座位点接到路径末尾，必要时插入一个安全的直角拐角
func _append_to_seat(seat_pt: Vector2) -> void:
	if _in_waypoints.is_empty():
		_in_waypoints.append(seat_pt)
		return
	var last: Vector2 = _in_waypoints[_in_waypoints.size() - 1]
	if last.distance_to(seat_pt) <= 1.0:
		return
	if not _blocked(last, seat_pt):
		_in_waypoints.append(seat_pt)
		return
	for corner in [Vector2(seat_pt.x, last.y), Vector2(last.x, seat_pt.y)]:
		if not _blocked(last, corner) and not _blocked(corner, seat_pt):
			_in_waypoints.append(corner)
			_in_waypoints.append(seat_pt)
			return
	# 【兜底：绝不直接连过去】
	# 直接连是一段斜线，可能从桌沿穿过去（自检抓到过）。
	# 改成「先离开桌子到一个安全点，再竖着/横着进座位」：
	# 安全点 = 座位在**桌子外侧**的那个方向再退开一点。
	# 这样最后一段永远在桌子外面，不会穿桌。
	var safe := _safe_staging(seat_pt)
	if safe != Vector2.INF:
		_in_waypoints.append(safe)
	_in_waypoints.append(seat_pt)


## 找一个「绝对不碰桌子」的落脚点：以座位为起点，朝各方向试探，
## 取第一个「离所有桌面 ≥ 客人半径，且从它到座位这段也不碰桌」的点。
func _safe_staging(seat_pt: Vector2) -> Vector2:
	var dirs := [
		Vector2(0, -1), Vector2(0, 1), Vector2(-1, 0), Vector2(1, 0),
		Vector2(-0.7, -0.7), Vector2(0.7, -0.7), Vector2(-0.7, 0.7), Vector2(0.7, 0.7),
	]
	for d in dirs:
		for dist in [RADIUS + 6.0, RADIUS * 2.0, RADIUS * 3.0, RADIUS * 5.0]:
			var cand: Vector2 = seat_pt + d.normalized() * dist
			if not _blocked(cand, seat_pt) and not _blocked(cand, cand):
				return cand
	return Vector2.INF


## 从 a 到 b 这条直线，客人身体会不会压到**桌子**。
##
## 【为什么只查桌子，不查椅子】
## 客人本来就坐在椅子上 —— 最后一段必然和椅子重叠，那是正常的。
## 一开始我把椅子也算进去，于是「连到座位」的那一小段被判为「被挡」，
## 退化成一条斜线穿过桌面（自检抓到的最后 1 条踩桌记录就是这么来的）。
## 只有桌子是真正不能碰的东西。
##
## 判据是「沿途每一点离桌面 ≥ 客人半径」，不是「有没有碰到」——
## 客人没有碰撞体，擦着桌沿过就等于身体穿过去。
## 采样步长 4px：8px 会漏掉「刚好擦过桌角」的短段。
func _blocked(a: Vector2, b: Vector2) -> bool:
	if a.distance_to(b) < 0.5:
		return false
	var steps := maxi(2, int(a.distance_to(b) / 4.0))
	for i in range(steps + 1):
		var p: Vector2 = a.lerp(b, float(i) / float(steps))
		for tb in Game.tables:
			# 只要桌面那个碰撞形状（第 0 个；椅子是后面的）
			var shapes: Array = tb.call("collision_shapes_global")
			if shapes.is_empty():
				continue
			if p.distance_to(EntityBase.nearest_point_on_rect(shapes[0], p)) < RADIUS:
				return true
	return false

## 走到座位后调用：自己点单 → 进入 WAITING_TO_ORDER
##
## 【注意】这里**不**建 Order。
## 订单是桌级共享的，要等玩家来接单时才由 Table.open_order() 统一开一张票。
## 客人此刻只是「把自己的菜记在座位上」。
func take_order() -> void:
	var mine := _pending_items.duplicate()
	if mine.is_empty():
		# 菜单空了，兜底给一个汉堡，免得客人白坐
		mine = [Constants.BURGER] as Array[String]
	if seat != null:
		seat.set_pending(mine)
	patience_max = Config.num("patience_waiting_to_order")
	patience = patience_max
	state = Constants.State.WAITING_TO_ORDER
	queue_redraw()


func set_pending_items(ids: Array[String]) -> void:
	_pending_items = ids.duplicate()


## 这位客人自己点的菜（只读副本）。
## 【为什么要有这个 getter】`_pending_items` 是私有的，而「整桌至少 1 份主食」
## 这条规则需要被验证到**客人身上**（而不是只看 Config 摇出来的结果）——
## 中间任何一步把它弄丢，只测 Config 是发现不了的。
func pending_items() -> Array[String]:
	return _pending_items.duplicate()


## 把已经进树的客人挪到另一个出发点，并重算进场路径。
##
## 【为什么不能靠再调一次 setup() 来改起点】
## setup() 之外它还负责 `reached_seat.connect(...)` / `gone.connect(...)`。
## 已经有信号连接的情况下再走一遍，会让「到座位」「离场」两个回调各触发两次
## —— 座位被记两次、订单栏刷新两次，而且这种重复连接不报任何错。
##
## 【用在哪】同组客人现在同一帧全部创建（见 customer_manager.spawn_group）。
## 第一位从门口中心出发，第二位偏开一小段，避免两个人的身体重叠着进门。
## 所以需要在 add_child 之后、真正开走之前，单独把起点挪一下。
func place_at(from: Vector2) -> void:
	if not is_inside_tree():
		return
	global_position = from
	# 路径必须重算：_compute_walk_in_path 内部会做射线检测，
	# 起点变了不重算，客人就会从旧起点那条路径的中间开始走（表现为瞬移）。
	_compute_walk_in_path(from, _target)


## 我在等点单吗（Table 点击时会问）
func is_waiting_to_order() -> bool:
	return state == Constants.State.WAITING_TO_ORDER


func _process(delta: float) -> void:
	match state:
		Constants.State.WALKING_IN:
			# 沿寻路拐点走，走完最后一个才到座位
			_watch_table_intrusion()
			if _follow_waypoints(delta):
				reached_seat.emit(self)
		Constants.State.WAITING_TO_ORDER, Constants.State.ORDER_TAKEN, Constants.State.ORDERED:
			patience -= delta
			if patience <= 0.0:
				patience = 0.0
				go_angry()
		Constants.State.EATING:
			patience -= delta
			if patience <= 0.0:
				finish_meal()
		Constants.State.LEAVING, Constants.State.ANGRY_LEAVING:
			if _step_toward(_target, delta):
				# 到家了：先把座位还回去（这样桌子能统计「还有没有人」），
				# 再报 gone 让 Level 把我移除。
				#
				# 【注意】不能拿「这单是否已了结」当判据 ——
				# finish_meal() 会提前置位，于是走到门口永远不发 gone，
				# 节点永远留在场上（曾经真的这么错过）。
				if not _gone_sent:
					_gone_sent = true
					if table != null and is_instance_valid(table) and seat != null:
						table.call("member_vacated", seat)
					gone.emit(self)
	queue_redraw()


func _step_toward(point: Vector2, delta: float) -> bool:
	var step := speed * delta
	if global_position.distance_to(point) <= step:
		global_position = point
		return true
	global_position = global_position.move_toward(point, step)
	return false


## 自检：走位过程中圆心踩进桌面碰撞盒就记录一次。
##
## 【为什么写在游戏代码里，而不是测试脚本里】
## 我写测试脚本时反复被「_ready 会重置位置」这类副作用干扰，
## 多次误读自己的日志、浪费了大量时间。把自检放在真正跑的这份代码里，
## 打开 DEBUG_WALK 就能在**真实对局**里抓到现场（含路径和帧号），
## 不用再维护一份容易写错的旁路脚本。
##
## 只在 DebugTrace 打开时才有开销（一次距离判断 + 字符串）。
func _watch_table_intrusion() -> void:
	if not DebugTrace.enabled():
		return
	for tb in Game.tables:
		var shapes: Array = tb.call("collision_shapes_global")
		if shapes.is_empty():
			continue
		# 只看桌面那一个形状（第 0 个）；和椅子重叠是正常的
		if shapes[0].has_point(global_position):
			DebugTrace.note_intrusion(self, tb.label, global_position,
				_in_waypoints, _target, table)
			return


## 沿拐点逐个走。全部走完（到达最后一个拐点 = 座位）时返回 true。
##
## 【为什么要「吸附」到拐点】和服务员那边同一个理由：只做「接近就算」
## 的话每段都会差几像素，段与段之间不是干净直角，走起来歪歪扭扭。
func _follow_waypoints(delta: float) -> bool:
	# 没有路径（寻路器不可用）→ 退回直线走，至少不会卡住
	if _in_waypoints.is_empty():
		return _step_toward(_target, delta)

	var wp: Vector2 = _in_waypoints[0]
	var step := speed * delta
	if global_position.distance_to(wp) <= step:
		global_position = wp
		_in_waypoints.pop_front()
		return _in_waypoints.is_empty()
	global_position = global_position.move_toward(wp, step)
	return false


# ── 状态迁移 ───────────────────────────────────────────────────────

## 玩家接单成功
func accept_order() -> void:
	if state != Constants.State.WAITING_TO_ORDER:
		return
	state = Constants.State.ORDER_TAKEN
	patience_max = Config.num("patience_waiting_for_food")
	patience = patience_max
	order_taken.emit(self)


## 玩家在后厨 UI 点了「完成」：耐心继续按 45s 走，不重置
func mark_ordered() -> void:
	if state == Constants.State.ORDER_TAKEN:
		state = Constants.State.ORDERED


## 全部上齐
func start_eating() -> void:
	state = Constants.State.EATING
	patience_max = Config.num("patience_eating")
	patience = patience_max
	_meal_done = false


## 我吃完自己那份了吗（Table 会问：整桌是否都吃完了）
func is_meal_done() -> bool:
	return _meal_done


## 被桌子要求离场（整桌一起走）。
## angry = true 表示气走（不结账）。
##
## 【为什么由桌子统一发令，而不是各人自己走】
## 已与用户确认：一组客人一起来、一起走。
## 所以「什么时候走」是**整桌**的决定，客人自己只负责执行。
func leave_now(angry: bool) -> void:
	if _leave_sent:
		return
	_leave_sent = true
	if angry:
		state = Constants.State.ANGRY_LEAVING
	else:
		state = Constants.State.LEAVING
	_send_home()


## 自己那份吃完了。
##
## 【为什么不在这里直接走】
## 已与用户确认：一组客人「各吃各的，但一起起身」。
## 先吃完的留在座位上等，由 Table 检查整桌都吃完后统一叫走。
func finish_meal() -> void:
	if _meal_done:
		return
	_meal_done = true
	Game.served_count += 1
	# 整桌都吃完了 → 一起走
	if table != null and is_instance_valid(table) and table.call("all_meals_done"):
		table.meal_completed = true
		table.call("leave_all", false)


## 耐心归零 → 整桌一起气走（已与用户确认）
func go_angry() -> void:
	if _leave_sent:
		return
	Game.angry_count += 1
	if table != null and is_instance_valid(table) and table.has_method("on_customer_angry") and seat != null:
		# 交给桌子：它会叫整桌一起走，并清空座位、不结账、不留脏桌
		table.on_customer_angry(seat)
		return
	# 兜底：没桌子信息就自己走
	leave_now(true)


func _send_home() -> void:
	_target = Door.home_point()
	queue_redraw()


# ── 玩家能否点它 ───────────────────────────────────────────────────

func is_clickable() -> bool:
	return state == Constants.State.WAITING_TO_ORDER \
		or state == Constants.State.ORDER_TAKEN \
		or state == Constants.State.ORDERED


func click_radius() -> float:
	return RADIUS + 6.0


# ── 「碰到就触发」的几何信息 ───────────────────────────────────────
##
## 客人**不是**物理物体（不然会挡住服务员走路），所以没法靠碰撞盒判定。
## 用「一个点 + 半径」代替，覆盖 WorldObject 的默认实现，
## 让「靠近客人」和「贴上桌子」用同一套判据 —— 手感一致，代码也只有一条路径。

## 【为什么是 50】
## 客人坐在**实体椅子**上，服务员最多只能走到椅子外沿。
## 椅子半宽 20 + 服务员半径 16 = 36，这是「刚好贴上」的数学下限；
## 但格子寻路只保证走到格子中心，会再偏出去约 10px（格子 20px 的一半），
## 所以取 50 留出余量。它必须 ≥ 椅子半宽 + 服务员半径 + 半格，
## 否则会出现「贴着椅子却永远接不了单」——正是踩过的坑 8。
const TOUCH_RADIUS := 50.0


## 离 from 最近的可碰点就是客人自己（他不是墙，站上去也没关系）
func touch_point(_from: Vector2) -> Vector2:
	return global_position


func touches_from(from: Vector2, radius: float) -> bool:
	return from.distance_to(global_position) <= TOUCH_RADIUS + radius


## 服务员站定时再退开多少。**当前是 0 —— 实测不需要。**
##
## 【为什么最终没有用它】
## 原本打算靠它解决「服务员压在客人身上」，做法是让落脚点再外推一点。
## 但实测发现两件事：
##   1. 落脚点本来就是按**整团家具（桌子+椅子）的外框**往外推的，
##      服务员会停在椅子外侧、离客人约 64px；
##   2. 「不重叠」只需要 ≥ 31px（客人半径 15 + 服务员半径 16）——
##      64px 早就满足了。
## 再加 12px 反而把他推到 76px 外，显得「隔着老远上菜」。
## 所以退让量归零；这个接口留着，以后要微调幅度改这里一个数字即可
## （它只在**到达判定**里生效，不会把落脚点推进障碍格）。
func standoff() -> float:
	return 0.0


# ── 点击入口（文档第十五节「左键点击客人」）────────────────────────
##
## 【这个方法曾经整个漏掉了】
## 结果就是「点客人完全没反应」，而且 ClickRouter 报
## `Nonexistent function 'interact'`。原因是客人不继承 WorldObject
## （它要能被行走穿过，不能是 StaticBody2D），
## 所以没有基类帮忙兜底 —— 接口必须在这个文件里自己补齐。
##
## 两种分支：
##   WAITING_TO_ORDER        → 走过去接单（到达时再检查客人是否还在等）
##   ORDER_TAKEN / ORDERED   → 手上正好有「这一桌还没人认领的菜」→ 走过去上菜
##   EATING / 走向 / 离场     → 不可点击，完全无反应
func interact(router: Node) -> int:
	# 1) 等点单：接单
	if state == Constants.State.WAITING_TO_ORDER:
		var cb := func(r: Node) -> bool: return _do_take_order(r)
		# 【走不到要让玩家知道】
		# 没有这个提示的话，服务员走一半取消，玩家只看到「点了没反应」——
		# 正是反复踩过的那个坑。接上信号就能说出原因。
		if not router.waiter.command_cancelled.is_connected(_on_move_cancelled):
			router.waiter.command_cancelled.connect(_on_move_cancelled)
		router.go_then(global_position, cb, "去接单", self)
		return RouterResult.ACCEPTED

	# 2) 等上菜：看**整桌**还缺不缺我手上这些菜，而不是只看我自己 ——
	#    订单是桌级共享的，谁拿哪份由 Table.assign_delivery() 决定。
	#    手上可能有两份（容量 2），所以这里检查的是「**有没有一份**是这桌缺的」。
	if state == Constants.State.ORDER_TAKEN or state == Constants.State.ORDERED:
		# 空手和「拿错菜」是两回事，提示要分开 ——
		# 空手时说「这不是他要的菜」会让玩家以为是菜点错了。
		if Game.hand_is_empty():
			router.say(Constants.MSG_HAND_EMPTY)
			return RouterResult.NO_ACTION
		if _wanted_in_hand().is_empty():
			router.say(Constants.MSG_WRONG_DISH)
			return RouterResult.NO_ACTION
		var cb2 := func(r: Node) -> bool: return _do_serve(r)
		# 【上菜只要求走到桌边，不要求走到这位客人身边】
		# 现实里服务员也是端到桌旁递过去，不会绕到每位客人身后。
		# 这同时大幅降低了对寻路的要求 —— 碰到桌子比碰到座位容易得多。
		var serve_target: Node = table if (table != null and is_instance_valid(table)) else self
		router.go_then(serve_target.call("walk_to"), cb2, "去上菜", serve_target)
		return RouterResult.ACCEPTED

	# 3) 用餐中 / 走向桌子 / 离场：不可点击，无反应
	return RouterResult.NO_ACTION


## 手上**这一桌还要**的那几样（按手上顺序）。
##
## 【为什么要返回列表而不是单个】
## 手上的菜可能不止一样（容量 2），而这一桌可能同时缺其中两样
## （例如两人桌点了汉堡+可乐）。已与用户确认：
##   - 只送**匹配的**那些，手上不匹配的继续拿着；
##   - 一次点击把该桌缺的、手上有的**都送完**。
func _wanted_in_hand() -> Array[String]:
	var out: Array[String] = []
	for id in Game.hand_items():
		if _table_wants(id):
			out.append(id)
	return out


## 这一桌（所有还坐着的客人）里，还有没有人没拿到这道菜
func _table_wants(item_id: String) -> bool:
	if table != null and is_instance_valid(table):
		return bool(table.call("wants_from_seats", item_id))
	if seat != null:
		return seat.wants(item_id)
	return false


## 到达时再检查：客人是否**仍然**在等点单
##
## 【订单在这里才诞生】玩家接到单，才由 Table.open_order() 开一张共享的票。
## 早先是客人一坐下就建 Order，结果票在玩家接单前就冒出来了。
func _do_take_order(router: Node) -> bool:
	if state != Constants.State.WAITING_TO_ORDER:
		return false
	if table == null or not is_instance_valid(table):
		return false
	# 同一桌只要有一位客人被接了单，整桌就一起进入等上菜
	var o: Order = table.open_order()
	for s in table.occupied_seats():
		s.occupant.call("accept_order")
	_on_order_changed_ui(router)
	Stickers.push_world(global_position + Vector2(0, -52), "已接单", Constants.COLOR_TEXT)
	return true


## 到达时再检查：手上**仍然**有餐，且这桌还有人在等这道菜
func _do_serve(router: Node) -> bool:
	if state != Constants.State.ORDER_TAKEN and state != Constants.State.ORDERED:
		return false
	if Game.hand_is_empty():
		router.say(Constants.MSG_HAND_EMPTY)
		return false
	if table == null or not is_instance_valid(table):
		return false

	# 【到达时再检查】手上**现在**还有哪些是这桌缺的。
	# 路上玩家可能又点了别的东西，所以不能沿用点击时的判断。
	var items := _wanted_in_hand()
	if items.is_empty():
		router.say(Constants.MSG_WRONG_DISH)
		return false

	# 一次把该桌缺的、手上有的都送完（已与用户确认）。
	# 交给桌子决定每一份归谁（给还没拿到它的那位客人）。
	# **手上不匹配的那些继续拿着**，等下一次点击送给别桌。
	#
	# 【手上扣几份必须以 assign_delivery 的返回值为准】
	# `items` 是**按手上的份数**列出来的，会带重复。例如手上两份汉堡、
	# 而这一桌只缺一份时，`items` = ["burger", "burger"]：
	# 循环第一遍真的送出了，第二遍 assign_delivery 已经找不到想要的客人
	# （返回 null），可代码原来不看返回值、照样扣一份 —— 于是**两份汉堡全没了**。
	# 现在先把「实际送出去的份数」数出来，再按这个数扣手上的菜。
	var delivered := _deliver_items(items)
	_apply_delivered(delivered, router)

	# 整桌的票都送齐了 → 票消失。
	#
	# 【注意】只是把 order 引用摘掉（让订单栏不再显示这张票），
	# **不要在这里结账** —— 结账要等客人走到门口那一刻，
	# 由 Table._settle_bill 用 Table.bill_amount 结算。
	# 该收多少钱在 open_order 时就记下了，所以这里清空 order 不影响收钱。
	if table.order != null and table.order.all_delivered():
		table.order = null
		Game.orders_changed.emit()
	_on_order_changed_ui(router)
	return true


## 按顺序把 items 送出去，返回「每样实际送成功了几份」。
##
## 【唯一真相在 assign_delivery 的返回值】它返回被服务的那位客人；
## 没有客人还要这一样时返回 null。只有返回非空才代表这一份真的上了桌。
func _deliver_items(items: Array[String]) -> Dictionary:
	var delivered: Dictionary = {}
	for item in items:
		var served: Node = table.call("assign_delivery", item)
		if served == null:
			continue          # 这一桌已经没人要它了 → 手上留着，别扣
		delivered[item] = int(delivered.get(item, 0)) + 1
	return delivered


## 照着「实际送出去的份数」从手上扣掉；顺带把「已上菜」飘字打出来。
##
## 【为什么要按份数扣，而不是每成功一次扣一份】
## 两者等价，但按份数写能表达出「送到了几份」这件事本身，
## 和飘字用的是同一个数字，不会出现「飘字说 2 份、手上只扣了 1 份」。
func _apply_delivered(delivered: Dictionary, router: Node) -> void:
	for item in delivered.keys():
		var n := int(delivered[item])
		for i in n:
			router.remove_from_hand(String(item))
		if router.waiter != null and is_instance_valid(router.waiter):
			Stickers.push_world(router.waiter.global_position + Vector2(0, -34),
				"上菜 %s×%d" % [Config.item_name(String(item)), n],
				Constants.COLOR_TEXT)
		else:
			router.say("上菜 %s×%d" % [Config.item_name(String(item)), n])


func _on_order_changed_ui(router: Node) -> void:
	Game.orders_changed.emit()
	if router != null and router.ui != null:
		router.ui.refresh_orders(Game.active_orders())


## 走不过去时的反馈。
## 服务员因为被家具挡住、绕不过去而放弃指令时，在这里飘一句，
## 免得玩家面对「点了没反应」完全摸不着头脑。
func _on_move_cancelled(reason: String) -> void:
	if reason == "":
		return
	Stickers.push_world(global_position + Vector2(0, -60), reason, Constants.COLOR_TEXT_DIM)


## 画耐心环 —— 只在这三个「等」的状态下显示
func _shows_ring() -> bool:
	return state == Constants.State.WAITING_TO_ORDER \
		or state == Constants.State.ORDER_TAKEN \
		or state == Constants.State.ORDERED


## 还差几样（**只用于内部逻辑，不显示在头顶**）。
##
## 【为什么不再给头顶用】
## 已与用户确认：菜名只保留在左侧订单票上。
## 头顶原来会显示「汉堡×2、可乐」这样的气泡，但经过可玩性分析后去掉：
##   - 玩家的决策链是「看票决定做什么菜 → 送到哪一桌」，气泡不参与决策；
##   - 同桌共享订单的模型下「谁点了哪份」在玩法上不存在（自动分配），
##     显示它既增加阅读负担、又和模型矛盾；
##   - 票和气泡各算一遍「已送达」= 两个真相来源，容易不一致；
##   - 客人头顶还有耐心环和 ! 号，再叠最宽的气泡会互相遮挡。
func remaining_items() -> int:
	return seat.remaining() if seat != null else 0


func _draw() -> void:
	# 影子
	draw_circle(Vector2(0, RADIUS * 0.6), RADIUS * 0.9, Color(0, 0, 0, 0.22))

	var body := Constants.COLOR_CUSTOMER
	if state == Constants.State.EATING:
		body = Constants.COLOR_CUSTOMER_EATING
	elif state == Constants.State.ANGRY_LEAVING:
		body = Constants.COLOR_CUSTOMER_ANGRY
	draw_circle(Vector2.ZERO, RADIUS, body)
	draw_arc(Vector2.ZERO, RADIUS, 0, TAU, 40, Color("2b3038"), 2.0)

	# 头顶：**不显示菜名**。
	#
	# 【为什么去掉了】
	# 已与用户确认：菜名只保留在左侧订单票上。
	# 理由（从可玩性分析得来）：
	#   1. 玩家的决策链是「看票决定做什么菜 → 送到哪一桌」，
	#      气泡里的菜名一个都不参与决策 —— 它不提供新信息；
	#   2. 同桌共享订单的模型下，「谁点了哪份」在玩法上是不存在的概念
	#      （上菜由 Table.assign_delivery 自动分配），把它显示出来
	#      既增加阅读负担，又和模型自相矛盾；
	#   3. 票和气泡各算一遍「已送达」，是两个真相来源，一旦不一致就是 bug；
	#   4. 客人头顶本来就有耐心环和 ! 号，再加最宽的气泡会互相遮挡，
	#      而且多桌并发时场景会糊成一片。
	# 菜名请到左侧订单票看；票上有桌号，桌上的小票标记帮你对上场景。

	# 头顶：耐心环
	if _shows_ring():
		_draw_patience_ring()

	# 头顶：等点单的 !
	if state == Constants.State.WAITING_TO_ORDER:
		_draw_exclamation()

	# 头顶：用餐中
	if state == Constants.State.EATING:
		_draw_bubble(Constants.MSG_EATING)


func _ring_center() -> Vector2:
	return Vector2(0, -RADIUS - RING_LIFT)


func _draw_patience_ring() -> void:
	var center := _ring_center()
	# 深灰底环
	draw_arc(center, RING_RADIUS, 0, TAU, 48, Constants.COLOR_PATIENCE_BG, RING_WIDTH, true)
	# 白色进度：12 点钟起顺时针
	var ratio := 0.0
	if patience_max > 0.0:
		ratio = clampf(patience / patience_max, 0.0, 1.0)
	if ratio <= 0.0:
		return
	var start := -PI * 0.5
	var end := start + TAU * ratio
	draw_arc(center, RING_RADIUS, start, end, 64, Constants.COLOR_PATIENCE_FG, RING_WIDTH, true)


func _draw_exclamation() -> void:
	var p := _ring_center() + Vector2(0, -RING_RADIUS - 11)
	var f := _bubble_font()
	if f == null:
		return
	var s := "!"
	var size := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, 20)
	draw_string(f, p - Vector2(size.x * 0.5, 0), s, HORIZONTAL_ALIGNMENT_LEFT, -1, 20,
		Color("ffdf5a"))
	draw_string_outline(f, p - Vector2(size.x * 0.5, 0), s, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, 4,
		Color(0, 0, 0, 0.7))


var _font_cache: Font = null


func _bubble_font() -> Font:
	if _font_cache == null:
		_font_cache = UiFont.get_font()
	return _font_cache


func _draw_bubble(text: String) -> void:
	var f := _bubble_font()
	if f == null:
		return
	var fs := 14
	var ts := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var pad := Vector2(7, 4)
	var box := Rect2(
		Vector2(-ts.x * 0.5 - pad.x, -RADIUS - BUBBLE_LIFT - ts.y - pad.y),
		Vector2(ts.x + pad.x * 2.0, ts.y + pad.y * 2.0))
	draw_rect(box, Constants.COLOR_BUBBLE_BG, true)
	draw_rect(box, Constants.COLOR_BUBBLE_BORDER, false, 1.0)
	draw_string(f, Vector2(box.position.x + pad.x, box.position.y + pad.y + ts.y * 0.82),
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Constants.COLOR_TEXT)
