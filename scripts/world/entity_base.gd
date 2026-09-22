extends WorldObject
class_name EntityBase
## 场景物件的通用实现：静态碰撞体、占位矩形、悬停高亮、标签。
##
## 家具的碰撞盒决定「服务员能走到哪」。
## 每个子类的 walk_to() 都必须返回碰撞盒**外面**的一点 ——
## 让服务员走到家具中心是最经典的 bug 来源：他会被自己的碰撞体挡在
## 外面几十像素处，指令永远走不完，看起来就是「点了鼠标没反应」。
## 这也正是 ClickRouter 里那个 stuck_timeout 保底存在的原因。

var rect: Rect2 = Rect2()
var label: String = ""
var body_color: Color = Color.WHITE
var label_color: Color = Constants.COLOR_TEXT_DIM

var hovered: bool = false
var _tint: Color = Color.WHITE
var _font: Font = null


func _ready() -> void:
	# 家具画在人物下面。
	#
	# 【为什么需要显式设 z_index】
	# 绘制顺序默认按场景树顺序：世界（家具）先加、演员后加，
	# 所以演员本来该在上面。但家具的 **子节点**（每把椅子的碰撞体、
	# 以及桌子自己画的椅子）会插在中间，造成「站在桌子下方时整个人被桌子盖住」。
	# 给家具一个统一的负 z，人物保持 0，层次就固定下来了，
	# 不依赖谁先 add_child。
	z_index = -10


## 由子类调用：设置视觉矩形（局部坐标）与碰撞矩形。
## make_body = false 时不生成碰撞体（门口是纯装饰，不挡人）。
func setup_shape(p_rect: Rect2, p_collision: Rect2 = Rect2(), make_body: bool = true) -> void:
	rect = p_rect
	if make_body and p_collision.size != Vector2.ZERO:
		collision_layer = 1 << 0   # world
		collision_mask = 1 << 1    # 挡住服务员（服务员在 layer 2）
		var cs := CollisionShape2D.new()
		var shape := RectangleShape2D.new()
		shape.size = p_collision.size
		cs.shape = shape
		cs.position = p_collision.position + p_collision.size * 0.5
		add_child(cs)
	queue_redraw()


func click_rect() -> Rect2:
	return rect


func walk_to() -> Vector2:
	return global_position + rect.size * 0.5


# ── 「碰到就触发」：用碰撞盒，而不是某个固定站位 ───────────────────

## 碰撞盒（局部坐标）。没有碰撞体时退回视觉矩形。
func collision_rect() -> Rect2:
	for c in get_children():
		if c is CollisionShape2D:
			var cs: CollisionShape2D = c
			if cs.shape is RectangleShape2D:
				var r := cs.shape as RectangleShape2D
				return Rect2(cs.position - r.size * 0.5, r.size)
	return rect


## 所有碰撞形状的世界矩形（桌子自己 + 每把椅子各一个）。
##
## 【为什么寻路要用这个，而不是 nav_rect_global 那个合并矩形】
## 曾经把「桌子 + 所有椅子」合并成一个大矩形喂给寻路，想借此消灭
## 桌椅上之间那条 8px 窄缝。缝确实没了，但**座位本身也一起被封死了**：
## 合并矩形把椅子那块盖住，于是「走到客人身边」这个目标点落在障碍内部，
## A* 只能给出一条斜线 —— 实测就是玩家看到的「一靠近桌椅就出斜线」。
##
## 正确做法：桌子、左椅、右椅**各自**是障碍。于是
##   - 椅子下方是开放的，座位可达；
##   - 桌椅上之间那 8px 缝被「外扩 ≥ 服务员半径」自动吃掉（本来就过不去）。
## 两个问题一起解决，而且不需要任何特殊处理。
func collision_shapes_global() -> Array:
	var out: Array = []
	for c in get_children():
		if c is CollisionShape2D:
			var cs: CollisionShape2D = c
			if cs.shape is RectangleShape2D:
				var r := cs.shape as RectangleShape2D
				out.append(Rect2(to_global(cs.position - r.size * 0.5), r.size))
	if out.is_empty():
		var fallback := collision_rect_global()
		if fallback.size.x > 0.0:
			out.append(fallback)
	return out


func collision_rect_global() -> Rect2:
	var r := collision_rect()
	return Rect2(to_global(r.position), r.size)


