@tool
extends EntityBase
## 桌子（含它自己的座位）。
##
## 三种状态（对应文档第九、十节）：
##   CLEAN_EMPTY 干净且无人 —— 客人可以坐
##   DIRTY       脏且无人   —— 必须先收拾，否则新客人不能坐
##   OCCUPIED    有人       —— 不论脏净
##
## 【订单模型：桌级共享，座位只记「谁拿到了什么」】
## 已与用户确认：一张票 = 同桌所有客人的菜合并（更符合现实，
## 服务员本来也不知道谁点的是哪份）。
##   耐心 → 客人级：每个客人各自等、各自气走
##   上菜 → 送到桌边，由本文件的 deliver() 自动分给「还没拿到这道菜」的客人
##
## 【脏桌什么时候产生】
##   - 同桌**所有**客人都吃完结账：立刻变脏（文档第八节）
##   - 客人气走：那个座位立刻空出；要是全桌都空了，桌子变干净，**不留脏桌**
##     （文档第十节）。还有人坐着就保持有人，免得把在座客人的桌子变成脏桌。
##
## 【椅子】
## 座位（Seat）是可点击物件的**数据**，由桌子统一画椅子、统一建碰撞盒。
## 这样做既避免了 Table → Seat → Table 的循环引用，
## 也让「服务员走到椅子边就停下」这种几何判定只有一处实现。

const SEAT_SCRIPT := preload("res://scripts/world/seat.gd")

## ── 编辑器摆放用的导出量 ──
##
## 【椅子在哪】椅子不再是这里的偏移数组，而是 **Chair 子节点**
## （见 scripts/world/chair.gd）。在这个 Table 下加 Chair 节点、拖到位置上，
## 代码就会把它们读成座位。好处是摆位置所见即所得，而且普通椅子
## 和卡座长凳可以各挂各的贴图。

## 是否用代码画**占位美术**（餐桌矩形 + 椅子色块 + 状态脏点）。
##
## 【默认 false：贴图优先】理由同 chair.gd 里的同名属性 ——
## 默认 `true` 会让色块和贴图重叠，且**编辑器里看不出来**（`_draw()` 在编辑器
## 走参考线分支），只有 F5 才暴露。还没有贴图时再手动勾上。
##
## 关掉只影响"画不画"，状态（干净/脏/有人）的数据与逻辑完全不受影响。
@export var draw_placeholder: bool = false

## 关掉它并手填 table_id，这张桌就不再参与自动编号（见 level.gd 的 _renumber_tables）。
##
## 【为什么要有这个开关】桌子的编号默认由位置自动决定 —— 复制粘贴桌子时最省事。
## 但有时你想让某张桌固定叫「桌2」（比如测试断言、或关卡设计需要），
## 那么关掉它、手填编号即可。自动编号只会分配**没被手工占用**的号，两者能混用。
@export var auto_table_id: bool = true

## 桌号。**正常运行由代码自动分配**（按位置从上到下、从左到右编号），所以不用管它。
##
## 【什么时候需要你手填】把上面的 `auto_table_id` 关掉，再在这里填一个号，
## 这张桌就固定用这个号（自动编号会跳过已被占用的号）。
## 这里也导出成 @export 就是为了让你能在检查器里直接填 ——
## 否则「手动覆盖编号」这条路在编辑器里根本走不通。
@export var table_id: int = 0
var seats: Array = []            ## Array[Seat]
var state: int = TableRules.State.CLEAN_EMPTY

## 桌级共享订单（null = 还没有单）
var order: Order = null

## 这一桌是否「吃完了」（用于结账：气走的单子不给钱）
var meal_completed: bool = false
## 该收多少钱。
##
## 【为什么要单独存金额，而不是结账时读 order】
## 票送齐以后 order 会被置空（那样订单栏上的票才会消失）。
## 但结账发生在客人**走到门口**那一刻，比置空晚 ——
## 于是 `if order == null: return` 直接跳过结账，钱永远是 0（玩家报的 bug）。
## 所以送齐的时候就把金额记下来，结账只看这个数。
var bill_amount: int = 0
## 账是否已经结过（同桌只结一次）
var _bill_settled: bool = false

