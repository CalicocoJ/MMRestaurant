extends Control
## 开始界面（标题画面）。
##
## 【它解决什么问题】
## 原来游戏一启动就直接进入餐厅，客人立刻开始生成 ——
## 玩家没有任何准备时间，也完全不知道规则。
## 现在启动先停在标题画面：**点了「开始游戏」才进入游戏**。
##
## 【屏幕上有什么】
##   上：游戏名「麦麦快餐店」（大号 + 金黄）
##   中：一句规则说明
##   下：「开始游戏」按钮（大按钮）
## 三者作为整体在屏幕正中间。
##
## 【为什么不是「PanelContainer 弹窗」那种样子】
## 后厨 / 饮料机 UI 是「面板 + 遮罩」，那是**工具窗口**的样子。
## 这里是标题画面，用户明确要求「画面留白更多」——
## 所以只有一层暗色遮罩 + 居中内容，没有面板边框。
##
## 【为什么用 CenterContainer 而不是自己算坐标】
## 与两个弹窗（popup_layout.gd）踩的是同一个坑：build() 在 _ready 里跑，
## 此时子节点最小尺寸还没算出来，任何「按尺寸居中」的手算都会把内容
## 算到屏幕外（弹窗当年就被扔到 x=-210，不报错、只是看不见）。
## CenterContainer 由引擎在布局阶段居中，不需要提前知道尺寸。
##
## 【它不自己管暂停】
## 「暂停」这件事的唯一所有者是 UiManager（见 ui_manager.gd 顶部说明）。
## 这里只负责显示 / 隐藏，并在按钮按下时发出 action_pressed。

## 玩家点了「开始游戏」。
## 用信号而不是直接调 UI 的方法：这个 Control 是 UiManager 建的，
## 让它回调父节点会形成双向依赖，测试里也不好单独搭起来。
signal action_pressed

var _roots: Array[Control] = []


func build() -> void:
	name = "StartScreen"

	# 全屏遮罩：盖住后面的餐厅画面，同时吃掉落在空白处的点击。
	#
	# 【为什么是 100% 纯黑（用户确认过）】
	# 第一版用 82%，结果背后的餐厅家具、服务员、甚至左上角的 HUD 都透出来，
	# 标题画面看起来像「游戏上面蒙了一层灰」，而不是一个开场。
	# 用户明确选择「一点餐厅都不露」—— 所以这里用完全不透明的纯黑。
	# HUD 另外由 UiManager.begin() 显式隐藏（见那里的说明）。
	#
	# 【为什么 mouse_filter = STOP 而不是 IGNORE】
	# 开始界面期间世界已暂停，但输入不该有机会漏到 ClickRouter 上；
	# 把整块屏幕吃掉，就物理上不可能误点到后面的桌子。
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0, 0, 0, 1.0)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	_roots.append(dim)

	# 居中容器：撑满整屏，把里面的竖列摆在正中间。
	var center := CenterContainer.new()
	center.name = "Center"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_roots.append(center)

	var col := VBoxContainer.new()
	col.name = "Column"
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 26)
	center.add_child(col)

	# ── 上：游戏名 ──
	# 【字号 56 是个折中】「麦麦快餐店」5 个字 × 56px ≈ 280px 宽，
	# 在 1280 宽的视口里只占五分之一，留白足够；
	# 再往上加（比如 80）会顶到屏幕上下边缘，标题画面反而局促。
	var title := Label.new()
	title.name = "Title"
	title.text = Constants.START_TITLE
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Constants.COLOR_START_TITLE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(title)

	# ── 中：一句规则说明 ──
	var subtitle := Label.new()
	subtitle.name = "Subtitle"
	subtitle.text = Constants.START_SUBTITLE
	subtitle.add_theme_font_size_override("font_size", 18)
	subtitle.add_theme_color_override("font_color", Constants.COLOR_TEXT_DIM)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(subtitle)

	# ── 下：开始游戏按钮 ──
	# 套一层 CenterContainer：VBoxContainer 会把子节点拉到整列宽度，
	# 不套这一层的话按钮会横跨整个标题宽度，看着不像按钮。
	var btn_center := CenterContainer.new()
	btn_center.name = "ButtonCenter"
	btn_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(btn_center)

	var start := Button.new()
	start.name = "StartButton"
	start.text = Constants.START_BUTTON
	start.custom_minimum_size = Vector2(240, 64)
	start.add_theme_font_size_override("font_size", 24)
	start.pressed.connect(_on_start_pressed)
	btn_center.add_child(start)


## 与 UiManager / HUD / 两个弹窗同一套尺寸约定：
## CanvasLayer 下的 Control 不会自动撑满视口，统一由 UiManager 显式赋尺寸。
func apply_size(s: Vector2) -> void:
	position = Vector2.ZERO
	size = s
	for n in _roots:
		if n == null or not is_instance_valid(n):
			continue
		# 全屏的那两层跟随；竖列自己由 CenterContainer 管，不用动。
		if n.name == "Dim" or n.name == "Center":
			n.position = Vector2.ZERO
			n.size = s


## 显示 / 隐藏。暂停由 UiManager 负责，这里只管自己可见不可见。
func begin(show_it: bool) -> void:
	visible = show_it


## 给 UiManager / 工具用：拿到那个大按钮。
## 【为什么用 find_child 而不是写死路径】
## 按钮上面套了一层 CenterContainer（为了不让它横跨整列宽度），
## 路径一旦多一层，写死的字符串就会在改名 / 调整层级时静默失效 ——
## 返回 null、按钮就按不动了，而且不报错。按名字递归找更稳。
func start_button() -> Button:
	return find_child("StartButton", true, false) as Button


func _on_start_pressed() -> void:
	action_pressed.emit()
