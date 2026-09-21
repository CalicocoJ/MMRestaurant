extends EntityBase
## 饮料机（文档第五节第 4 步、第七节的取饮品）。
##
## 点击时检查手上为空 → 走过去 → 到达时再检查手上为空 → 暂停 → 弹饮料机 UI。
## 手上已有餐品则原地飘字「手上已有餐品」。
##
## 【为什么饮品也要走一趟】
## 文档把「接单/上菜」都设计成跑腿，饮品如果凭空到手会破坏这个手感；
## 而且出了 UI 以后 PlayerHand = 可乐，再走到客人身边上菜，
## 与汉堡走完全相同的上菜流程，delivered 数组统一处理。
##
## 【外观】
## 现在只画一个纯色矩形 + 贴底的「饮料机」文字（EntityBase._draw_label 负责）。
## 之前画过「出水口 + 杯子」的占位图案，会和标签叠在一起，
## 已与用户确认直接去掉 —— 等有真实美术素材时换成 Sprite2D 即可。

var rect_size: Vector2 = Vector2(110, 100)
var _walk: Vector2 = Vector2.ZERO


func setup(p_rect: Rect2, p_walk: Vector2) -> void:
	kind = Constants.Kind.DRINK
	label = "饮料机"
	display_label = label
	position = p_rect.position
	rect_size = p_rect.size
	var col := Rect2(Vector2.ZERO, Vector2(p_rect.size.x, p_rect.size.y * 0.75))
	setup_shape(Rect2(Vector2.ZERO, rect_size), col)
	body_color = Constants.COLOR_DRINK_MACHINE
	_walk = p_walk


func walk_to() -> Vector2:
	return _walk


func accepts_click() -> bool:
	return true


func interact(router: Node) -> int:
	# 手上满了：**不弹窗**，直接飘字（已与用户确认）
	if Game.hand_is_full():
		router.say(Constants.MSG_HANDS_FULL)
		return RouterResult.NO_ACTION
	router.go_then(_walk, Callable(self, "_do_open"), "去饮料机")
	return RouterResult.ACCEPTED


## 到达时再检查手上还有空位
func _do_open(router: Node) -> bool:
	if Game.hand_is_full():
		router.say(Constants.MSG_HANDS_FULL)
		return false
	router.ui.open_drink_machine()
	return true