## 桌子变「干净且无人」的时刻，用于「空桌出现已超过 2s」判定
var available_since: float = 0.0

var _dirty_marks: Array[Vector2] = []


func setup(p_id: int, p_rect: Rect2, p_seats: Array, p_build_seat_bodies: int = 0) -> void:
	table_id = p_id
	kind = Constants.Kind.TABLE
	label = "桌%d" % p_id
	display_label = label
	position = p_rect.position

	# 座位：p_seats 里的 pos 是相对桌子左上角的。
	# `sit_pos` 可能带（椅子节点给的），不带就退回 pos（= 旧行为）。
	seats.clear()
	for s in p_seats:
		var seat: Seat = SEAT_SCRIPT.new(
			s["pos"],
			s.get("size", Vector2(40, 30)),
			int(s.get("facing", 0)),
			s.get("sit_pos", null))
		seats.append(seat)

	# 【清掉旧的座位碰撞体】这个函数会被重复调用（每开一局都重跑搭建流程），
	# 而椅子碰撞体是下面 build_seat_bodies() 现建的 —— 不清就会一局叠一层，
	# 寻路网格跟着多一层障碍，表现是「隔着老远就绕路」这种莫名其妙的路径。
	_clear_body_shapes()

	# 碰撞盒：桌面中部。
	# 【为什么可以铺到接近满宽了】以前要留出 8% 给「坐在桌沿上的客人」，
	# 现在客人坐在椅子上、椅子自己有碰撞盒，所以桌面碰撞盒只管桌面本身。
	# 于是服务员不可能再踩到桌面 —— 这正是玩家报的那个问题。
	setup_shape(Rect2(Vector2.ZERO, p_rect.size),
		Rect2(Vector2(0, p_rect.size.y * 0.25), Vector2(p_rect.size.x, p_rect.size.y * 0.75)))

	body_color = Constants.COLOR_TABLE_CLEAN
	_make_dirty_marks()
	mark_available()
	if p_build_seat_bodies > 0:
		build_seat_bodies()


## 给每个座位建一个静态碰撞体（椅子会挡路）。
##
## 【为什么默认由「自动生成」路径显式打开，而编辑器路径关掉】
## 两条路对「椅子碰撞盒归谁」的要求正好相反：
##   - **编辑器摆放**（你手摆椅子）→ 椅子是独立的 `StaticBody2D`、自带碰撞盒，
##     桌子**不该**再生成，否则两套叠一起（寻路网格那块被重复标记，
##     表现是「隔着老远就绕路」，静默且难查）。
##   - **自动生成**（`level.gd` 按 layout.json 造家具 —— 测试走这条）
##     → 那时根本没有 Chair 节点，**必须**由桌子生成，
##     否则「椅子挡路」这件事凭空消失、座位可达性跟着变。
##
## 【为什么是参数而不是两个函数】生成路径调的是同一个 `setup()`，
## 用一个参数分流比复制一份 setup 安全得多（那套几何是修过 bug 的）。
func build_seat_bodies() -> void:
	for seat in seats:
		var cs := CollisionShape2D.new()
		var shape := RectangleShape2D.new()
		shape.size = seat.size
		cs.shape = shape
		cs.position = seat.pos
		add_child(cs)


## 从 **Chair 子节点**读出座位，转成 setup() 要的字典数组。
##
## 【这是「椅子拆成节点」的落点】
## 椅子现在是场景里的独立节点（见 scripts/world/chair.gd），它们的位置由你
## 在编辑器里拖出来，而不是写一串偏移数字。这里把「节点位置」翻译成
## setup() 认识的 `{pos, size, facing}`，于是下游（建碰撞盒 / 画椅子 /
## 客人坐哪）**一行都不用改** —— 位置从哪来，和位置怎么用，被这条转换隔开了。
##
## 【两套坐标别混】椅子是 Table 的子节点，所以它的 `position` 已经是
## **相对桌子原点**的局部坐标，正好就是 Seat.pos 要的形式，不用换算。
## 而 `pos`（椅子中心）与 `sit_pos`（客人身体）分开传：
## 前者管碰撞盒和椅子外观，后者管客人坐哪。
func seats_from_chairs() -> Array:
	var out: Array = []
	for c in get_children():
		if not (c is Chair):
			continue
		var chair := c as Chair
		out.append({
			"pos": seat_body_pos(chair),
			"size": chair.size,
			"facing": Chair.to_legacy_facing(chair.back),
			"sit_pos": chair.position + chair.sit_offset_for_body(),
		})
	return out


