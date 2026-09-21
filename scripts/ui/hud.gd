extends Control
## HUD（文档第十四节）。
##
##   左上角   第 N 关 · 倒计时 · 收入（就这一行）
##   （原来还有 钱 / 已接待人数 / 空桌数 / 待收拾数 / 在店人数 / 出餐口 / 后厨队列
##     七行，本轮按玩家要求删掉了；数据仍在 Game.hud_snapshot() 里算着）
##   左侧     订单栏
##   左下角   手上餐品
##
## 【为什么整个 HUD 都 mouse_filter = IGNORE】
## 文档说「仅鼠标左键」操作场景。如果 HUD 这块 Control 吃掉鼠标事件，
## 屏幕左上角那一带的空地就永远点不动了。
## 所以 HUD 只负责看，不负责吃点击。

const ORDER_PANEL_SCRIPT := preload("res://scripts/ui/order_panel.gd")
const STAR_ICON_SCRIPT := preload("res://scripts/ui/star_icon.gd")

## 顶部「关卡目标栏」的星星尺寸与数字字号（玩家要求「放大、要醒目」）
const STAR_BAR_SIZE := 40.0

var _order_panel: Control = null
var _hand_label: Label = null
var _hand_slot: Control = null
## 关卡那一行（左上角唯一一行）：第 N 关 · 倒计时 · 收入
var _level_label: Label = null
## 顶部中间的「关卡目标栏」：三颗星 + 每档的「当前/目标」
var _target_bar: PanelContainer = null
## 三颗星（按 1★→3★ 从左到右）
var _star_icons: Array[Control] = []
## 三颗星下面各自的「当前/目标」数字
var _star_labels: Array[Label] = []
var _last_snapshot: Dictionary = {}
## 左上角那个 VBox（现在只装关卡那一行）
var _stats_box: VBoxContainer = null