## 寻路用的外接矩形：把**自己 + 所有附属碰撞盒（椅子）**并成一个大矩形。
##
## 【为什么寻路要用它，而不是上面那个精确碰撞盒】
## 桌子的碰撞盒和左右椅子的碰撞盒之间，因为布局取整会留下 8px 左右的缝。
## 服务员的圆心要离障碍 ≥16px 才能通过，8px 的缝物理上过不去；
## 但网格是 20px 一格，这点缝在离散化之后可能被当成「一格可通行」，
## A* 于是给出一条**沿着缝走**的路径，服务员按它走必然撞在椅子边上卡住。
##
## 把桌子连同椅子当成**一件家具**喂给寻路，缝就根本不存在了。
##
## 【为什么不干脆把碰撞盒也合成一个】
## 那样服务员会在更外面就停下（大盒比桌面宽得多），贴近感变差。
## 分开的好处：走路判定仍然精确（该贴多近还多近），
## 只有寻路把它看成一整块 —— 代价仅是路径离家具远一点，反而更自然。
##
## 【换美术时的影响】
## 美术（_draw）和碰撞盒是两件事，换素材不受影响。
## 但要记得：**改了碰撞盒尺寸，这个外接矩形会自动跟着变**，
## 不需要再去维护「椅子在 -28、桌子宽 80」这类数字。
func nav_rect_global() -> Rect2:
	var box := collision_rect()
	for c in get_children():
		if c is CollisionShape2D:
			var cs: CollisionShape2D = c
			if cs.shape is RectangleShape2D:
				var r := cs.shape as RectangleShape2D
				box = box.merge(Rect2(cs.position - r.size * 0.5, r.size))
	return Rect2(to_global(box.position), box.size)


## 离 from 最近的可碰点。
## 从右侧点桌子就该从右边贴上，从下方点就从下面贴上 ——
## 这就是「不再绕到固定点」的关键。
##
## 【用的是 touch_box 而不是碰撞盒】见 touch_box 的说明：
## 可碰区域可能比碰撞盒大（桌子就是这样），两者故意分开。
func touch_point(from: Vector2) -> Vector2:
	return EntityBase.nearest_point_on_rect(touch_box(), from)


## 我的身体（半径 radius 的圆）现在碰到这个家具了吗
func touches_from(from: Vector2, radius: float) -> bool:
	# 圆心到矩形的距离 ≤ 身体半径 → 贴上了
	return EntityBase.nearest_point_on_rect(touch_box(), from).distance_to(from) <= radius + 1.0


## 可碰判定用的矩形。
## 家具默认用碰撞盒；桌子覆盖成「整个桌面」（见 Table.touch_box）。
func touch_box() -> Rect2:
	return collision_rect_global()


## 点到矩形上离它最近的那个点（点在矩形内时返回它自己）。
## 抽成静态函数是因为桌子 / 客人 / 服务员都要用同一套几何，
## 各写一遍迟早会出现「三处算的边不一样」这种怪 bug。
static func nearest_point_on_rect(box: Rect2, p: Vector2) -> Vector2:
	return Vector2(
		clampf(p.x, box.position.x, box.end.x),
		clampf(p.y, box.position.y, box.end.y))


# ── 悬停 ───────────────────────────────────────────────────────────

## 由 Level 每帧喂鼠标位置（家具只有 7 件，直接遍历比连信号简单）
func update_hover(world_point: Vector2, enabled: bool) -> void:
	var h := enabled and hit_test(world_point)
	if h != hovered:
		hovered = h
		queue_redraw()


# ── 画 ─────────────────────────────────────────────────────────────

func body_tint() -> Color:
	return _tint


func set_tint(c: Color) -> void:
	_tint = c
	queue_redraw()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, rect.size)
	draw_rect(r, body_color * _tint, true)
	draw_rect(r, Color(0, 0, 0, 0.45), false, 2.0)
	if hovered:
		draw_rect(r, Color(1, 1, 1, 0.5), false, 3.0)
	if label != "":
		_draw_label(label, r)


## 画家具标签。
##
## 【为什么贴底而不是居中】
## 居中会和家具自己画的图案撞上 —— 饮料机的杯子和出水口就在中间，
## 标签压上去以后两者叠在一起（放大截图确认过）。
## 改成贴底（留 4px），中间那块完整留给图案，以后加图标也不会再打架。
##
## 【font_size 可传】默认 14。点餐铃那种 64×48 的小方块塞不下 14px，
## 需要 11px；加这个参数比在外面重写一遍绘制逻辑干净。
func _draw_label(text: String, r: Rect2, color: Color = Color.TRANSPARENT,
		font_size: int = 14) -> void:
	var f := _get_font()
	if f == null:
		return
	var fs := font_size
	var size := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var c := label_color if color == Color.TRANSPARENT else color
	var at := Vector2(
		r.position.x + (r.size.x - size.x) * 0.5,
		r.position.y + r.size.y - 4.0)
	draw_string_outline(f, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4,
		Color(0, 0, 0, 0.65))
	draw_string(f, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, c)


func _get_font() -> Font:
	if _font == null:
		_font = UiFont.get_font()
	return _font


## 布局工具：JSON 里的 [x, y, w, h] → Rect2
static func from_array(a: Variant, fallback: Rect2 = Rect2()) -> Rect2:
	if typeof(a) != TYPE_ARRAY or (a as Array).size() < 4:
		return fallback
	var arr: Array = a
	return Rect2(float(arr[0]), float(arr[1]), float(arr[2]), float(arr[3]))


static func point_from_array(a: Variant, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	if typeof(a) != TYPE_ARRAY or (a as Array).size() < 2:
		return fallback
	var arr: Array = a
	return Vector2(float(arr[0]), float(arr[1]))