## 椅子的**碰撞盒中心**（相对桌子原点）。
##
## 【为什么要从「客人身体位置」反推椅子本体位置】
## Chair 节点的原点是「客人身体中心」（这样摆位置最直观），
## 而碰撞盒要盖住的是椅子本体 —— 也就是从身体位置往**椅背方向**退半个椅子。
## Chair.chair_rect() 就是这个反推（它描述椅子相对原点的占位），取它的中心即可。
func seat_body_pos(chair: Chair) -> Vector2:
	return chair.position + chair.chair_rect().get_center()


## 编辑器摆放后的自绑定。位置用节点自己的，椅子从子节点读。
func setup_from_editor() -> void:
	# 尺寸优先跟贴图走。必须在 setup() 之前 —— setup() 用 rect 算桌面碰撞盒
	# 和脏点位置，晚了就会用旧的默认尺寸算一遍。
	fit_rect_size_to_sprite()
	if not auto_generate_shapes:
		# 碰撞盒由你自己摆：只同步视觉矩形，不建桌面、也不建椅子碰撞体。
		# 【注意这里**没有** _clear_body_shapes()】因为那会把你摆的也删掉。
		rect = Rect2(Vector2.ZERO, rect_size)
		_setup_table_data_only()
		queue_redraw()
	elif has_manual_shapes():
		# 没关开关，但身上已经有碰撞盒了 → 当成「你已经摆了」，同样不重复生成。
		# 这是防止「忘了关开关」导致两套碰撞盒叠在一起。
		rect = Rect2(Vector2.ZERO, rect_size)
		_setup_table_data_only()
		queue_redraw()
	else:
		# 兜底：自动按比例生成（桌面 + 每把椅子各一个）
		_clear_body_shapes()
		setup(0 if auto_table_id else table_id,
			Rect2(Vector2.ZERO, rect_size),
			seats_from_chairs())
	# 手工指定编号时，label 也要跟着自己的编号走
	# （自动编号那条路由 level.gd 的 _renumber_tables 统一刷 label）
	if not auto_table_id:
		label = "桌%d" % table_id
		display_label = label


## 只建立「桌子作为座位容器」需要的数据，不碰碰撞形状。
##
## 【什么时候用】碰撞盒由你在编辑器里摆的时候。
## 【为什么座位数据必须建】订单是**桌级共享**的，客人落座、上菜分配、
## 结账都依赖 `seats` 数组。碰撞盒归你管，但座位数据归逻辑管 ——
## 不建的话客人无处可坐，而且不报错。
func _setup_table_data_only() -> void:
	kind = Constants.Kind.TABLE
	if label == "" or label == null:
		label = "桌1"
	display_label = label
	seats.clear()
	for s in seats_from_chairs():
		var seat: Seat = SEAT_SCRIPT.new(
			s["pos"],
			s.get("size", Vector2(40, 30)),
			int(s.get("facing", 0)),
			s.get("sit_pos", null))
		seats.append(seat)
	body_color = Constants.COLOR_TABLE_CLEAN
	_make_dirty_marks()
	mark_available()


func _make_dirty_marks() -> void:
	_dirty_marks.clear()
	var r := rect.size
	for i in 5:
		var fi := float(i)
		_dirty_marks.append(Vector2(
			r.x * (0.18 + 0.16 * fi),
			r.y * (0.30 + 0.22 * float((i * 3) % 4))))


func mark_available() -> void:
	available_since = _now()


## 空桌已经存在多久了（秒）
func available_duration() -> float:
	return _now() - available_since


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


# ── 座位 ───────────────────────────────────────────────────────────

func seat_count() -> int:
	return seats.size()


func free_seats() -> Array:
	var out: Array = []
	for s in seats:
		if s.is_free():
			out.append(s)
	return out


func occupied_seats() -> Array:
	var out: Array = []
	for s in seats:
		if not s.is_free():
			out.append(s)
	return out


