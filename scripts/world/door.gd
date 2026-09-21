extends EntityBase
class_name Door
## 门口。
##
## 它不参与「服务员走过去做事」，只有两个用途：
##   1. 客人从这里出现（生成点）
##   2. 客人（吃完 / 气走）走到这里后消失
##
## 【为什么做成静态存取】
## 客人在生命周期里需要反复问「门在哪」，
## 而客人是运行时动态生成的、没有门节点的引用。
## 与其给每个客人塞一个引用，不如让门在 setup 时把坐标登记到静态变量上。
## 场景里只有一扇门，这个简化是安全的。

static var _home: Vector2 = Vector2(620, 600)
static var _spawn: Vector2 = Vector2(620, 600)

## 同组客人依次取生成点时用的序号（见 begin_group）。
static var _group_index: int = 0


static func home_point() -> Vector2:
	return _home


static func spawn_point() -> Vector2:
	return _spawn


## 一组客人开始入场：把「依次取点」的序号归零。
## 【为什么需要】同组客人改成**同一帧全部创建**（见 customer_manager），
## 如果都从同一个点出发，两个人的圆会完全重叠着走进店里，看着像一个人。
## 所以给他们沿门口横向错开一小段：一个人站门口中心，另一个偏 36px。
## 这只是**视觉**上的错开 —— 门口没有碰撞体、也不影响寻路，
## 每个人各走各的路径到自己的座位。
static func begin_group() -> void:
	_group_index = 0


## 取下一个组内生成点（沿 x 轴错开）
static func next_group_spawn(stagger: float) -> Vector2:
	var p := _spawn + Vector2(stagger * float(_group_index), 0.0)
	_group_index += 1
	return p


## 收尾：把序号复位，免得下一组接着上一组的偏移（单人也走这条）
static func end_group() -> void:
	_group_index = 0


var _walk: Vector2 = Vector2.ZERO


func setup(p_rect: Rect2, p_walk: Vector2, p_spawn: Vector2) -> void:
	kind = Constants.Kind.DOOR
	label = "门口"
	display_label = label
	position = p_rect.position
	_walk = p_walk
	_home = p_walk
	_spawn = p_spawn
	setup_shape(Rect2(Vector2.ZERO, p_rect.size), Rect2(), false)
	body_color = Constants.COLOR_DOOR
	label_color = Color(1, 1, 1, 0.8)


func click_rect() -> Rect2:
	return Rect2(Vector2.ZERO, rect.size)


func accepts_click() -> bool:
	return true


func walk_to() -> Vector2:
	return _walk


## 点门口就是「走过去」，没有任何附加动作
func interact(router: Node) -> int:
	router.walk_to_only(_walk)
	return RouterResult.ACCEPTED


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, rect.size)
	draw_rect(r, body_color, true)
	# 门框
	draw_rect(r, Color(0, 0, 0, 0.5), false, 3.0)
	draw_rect(Rect2(r.position + Vector2(6, 4), r.size - Vector2(12, 8)),
		Color(1, 1, 1, 0.12), true)
	if label != "":
		_draw_label(label, r)
	if hovered:
		draw_rect(r, Color(1, 1, 1, 0.5), false, 3.0)
