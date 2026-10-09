@tool
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


## 站位点 / 客人出生点相对节点原点（门框左上角）的偏移。
##
## 【为什么偏移而不是世界坐标】门可以被你拖到任意位置。存世界坐标的话，
## 一拖动就失效 —— 而且**不报错**，只是客人从老地方凭空冒出来。
@export var walk_offset: Vector2 = Vector2(60, 86)
@export var spawn_offset: Vector2 = Vector2(60, 104)

## 是否用代码画**占位美术**（门框色块）。
##
## 【默认 false：贴图优先】理由同 table.gd / chair.gd 的同名属性 ——
## 门上贴了贴图之后再画色块，色块会盖住贴图；而且 `_draw()` 在编辑器走
## 参考线分支，**编辑器里看不出来**，只有 F5 才暴露。
## 另外挂了 Sprite2D 的门会被自动关掉，见
## `EntityBase.auto_disable_placeholder_if_sprite()`。
##
## 【注意它管不到什么】「门口」二字**不受这个开关控制**（标签永远画）。
## 不想要那两个字，把 `label` / `display_label` 清空即可 —— 那是场景里的值。
@export var draw_placeholder: bool = false

var _walk: Vector2 = Vector2.ZERO


func setup(p_rect: Rect2, p_walk: Vector2, p_spawn: Vector2) -> void:
	kind = Constants.Kind.DOOR
	# 【不写死标签】门是纯装饰 + 位置基准，要不要「门口」二字由场景决定。
	# 写死的话关都关不掉（代码每局都会把它设回来）。
	position = p_rect.position
	_walk = p_walk
	_home = p_walk
	_spawn = p_spawn
	setup_shape(Rect2(Vector2.ZERO, p_rect.size), Rect2(), false)
	body_color = Constants.COLOR_DOOR
	label_color = Color(1, 1, 1, 0.8)


## 编辑器摆放后的自绑定。
##
## 【这个函数是必须的，不是可选优化】
## 客人的生成点 / 回家点是 **static 变量**（`_home` / `_spawn`），
## 因为客人是运行时动态创建的、手里没有门的引用（见文件头的说明）。
## 而 static 变量的初值是硬编码的 `(620, 600)` —— 一旦门被拖走却没人调 setup()，
## 客人就会从屏幕上的老地方凭空出现。**没有任何报错**，只是位置不对。
## 所以这里的赋值是「让门和客人对上号」的唯一途径。
func setup_from_editor() -> void:
	kind = Constants.Kind.DOOR
	auto_disable_placeholder_if_sprite()
	_clear_body_shapes()
	fit_rect_size_to_sprite()
	# 门口是纯装饰，不生成碰撞体（make_body = false 是**故意的**：
	# 门要允许服务员和客人自由穿过，挡路会把「客人进场」这条链路弄坏）
	setup_shape(Rect2(Vector2.ZERO, rect_size), Rect2(), false)
	body_color = Constants.COLOR_DOOR
	label_color = Color(1, 1, 1, 0.8)
	_walk = global_position + walk_offset
	_home = _walk
	_spawn = global_position + spawn_offset


## 门口是否可以点击。
##
## 【默认关闭】点门口原本只是「服务员走过去」，没有任何附加动作 ——
## 而这个功能是**旧布局的遗留**：当初门口在屏幕**底部中间**，
## 「走到门口」是个合理的导航目标（去接新来的客人）。
## 现在门口通常在墙角/墙边，这个点击就变成纯粹的副作用：
## **它会把墙角那片区域的点击吃掉**，玩家点那里想走过去，结果触发一个没用的动作。
##
## 【为什么关闭点击要同时改两处】`ClickRouter._object_at()` 的逻辑是
## 「能接受点击的直接返回，否则记下来当 fallback」——
## 也就是说**只把 accepts_click 改成 false 是不够的**，
## 它仍然会作为 fallback 被返回，点击照样触发。
## 所以必须连 `click_rect()` 一起失效，让 hit_test 根本命中不了，
## 点击就会**穿透到地板**、变成正常的「走过去」。
##
## 【想要回来的时候】在检查器里勾上它即可，不用改代码。
@export var clickable: bool = false


func click_rect() -> Rect2:
	# 尺寸为 0 = 不可点击（WorldObject.hit_test 会直接返回 false）
	if not clickable:
		return Rect2()
	return Rect2(Vector2.ZERO, rect.size)


func accepts_click() -> bool:
	return clickable


func walk_to() -> Vector2:
	return _walk


## 点门口就是「走过去」，没有任何附加动作
func interact(router: Node) -> int:
	router.walk_to_only(_walk)
	return RouterResult.ACCEPTED


func _draw() -> void:
	# 【编辑器里只画参考线】门口有两个点：站位点（绿）和客人出生点（橙）。
	# 出生点是**关键**：它错了客人就会从屏幕上的怪地方冒出来，且不报错。
	# 【为什么不受 draw_placeholder 影响】参考线是"摆场景时的尺子"，
	# 和运行时要不要画占位美术是两件事 —— 关掉占位不该把尺子也收走。
	if Engine.is_editor_hint():
		_draw_gizmo_walk(walk_offset)
		_draw_gizmo_cross(spawn_offset, Color(1.0, 0.6, 0.3, 0.95))
		draw_arc(spawn_offset, 5.0, 0.0, TAU, 16, Color(1.0, 0.6, 0.3, 0.95), 1.5)
		return

	var r := Rect2(Vector2.ZERO, rect.size)
	# 占位色块：门上已经贴了贴图时不该再画（否则盖住贴图）。
	# 默认关、挂了 Sprite2D 会自动关，见
	# `EntityBase.auto_disable_placeholder_if_sprite()`。
	if draw_placeholder:
		draw_rect(r, body_color, true)
		draw_rect(r, Color(0, 0, 0, 0.5), false, 3.0)          # 门框
		draw_rect(Rect2(r.position + Vector2(6, 4), r.size - Vector2(12, 8)),
			Color(1, 1, 1, 0.12), true)
	if hovered:
		draw_rect(r, Color(1, 1, 1, 0.5), false, 3.0)
	# 【标签永远画，不看 draw_placeholder】门是要被点的地方，
	# 有个「门口」二字能让人一眼知道那是门、并且知道能点。
	# 不想要的话把 Door 的 `label` / `display_label` 清空即可（那是场景里的值）。
	if label != "":
		_draw_label(label, r)