func customers() -> Array:
	var out: Array = []
	for s in seats:
		if not s.is_free():
			out.append(s.occupant)
	return out


## 这位客人坐的座位（找不到返回 null）
func seat_of(c: Node) -> Seat:
	for s in seats:
		if s.occupant == c:
			return s
	return null


## 座位中心的世界坐标（客人该站/坐的地方）
func seat_sit_point(seat: Seat) -> Vector2:
	return to_global(seat.sit_offset())


func seat_center(seat: Seat) -> Vector2:
	return to_global(seat.pos)


# ── 状态 ───────────────────────────────────────────────────────────

func on_seat_taken(seat: Seat, c: Node) -> void:
	seat.take(c)
	state = TableRules.State.OCCUPIED
	_refresh_look()


## 客人走到门口、座位还回来了。
##
## 【为什么座位要等到「到门口」才还，而不是「一起身」就还】
## 全桌一起起身时，如果一起身就把座位清空，桌子会立刻判定「没人了」
## 而变脏；但客人还在往门口走，视觉上会出现「人还在店里，桌子已经脏了」。
## 等到门口再还，时序就对得上了：
##   起身（都进入 LEAVING）→ 各自走到门口 → 最后一个到门口时桌子变脏。
##
## 【为什么必须先判断「桌子还是有人状态」】
## 这是玩家报的一个 bug：客人不耐烦气走时，桌子明明没被用过，却变脏了。
## 原因是气走这条路**在 leave_all(true) 里就已经把桌子设成干净了**
## （文档第十节：气走不留脏桌），可是客人走到门口时又会调用本函数，
## 此时座位早已清空 →「全空就变脏」无条件执行，把干净的桌子又改成脏的。
## 加这一道状态判断：只有桌子当前确实处于「有人」状态时，
## 这次离场才意味着一桌人真的走完了。
##
## 【结账不在这里了】已改为「一起身（leave_all）就结算」，
## 见 leave_all 里的说明。这里只负责「还座位 + 最后一个人到门口时变脏」。
func member_vacated(seat: Seat) -> void:
	seat.release()
	# 桌子已经被标记为干净（说明这一桌是气走的，不是吃完的）→ 不要再弄脏
	if state != TableRules.State.OCCUPIED:
		_refresh_look()
		return
	if occupied_seats().is_empty():
		order = null
		state = TableRules.State.DIRTY
		_refresh_look()
		Game.orders_changed.emit()
	_refresh_look()


## 客人吃完结账走了（保留给测试/工具直接调用；正常流程走 member_vacated）
func on_customer_left(seat: Seat) -> void:
	member_vacated(seat)


## 结算这一桌的账（只结一次）。气走的那一单收不到钱，所以不结。
##
## 【金额来源】bill_amount —— 在「开单」和「送齐置空」两处都会记下，
## 所以即使 order 已经被置空（票消失了），结账照样拿得到钱。
func _settle_bill() -> void:
	if _bill_settled:
		return
	_bill_settled = true
	if not meal_completed:
		return          # 气走的单子不给钱
	if bill_amount <= 0:
		return
	Game.add_money(bill_amount)
	float_text("+%d 元 · 结账" % bill_amount, Constants.COLOR_MONEY)


## 整桌一起吃完了吗（所有在座客人都已结束用餐）
func all_meals_done() -> bool:
	var occ := occupied_seats()
	if occ.is_empty():
		return false
	for s in occ:
		if not s.occupant.call("is_meal_done"):
			return false
	return true


## 整桌一起走（吃完了 / 或一人气走全桌跟着走）
##
## 【为什么整桌一起走】
## 已与用户确认：一组客人一起来、一起走。
## 「各吃各的，但一起起身」—— 各人 12 秒计时独立，
## 先吃完的留在座位上等，等最后一位也吃完，全桌一起起身。
##
## angry = true 表示气走：整桌都不结账，而且桌子不留脏（文档第十节）。
func leave_all(angry: bool) -> void:
	# 【在这里收钱，不等走到门口】
	# 已与用户确认：**客人离开座位（一起身）那一刻就结算**。
	#
	# 为什么不能挂在「走到门口」那一刻（原来就是这么写的，结果钱一直是 0）：
	# 票送齐时会把 order 置空（那样订单栏的票才会消失），
	# 而结账发生在走到门口时，比置空晚 —— 结账拿不到单子了。
	# 改成起身就结：时机更直观，也不依赖 order 还在不在
	# （金额在 open_order 时就记在 bill_amount 里了）。
	if not angry:
		_settle_bill()
	for s in occupied_seats():
		s.occupant.call("leave_now", angry)
	if angry:
		# 气走：座位一次性清空、桌子立刻变空可用（不留脏桌）
		for s in seats:
			s.release()
		order = null
		state = TableRules.State.CLEAN_EMPTY
		mark_available()
		_refresh_look()
		Game.orders_changed.emit()


