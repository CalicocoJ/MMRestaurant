extends Control
## 后厨弹窗里的「队列小方块」：一份已点的菜。
##
## 【交互：只响应鼠标右键】
## 左键点它**什么也不做**（加菜是点上面的菜品方块）；
## 右键点它就删掉**这一份**。删除靠发 `remove_requested` 信号，
## 由 `kitchen_popup.gd` 统一处理（它才知道队列的数据结构）。
##
## 【为什么单独一个文件，而不是在 popup 里内联脚本】
## 这个控件需要自己处理鼠标输入（`_gui_input`），必须有脚本；
## 而之前试过用 `GDScript.new()` 内联源码，可读性差、还撞过类型推断的坑。
## 单独一个 20 行的小文件最清楚。
##
## 【为什么不再做悬停 ✕】曾用「悬停浮现红 ✕」来删，结果两轮都出问题：
##   ① ✕ 越出小方块被邻居盖住；
##   ② 用 `visible` 切换浮现 → ✕ 就在鼠标下方，形成「出现→鼠标离开→隐藏→
##      鼠标回来」的每帧死循环 → 红叉闪、输入延迟，最后甚至点不动。
## 右键删除没有这些问题：不需要任何额外控件，也不改变命中结果。

## 玩家右键点了这个方块 → 请求删掉它
signal remove_requested

## 这块小方块的边长（贴图尺寸，由父节点设）
var box: Vector2 = Vector2(46, 46):
	set(v):
		box = v
		custom_minimum_size = v


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = "右键可删除该餐品"


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
			remove_requested.emit()
			accept_event()