func build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 【每次重建先把上一次的控件清掉】
	# build() 会在**同一个 HUD 实例**上被反复调用（UI.hud 是 autoload 单例，
	# 而 setup() 每开一局就调一次 build）。原先不清旧控件，于是每开一局
	# 就往同一个 HUD 上再叠一整套控件：
	#   - 界面上看不出问题（新控件正好盖在旧控件上面），
	#   - 但布局在「旧的还没算完」和「新的又建了」之间反复横跳，
	#     曾经把订单栏的重排自递归续期无限拉长 →
	#     最终在节点释放后继续跑，进程级访问违例。
	# 清掉之后，HUD 永远只有一套控件，布局一次就收敛。
	for child in get_children():
		remove_child(child)
		child.queue_free()

	# ── 左上角状态 ──
	var box := VBoxContainer.new()
	box.position = Vector2(20, 20)
	box.add_theme_constant_override("separation", 4)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)
	_stats_box = box

	# ── 左上角：关卡那一行（第 N 关 · 倒计时 · 收入） ──
	#
	# 【左上角现在只有这一行】原来下面还有七行（钱 / 已接待人数 / 空桌数 /
	# 待收拾数 / 在店人数 / 出餐口 / 后厨队列）+ 一行星级门槛文字，
	# 本轮玩家要求**只保留「第 N 关、倒计时、收入」**，其余全删。
	# 顶中那三颗星见下面 `TargetBar`。
	#
	# ── 顶部中间的「关卡目标栏」 ──
	#
	# 【本轮改动（玩家要求）】原来星级是左上角一行纯文字
	# `★3 80 ／ ★2 70 ／ ★1 60`，玩家反馈「看不到每星目标」。
	# 现在改成**顶部正中一块醒目的栏**：三颗星（1★→3★，目标递增），
	# 星下面是「当前/目标」，达到哪一档就把那颗星点亮成金黄。
	# 玩家还要求去掉「还差多少」——目标金额已经在星下面了，不再重复。
	#
	# 【为什么不用普通 Label 拼】拼出来是一行字，玩家扫不到；
	# 三颗星是「离下一颗还差多少」最直观的载体，而 `star_icon.gd` 本来就是
	# 现成的控件（结算界面在用），直接复用，不新造零件。
	#
	# 【为什么放顶部中间】那里是空场地（后厨窗口在 y=96 以下、饮料机在 x=735
	# 右侧），且在 1280 宽的屏幕上居中，离左上角的状态栏有足够距离。
	# 这一块也 `mouse_filter = IGNORE`，不会挡住点场景。
	var bar := PanelContainer.new()
	bar.name = "TargetBar"
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.42)
	sb.corner_radius_top_left = 10
	sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_left = 10
	sb.corner_radius_bottom_right = 10
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 7.0
	sb.content_margin_bottom = 7.0
	bar.add_theme_stylebox_override("panel", sb)
	add_child(bar)
	_target_bar = bar

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(row)

	# 【只放星星，不放文字】原来想把「第 N 关 · 倒计时 · 钱」也塞进来，
	# 结果整块宽到 374px、右边界压住饮料机（x=735）。
	# 现在的分工是：**关卡/倒计时/钱回到左上角状态栏**（信息归信息），
	# 顶中这块只负责「三颗星 + 每档目标」，一眼看清还差多少。
	# 宽度只剩星星那一段（约 190px），左右都留足空档。
	var stars_box := HBoxContainer.new()
	stars_box.alignment = BoxContainer.ALIGNMENT_CENTER
	stars_box.add_theme_constant_override("separation", 12)
	stars_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(stars_box)

	_star_icons.clear()
	_star_labels.clear()
	for i in 3:
		var cell := VBoxContainer.new()
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_theme_constant_override("separation", 0)
		stars_box.add_child(cell)

		var star: Control = Control.new()
		star.set_script(STAR_ICON_SCRIPT)
		star.custom_minimum_size = Vector2(STAR_BAR_SIZE, STAR_BAR_SIZE)
		star.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		star.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(star)
		_star_icons.append(star)

		# 【星下面是「当前/目标」】只写目标数字的话，玩家还是得自己做减法；
		# 写成 `45/60` 就一眼看出这一档还差多少，而且三颗星并排时不会乱。
		var num := Label.new()
		num.text = "0/0"
		num.add_theme_font_size_override("font_size", 16)
		num.add_theme_color_override("font_color", Constants.COLOR_TEXT)
		# 【必须关掉默认的 wrap】Label 拿到 1px 宽度时会按字符竖排，
		# 高度瞬间变成上百像素（实测把整块撑到 135px 高）。
		num.autowrap_mode = TextServer.AUTOWRAP_OFF
		num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		num.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(num)
		_star_labels.append(num)

	# 居中要等容器算出自身宽度 → 每次 HUD 尺寸变化时重算（含首帧）
	if not resized.is_connected(_place_target_bar):
		resized.connect(_place_target_bar)
	_place_target_bar()

	# ── 关卡模式一行：第 N 关 · 倒计时 · 钱 ──
	#
	# 【左上角现在只剩这一行】原来它下面还有七行数据（钱 / 已接待人数 / 空桌数 /
	# 待收拾数 / 在店人数 / 出餐口 / 后厨队列），本轮玩家要求**全删掉**，
	# 只留「第几关、还剩多久、现在多少钱」。信息仍然在 `Game.hud_snapshot()`
	# 里算着（工具/测试还在用），只是不再显示到 HUD 上。
	var level_label := Label.new()
	level_label.name = "LevelLine"
	level_label.text = ""
	level_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	level_label.add_theme_font_size_override("font_size", 16)
	level_label.add_theme_color_override("font_color", Constants.COLOR_TEXT)
	level_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(level_label)
	_level_label = level_label

	# ── 订单栏 ──
	#
	# 【位置为什么写死 y=88】原来它是「紧贴状态栏下方」由状态栏真实高度推出来的
	# （那时左上角有 7 行数据：钱/已接待/空桌/待收拾/在店/出餐口/后厨队列）。
	# 本轮玩家要求**把那 7 行全删掉**，左上角只剩「第 N 关 · 倒计时 · 钱」一行，
	# 高度固定了 —— 于是不需要再动态推算，也顺手删掉了那套
	# 「高度是 0 就 call_deferred 自己」的重试逻辑（它曾是个无限续期的崩溃源）。
	_order_panel = Control.new()
	_order_panel.set_script(ORDER_PANEL_SCRIPT)
	_order_panel.name = "OrderPanel"
	_order_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_order_panel.position = Vector2(20, 88)
	add_child(_order_panel)

	# ── 左下角：手上餐品 ──
	# 【为什么不给 PanelContainer 直接设锚点 + position】
	# 两者会打架：set_anchors_preset(BOTTOM_LEFT) 把锚点设成「贴底」，
	# 之后再改 position，会被 grow_vertical 解释成「从底部往上长」，
	# 结果整个面板落到 y=-113（屏幕上方外面），一声不响就没了。
	# 更稳的做法：用一个**显式坐标**的容器，每次 HUD 尺寸变化时重算它的位置。
	_hand_slot = Control.new()
	_hand_slot.name = "HandSlot"
	_hand_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hand_slot)

	# 尺寸变化时重算（含首次：HUD 拿到真实尺寸的那一刻）。
	# 必须先判断有没有连过：build() 可能被跑第二次（测试里反复建场景），
	# 重复 connect 会报 "Signal 'resized' is already connected" 并刷满日志。
	if not resized.is_connected(_place_bottom_left):
		resized.connect(_place_bottom_left)

	var hand_box := PanelContainer.new()
	hand_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hand_box.position = Vector2(20, 0)
	_hand_slot.add_child(hand_box)

	var hm := MarginContainer.new()
	hm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		hm.add_theme_constant_override("margin_" + side, 10)
	hand_box.add_child(hm)

	_hand_label = Label.new()
	_hand_label.text = "手上：空手"
	_hand_label.add_theme_font_size_override("font_size", 16)
	_hand_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hm.add_child(_hand_label)

	# 连 resized 只能覆盖「以后」的尺寸变化；build() 时 HUD 可能已经定好尺寸了，
	# 那时信号早发过了 —— 所以这里必须再显式摆一次，
	# 否则 HandSlot 会永远停在 (0,0)，也就是「设了监听但没人通知我」。
	_place_bottom_left()