## 客人气走：整桌跟着一起走（见 leave_all）
func on_customer_angry(_seat: Seat) -> void:
	leave_all(true)


## 收拾完成
##
## 【不能无条件设成 CLEAN_EMPTY】正常情况下收拾期间不会有客人（选座已经把
## 「正在被收拾」的桌排除掉了），但这里是最后一道防线：
## 万一真的有人坐上来了，**必须保留 OCCUPIED**，否则桌子会对外宣称
## 「我干净又没人」——玩家点它就会看到「这桌是空的」，
## 而椅子上明明坐着人（这就是玩家实测报的那个错乱状态）。
func finish_clean() -> void:
	if not occupied_seats().is_empty():
		# 有人在座：收拾干净了，但桌子仍归「有人」管，不能变回空桌
		state = TableRules.State.OCCUPIED
		_refresh_look()
		return
	state = TableRules.State.CLEAN_EMPTY
	mark_available()
	_refresh_look()


## 把桌子硬复位成「干净、无人、无单」——**重开一局时用**。
##
## 【为什么必须有这个入口，不能在外面直接改 state】
## 桌子的**颜色和脏点全靠 _refresh_look() 里的 queue_redraw()**。
## 从外面写 `t.state = CLEAN_EMPTY` 只改了数据、视觉不刷新 ——
## 表现是「上一局的脏桌进了新一局还是脏的，要等鼠标动一下才变干净」
## （玩家实测报的 bug：看起来延迟约 2 秒）。
## 改状态和刷新视觉必须成对，所以收口到这里。
func reset_to_clean() -> void:
	for s in seats:
		s.release()
	order = null
	_bill_settled = false
	meal_completed = false
	bill_amount = 0
	state = TableRules.State.CLEAN_EMPTY
	mark_available()
	_refresh_look()


func _refresh_look() -> void:
	match state:
		TableRules.State.CLEAN_EMPTY:
			body_color = Constants.COLOR_TABLE_CLEAN
		TableRules.State.DIRTY:
			body_color = Constants.COLOR_TABLE_DIRTY
		_:
			body_color = Constants.COLOR_TABLE_BUSY
	queue_redraw()


# ── 共享订单 ───────────────────────────────────────────────────────

## 订单内容 = 同桌所有客人自己点的菜合并。
## 按座位顺序拼接，结果稳定（同一批客人每次算出来一样），测试才好断言。
func group_items() -> Array[String]:
	var out: Array[String] = []
	for s in seats:
		for id in s.pending:
			out.append(id)
	return out


## 开一张共享订单（玩家接单时调用）
func open_order() -> Order:
	var items := group_items()
	order = Order.new(table_id, items)
	# 记下该收的钱：结账发生在客人走到门口那一刻，
	# 而那时 order 可能已经被置空（票消失），所以金额必须单独存。
	bill_amount = order.total_price()
	meal_completed = false
	_bill_settled = false
	Game.orders_changed.emit()
	queue_redraw()
	return order


## 桌边还有人在等这道菜吗
func wants_from_seats(item_id: String) -> bool:
	for s in seats:
		if s.is_free():
			continue
		if s.wants(item_id):
			return true
	return false


## 送到桌边的这份菜归谁：给「还没拿到这道菜」的第一个客人。
## 返回被服务的客人（没人要则 null）。
func assign_delivery(item_id: String) -> Node:
	for s in seats:
		if s.is_free():
			continue
		if s.wants(item_id):
			s.mark_got(item_id)
			# 票上的「已送达」标记也要跟上
			if order != null:
				order.deliver(item_id)
			# 这位客人齐了 → 开始用餐
			if s.all_got() and s.occupant.has_method("start_eating"):
				s.occupant.call("start_eating")
			return s.occupant
	return null


