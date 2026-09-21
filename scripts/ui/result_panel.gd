extends Control
## 结算界面（本局结束）。
##
## 【屏幕上有什么】（用户指定，刻意极简）
##   大标题：「通关成功」/「通关失败」
##   营业额：这一关赚了多少（每关营收从 0 重新算）
##   接待客人总数
##   一个按钮：达标 →「下一关」；未达标 →「重试本关」
##
## 【为什么不做星级、不做关卡选择】用户明确要求第一版只做这四样，
## 星级等数值稳定后再加（它是纯展示层，后加成本很低）。
##
## 【为什么标题只有成功/失败两种，没有「全部通关」】第 5 关过了之后
## 没有第 6 关，按钮会显示「重玩第 1 关」并回到第 1 关 —— 比停在一个
## 点不动的界面上好。用户没指定这一点，这里取最合理的方案。

## 玩家按下了那个按钮。
signal action_pressed

const STAR_ICON_SCRIPT := preload("res://scripts/ui/star_icon.gd")

## 星级一共几档（1~3 星）
const MAX_STARS := 3

const TITLE_WIN := "通关成功"
const TITLE_LOSE := "通关失败"
## 第 5 关过了之后没有下一关，按钮改成这个（见类注释）
const BUTTON_NEXT := "下一关"
const BUTTON_RETRY := "重试本关"
const BUTTON_REPLAY := "重玩第 1 关"

var _title: Label = null
var _stars_box: HBoxContainer = null
var _stars: Array[Control] = []
var _stat_revenue: Label = null
var _stat_served: Label = null
var _button: Button = null
var _roots: Array[Control] = []


func build() -> void:
	name = "ResultPanel"

	# 全屏遮罩：盖住世界与 HUD，并吃掉落在空白处的点击
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.name = "Dim"
	# 结算界面用**纯黑不透明**，和开始界面一致 ——
	# 结算时不该还能看见背后餐厅在动（世界此时已冻结）
	dim.color = Color(0, 0, 0, 1.0)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	_roots.append(dim)

	var center := CenterContainer.new()
	center.name = "Center"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_roots.append(center)

	var col := VBoxContainer.new()
	col.name = "Column"
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 22)
	center.add_child(col)

	_title = Label.new()
	# 【节点名唯一，不是 Title / Revenue / Served】两个作用：
	#   ① 测试可以直接 find_child 定位，不用把「Center/Column/...」这条路径
	#      抄进断言（路径一改断言就静默失效、返回 null）；
	#   ② 排查时看节点树就能知道哪个控件是干什么的（Title 这种名字满树都是）。
	_title.name = "ResultTitle"
	_title.text = TITLE_WIN
	_title.add_theme_font_size_override("font_size", 48)
	_title.add_theme_color_override("font_color", Constants.COLOR_MONEY)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_title)

	# ── 星星（在「通关成功」四个字下面）──
	# 居中摆 3 颗；已获得的画成金黄实心，未获得的只有白色描边。
	# 【失败的局整行隐藏】0 星时画 3 颗空心星没有意义（已与玩家确认）。
	var star_center := CenterContainer.new()
	star_center.name = "StarCenter"
	star_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(star_center)

	_stars_box = HBoxContainer.new()
	_stars_box.name = "Stars"
	_stars_box.add_theme_constant_override("separation", 8)
	_stars_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	star_center.add_child(_stars_box)

	_stars.clear()
	for i in MAX_STARS:
		var s := Control.new()
		s.set_script(STAR_ICON_SCRIPT)
		s.name = "Star%d" % (i + 1)
		_stars_box.add_child(s)
		_stars.append(s)

	_stat_revenue = _make_stat_label("ResultRevenue")
	col.add_child(_stat_revenue)
	_stat_served = _make_stat_label("ResultServed")
	col.add_child(_stat_served)

	var btn_center := CenterContainer.new()
	btn_center.name = "ButtonCenter"
	btn_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(btn_center)

	_button = Button.new()
	_button.name = "ActionButton"
	_button.text = BUTTON_NEXT
	_button.custom_minimum_size = Vector2(240, 64)
	_button.add_theme_font_size_override("font_size", 24)
	_button.pressed.connect(_on_action_pressed)
	btn_center.add_child(_button)


func _make_stat_label(nm: String) -> Label:
	var l := Label.new()
	l.name = nm
	l.add_theme_font_size_override("font_size", 20)
	l.add_theme_color_override("font_color", Constants.COLOR_TEXT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## 与 UiManager / HUD / 开始界面同一套尺寸约定（CanvasLayer 下的 Control
## 不会自动撑满视口，统一由 UiManager 显式赋尺寸）
func apply_size(s: Vector2) -> void:
	position = Vector2.ZERO
	size = s
	for n in _roots:
		if n == null or not is_instance_valid(n):
			continue
		if n.name == "Dim" or n.name == "Center":
			n.position = Vector2.ZERO
			n.size = s


## 用本局结果填充界面。由 UiManager.show_result() 调用。
##
## 【参数为什么传进来而不是自己去读 Game】结算界面只负责「显示」；
## 让它去读 Game 会让「什么时候读、读的是不是结算那一刻的值」变得含糊
## （时间到之后 money 还有可能因为结账再变一次）。
## 由调用方在结算那一刻把数字取好传进来，语义唯一、也好测。
func fill(level_index: int, level_name: String, revenue: int, target: int,
		served: int, passed: bool, has_next: bool, stars: int = 0) -> void:
	if _title != null:
		_title.text = TITLE_WIN if passed else TITLE_LOSE
		_title.add_theme_color_override("font_color",
			Constants.COLOR_MONEY if passed else Constants.COLOR_STRIKE)
	# 星星：前 stars 颗亮、其余暗；0 星（未达标）整行隐藏。
	# 【用 obj.set() 而不是 obj.lit = ...】_stars 的元素声明成 Control，
	# 静态类型上没有 lit 属性；set() 是按名字动态赋值，正是这里要的。
	if _stars_box != null:
		_stars_box.visible = stars > 0
		for i in _stars.size():
			if _stars[i] != null and is_instance_valid(_stars[i]):
				_stars[i].set("lit", i < stars)
	if _stat_revenue != null:
		_stat_revenue.text = "营业额：%d 元（目标 %d 元）" % [revenue, target]
	if _stat_served != null:
		_stat_served.text = "接待客人：%d 位" % served
	if _button != null:
		if not passed:
			_button.text = BUTTON_RETRY
		elif has_next:
			_button.text = BUTTON_NEXT
		else:
			_button.text = BUTTON_REPLAY


## 界面显示时的副标题（关卡名），放在标题下面一行
func set_level_label(text: String) -> void:
	if _title != null:
		_title.tooltip_text = text


func action_button() -> Button:
	return _button


## 当前按钮上打算做什么：next / retry / replay
func action_kind() -> String:
	if _button == null:
		return ""
	match _button.text:
		BUTTON_NEXT: return "next"
		BUTTON_RETRY: return "retry"
		BUTTON_REPLAY: return "replay"
	return ""


func _on_action_pressed() -> void:
	action_pressed.emit()