## 订单栏宽度（与 order_panel.gd 的 TICKET_W 保持一致，供工具参考）
const ORDER_PANEL_W := 168.0


## 由 Level 每帧喂一次快照，只在变化时重绘文本
func apply(snapshot: Dictionary) -> void:
	if snapshot == _last_snapshot:
		return
	_last_snapshot = snapshot.duplicate()

	# 【左上角只剩这两样】第 N 关/倒计时/收入、以及顶中那三颗星。
	# 钱 / 已接待人数 / 空桌数 / 待收拾数 / 在店人数 / 出餐口 / 后厨队列
	# 这七项本轮按玩家要求从 HUD 上删掉了（快照里仍然算着，工具/测试在用）。
	_update_star_line(snapshot)
	_update_level_line(snapshot)

	var hand: Array = snapshot.get("hand", [])
	if hand.is_empty():
		_hand_label.text = "手上：空手"
	else:
		var parts: PackedStringArray = []
		for id in hand:
			parts.append(Config.item_name(String(id)))
		_hand_label.text = "手上：%s" % "、".join(parts)


## 把「手上」面板放到左下角（按 HUD 的真实高度算，不依赖锚点）
func _place_bottom_left() -> void:
	if _hand_slot == null:
		return
	var h := size.y
	if h <= 0.0:
		var vp := get_viewport()
		if vp != null:
			h = vp.get_visible_rect().size.y
	if h <= 0.0:
		h = 720.0
	_hand_slot.position = Vector2(0, h - 96.0)
	_hand_slot.size = Vector2(300, 84)