func remaining_on_ticket() -> int:
	if order == null:
		return -1
	return order.remaining_count()


# ── 点击 ───────────────────────────────────────────────────────────

func accepts_click() -> bool:
	if TableRules.is_cleanable(state):
		return true
	# 有客人坐着（等点单的）：点桌子也能接单，和点客人等价
	for s in seats:
		if not s.is_free():
			return true
	return false


func interact(router: Node) -> int:
	# 1) 脏桌：走过去 → 碰到桌子时再检查 → 3s 收拾（不可取消）
	if TableRules.is_cleanable(state):
		router.go_then(walk_to(), Callable(self, "_do_clean"), "收拾" + label, self)
		return RouterResult.ACCEPTED

	# 2) 有客人在等点单：点桌子等价于点那位客人
	for s in seats:
		if s.is_free():
			continue
		if s.occupant.has_method("is_waiting_to_order") and s.occupant.call("is_waiting_to_order"):
			return int(s.occupant.call("interact", router))

	# 3) 桌子本身就没人 → 一律先说「这桌是空的」
	#
	# 【为什么这一条必须排在「手上有菜」前面】
	# 原来「手上有菜 → 没人要 → 说没点这个菜」写在前面，于是
	# **手里拿着菜去点一张空桌**会得到「这不是他要的菜」——
	# 可桌上一个客人都没有，这句提示完全不成立（玩家实测报的 bug）。
	# 「桌上有没有人」比「手上是什么菜」更基础，必须先问。
	if occupied_seats().is_empty():
		router.say(Constants.MSG_TABLE_EMPTY, Constants.COLOR_TEXT_DIM)
		return RouterResult.NO_ACTION

	# 4) 有客人 + 手上有这桌还没人认领的菜 → **点桌子也能上菜**（已与用户确认等价）
	#
	# 【为什么交给某位客人去执行】
	# 上菜这一整套逻辑（走到桌边 → 到达时再检查 → 交给 Table.assign_delivery 分配）
	# 已经在 Customer 里写好了，而且它本来就是「走到桌边」而不是走到客人身上。
	# 所以这里挑一位代跑一遍，不重复实现。
	# 手上可能有 2 份，所以判断是「**手上任何一样**这桌还缺」。
	if not Game.hand_is_empty():
		var who := _someone_wanting_any()
		if who != null:
			return int(who.call("interact", router))
		router.say(Constants.MSG_WRONG_DISH)
		return RouterResult.NO_ACTION

	# 5) 有客人但手上没菜
	router.say(Constants.MSG_HAND_EMPTY)
	return RouterResult.NO_ACTION


## 找一位「还缺我手上某一样菜」的客人（没有则 null）
func _someone_wanting_any() -> Node:
	for id in Game.hand_items():
		for s in seats:
			if s.is_free():
				continue
			if s.wants(id):
				return s.occupant
	return null


## 找一位「还缺这道菜」的客人（没有则 null）
func _someone_wanting(item_id: String) -> Node:
	for s in seats:
		if s.is_free():
			continue
		if s.wants(item_id):
			return s.occupant
	return null


## 到达时检查 + 执行。返回 false = 条件不满足，动作取消。
func _do_clean(router: Node) -> bool:
	if not TableRules.is_cleanable(state):
		return false
	if router.waiter.is_locked():
		return false
	DebugTrace.note_clean_start(self, router.waiter)
	router.waiter.begin_clean(self, Config.num("clean_time"))
	return true


## 服务员该站哪 —— 只作为**参考点**保留（工具/测试用）。
## 真正的到达判据是「碰到桌子的可碰区」。
func walk_to() -> Vector2:
	return global_position + Vector2(rect.size.x * 0.5, collision_rect().end.y + 12.0)