## 顶部目标栏：三颗星按「1★→3★」从左到右，星下面是该档的目标金额。
##
## ```text
##        本关目标
##      ★     ★     ★
##      60    70    80
##   第 1 关 · ⏱ 1:29 · 收入 45 元
## ```
##
## 【为什么星星要「点亮」而不是只写数字】玩家反馈「看不到每星目标」——
## 数字只能告诉他门槛是多少，点亮/空心的对比才能一眼看出「我已经拿到几颗、
## 下一颗还差多少」。`star_icon.gd` 的 lit 属性就是干这个的。
##
## 【为什么按 1★→3★ 排（玩家确认）】金额从左到右递增，读起来像进度条，
## 左边先拿到。原来的文字行是 3★→2★→1★（因为关心"离下一颗还差多少"），
## 换成图标后按升序更自然。
func _update_star_line(snapshot: Dictionary) -> void:
	if _star_icons.is_empty():
		return
	if not snapshot.has("star1") and not snapshot.has("star2") and not snapshot.has("star3"):
		for i in 3:
			_star_icons[i].set("lit", false)
			_star_labels[i].text = "—"
		return
	var money := int(snapshot.get("money", 0))
	var goals := [
		int(snapshot.get("star1", 0)),
		int(snapshot.get("star2", 0)),
		int(snapshot.get("star3", 0)),
	]
	for i in 3:
		_star_icons[i].set("lit", money >= goals[i])
		# 星下面写「当前/目标」，省得玩家自己减
		_star_labels[i].text = "%d/%d" % [mini(money, goals[i]), goals[i]]


## 把顶部目标栏摆到屏幕水平居中、贴顶（y=16）。
## 宽度要等容器布局算完才有值，所以放在 resized 回调 + build 末尾各调一次。
func _place_target_bar() -> void:
	if _target_bar == null or not is_instance_valid(_target_bar):
		return
	_target_bar.reset_size()
	_target_bar.position = Vector2((size.x - _target_bar.size.x) * 0.5, 16.0)


## 关卡那一行（在左上角，HUD 上唯一的一行）：第 N 关 · 倒计时 · 收入
##
## 【倒计时的颜色是有意义的】剩余不足 10 秒转成红色（COLOR_STRIKE）——
## 玩家不用去读数字，余光就能感觉到时间要到了。
##
## 【为什么不再显示「还差多少」】玩家要求去掉：三档目标金额已经在
## 顶部那三颗星下面了，再写一遍「还差 N 元」是重复信息。
## 【措辞】2026 玩家要求把「钱」改成「收入」。
func _update_level_line(snapshot: Dictionary) -> void:
	if _level_label == null:
		return
	var idx := int(snapshot.get("level", 1))
	var left := float(snapshot.get("time_left", 0.0))
	var money := int(snapshot.get("money", 0))
	var running := bool(snapshot.get("run_active", false))

	if not running:
		# 本局还没开始（标题画面期间）或已结束：不显示倒计时，免得看到 0:00 困惑
		_level_label.text = "第 %d 关　·　准备中" % idx
	else:
		_level_label.text = "第 %d 关　·　⏱ %s　·　收入 %d 元" % [idx, _fmt_time(left), money]
	_level_label.add_theme_color_override("font_color",
		Constants.COLOR_STRIKE if (running and left < 10.0) else Constants.COLOR_TEXT)


## 秒 → "m:ss"（关卡都在 2~3 分钟量级，不需要小时位）
static func _fmt_time(seconds: float) -> String:
	var total := maxi(0, int(ceil(seconds)))
	return "%d:%02d" % [total / 60, total % 60]


func refresh_orders(orders: Array) -> void:
	if _order_panel != null and _order_panel.has_method("refresh"):
		_order_panel.refresh(orders)