## 可碰判定用的矩形 = **整个桌面**（不是碰撞盒）。
##
## 【为什么要和碰撞盒分开】碰撞盒是 `(0, h*0.25, w, h*0.75)`，
## 只占桌面下面 3/4 —— 它同时喂给寻路网格，改它会牵动「座位可达性」
## 「服务员不压桌面」等一批已验证的行为，风险很大。
##
## 但「碰到桌子」的判定必须按**眼睛看到的桌面**算，否则：
##   - 站在椅子旁边（离桌面盒 12px < 服务员半径 16）会被误判成碰到桌子
##     → 玩家看到的「碰椅子也能清洁」
##   - 站在桌子正上方（y 400..415，视觉上贴着桌面）反而判定不到
## 两件事都源于判定盒比视觉桌面少了最上面 15px。
## 现在判定用完整桌面，寻路仍然用碰撞盒，各取所需。
func touch_box() -> Rect2:
	# 【手摆碰撞盒时以你摆的为准】见 manual_touch_box 的说明：
	# 碰撞盒是桌子的真实占位，rect_size 只是贴图范围，两者可以不一样。
	var manual := manual_touch_box()
	if manual.size.x > 0.0 and manual.size.y > 0.0:
		return manual
	# 【必须是 global_position，不能是 position】
	# 原先写的是 Rect2(position, rect.size)。在「节点被 setup() 挪到 JSON 坐标」
	# 的旧模型下两者数值恰好相等，所以一直是对的。但家具改成**编辑器摆放**以后，
	# 节点位置由你自己拖，rect 只是「以节点原点为基准的尺寸」——
	# 这时 position 是局部坐标，用它算出来的判定盒会**停在原位不动**：
	# 桌子明明拖走了，判定盒还留在旧地方 → 点脏桌时服务员走过去却永远
	# 判定不到「碰到了」，表现为**不报错的卡死**。
	# global_position 是位置无关的写法，两种摆放方式都对。
	# 注意：rect.size 是整张桌子的尺寸，而节点原点 = 桌子左上角。
	return Rect2(global_position, rect.size)


## 手动摆了碰撞盒时，「碰到桌子」的可碰区 = 你摆的那些形状的外接矩形。
##
## 【为什么要这样】`touch_box` 是「服务员身体碰到桌子了吗」的判据。
## 碰撞盒由你摆时，它才是桌子的真实占位；而 `rect_size`（贴图尺寸）只是视觉范围。
## 两者在门口那类家具上可以差很远，用贴图范围当判据会出现
## 「离桌子老远就判定碰到了」。
## 返回 size 为 0 表示「没手摆碰撞盒」，调用方会退回贴图范围。
func manual_touch_box() -> Rect2:
	if not has_manual_shapes():
		return Rect2()
	var box := _manual_shapes()
	return Rect2(to_global(box.position), box.size)


# ── 画 ─────────────────────────────────────────────────────────────

func _draw() -> void:
	# 【编辑器里只画参考线】桌子是家具里几何最复杂的一件，所以参考线也最多：
	#   蓝框 = 桌面碰撞盒（下部 75%，决定服务员能不能贴过来）
	#   红框 = 每把椅子的碰撞盒（椅子会挡路）
	#   红点 = 客人身体位置 / 黄箭头 = 客人面朝方向
	# 这三样在编辑器里「看得见」很关键 —— 否则你摆完只能靠 F5 猜。
	if Engine.is_editor_hint():
		_draw_editor_chair_guides()
		return

	# 【占位美术的开关粒度】
	#   桌子的 draw_placeholder → 控制桌面矩形 + 脏点 + 悬停高亮
	#   每把 Chair 自己的 draw_placeholder → 只控制那一把椅子的色块
	# 分开是有用的：你可以先把桌子换成真贴图、椅子还留着占位色块，
	# 边换边看，不必两件一起换。
	if draw_placeholder:
		super._draw()

		# 先画椅子（在桌子下面一层，客人再画在椅子上）
		for s in seats:
			if _chair_placeholder_on(s):
				_draw_chair(s)

		if state == TableRules.State.DIRTY:
			for p in _dirty_marks:
				draw_circle(p, 3.0, Color("3d3226"))
				draw_circle(p + Vector2(4, 3), 2.0, Color("5a4a38"))
	elif not seats.is_empty():
		# 桌子已换真贴图、但椅子还没换 → 仍然画椅子色块
		for s in seats:
			if _chair_placeholder_on(s):
				_draw_chair(s)

	# 【桌角的小票标记已删除（玩家要求）】
	# 原来在这里给「已开单」的桌子画一个米白色小方块，本意是
	# 「让玩家把左侧订单票和场景里的桌子对上号」。
	# 但一个空方块没有任何小票特征，玩家看到只会疑惑「这是什么」，
	# 起不到提示作用反而成了噪音。已确认直接去掉。
	# 「哪一桌有单」请以左侧订单票上的桌号为准。


## 这个座位对应的椅子要不要画占位色块？
##
## 【为什么要查子节点，而不是在 Seat 上存一个布尔】占位开关属于**美术配置**，
## 它天然属于场景里的 Chair 节点；Seat 是运行时数据，不该背这个字段。
## 两边靠「椅子在桌子下的序号」对应 —— 这与 build_seat_bodies() 建碰撞盒时
## 用的是同一个顺序，所以不会错位。
func _chair_placeholder_on(seat: Seat) -> bool:
	var idx := seats.find(seat)
	var chairs: Array = []
	for c in get_children():
		if c is Chair:
			chairs.append(c)
	if idx < 0 or idx >= chairs.size():
		return true
	return bool((chairs[idx] as Chair).draw_placeholder)


## 椅子：座垫 + 靠背（靠背朝外，客人面朝桌子）
func _draw_chair(s: Seat) -> void:
	var r := s.chair_rect()
	var ply := 4.0
	if s.is_free():
		draw_rect(r, Constants.COLOR_CHAIR_FREE, true)
	else:
		draw_rect(r, Constants.COLOR_CHAIR_TAKEN, true)
	draw_rect(r, Color(0, 0, 0, 0.45), false, 1.5)

	# 靠背：贴在远离桌子的那一侧
	var back := Rect2()
	if s.facing > 0:
		# 椅子在桌子右侧、客人面朝左 → 靠背在右边
		back = Rect2(r.position.x + r.size.x - ply, r.position.y, ply, r.size.y)
	elif s.facing < 0:
		back = Rect2(r.position.x, r.position.y, ply, r.size.y)
	else:
		back = Rect2(r.position.x, r.position.y, r.size.x, ply)
	draw_rect(back, Constants.COLOR_CHAIR_BACK, true)

	# 座位号，方便对着截图排查谁坐哪
	var f := _get_font()
	if f != null:
		var idx := seats.find(s) + 1
		var txt := str(idx)
		var size := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
		draw_string(f, r.get_center() - Vector2(size.x * 0.5, -4.0), txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.45))


## 编辑器参考线：桌面碰撞盒 + 每把椅子的碰撞盒与座位位置。
##
## 【为什么在编辑器里直接读 Chair 子节点，而不是读 seats 数组】
## `seats` 是运行时数据，由 setup_from_editor() 填 —— 那一步在编辑器里**不会跑**。
## 但参考线偏偏要在编辑器里就看得见，所以这里直接遍历子节点，
## 用与运行时**同一套**几何函数（Chair.chair_rect / sit_offset_for_body）
## 现算一遍。同一套函数是关键：参考线和实际碰撞盒不会走出两个样子。
func _draw_editor_chair_guides() -> void:
	var col := collision_box_local()
	if col.size.x > 0.0 and col.size.y > 0.0:
		_draw_gizmo_box(col, Color(0.25, 0.6, 1.0, 0.18), Color(0.35, 0.7, 1.0, 0.95))
	for c in get_children():
		if not (c is Chair):
			continue
		var ch := c as Chair
		# 椅子的碰撞盒：Chair 的占位框平移到它在桌子里的位置
		var chair_local := ch.chair_rect()
		chair_local.position += ch.position
		# 面朝方向 = 背离椅背
		var back_dir := Vector2.ZERO
		match ch.back:
			Chair.Back.LEFT:
				back_dir = Vector2(-1.0, 0.0)
			Chair.Back.RIGHT:
				back_dir = Vector2(1.0, 0.0)
			Chair.Back.UP:
				back_dir = Vector2(0.0, -1.0)
			Chair.Back.DOWN:
				back_dir = Vector2(0.0, 1.0)
		_draw_gizmo_seat(ch.position + ch.sit_offset_for_body(), chair_local, back_dir)
