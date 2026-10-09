@tool
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
## 视觉矩形的**尺寸**（以节点原点为基准）。节点原点一律 = 家具的**左上角**。
##
## 【为什么尺寸要单独导出，而位置不用】
## 在旧的「按 data/layout.json 生成」模型里，rect 同时含位置和尺寸，两者都来自 JSON。
## 家具改成**编辑器摆放**以后，位置由你在编辑器里拖，只有尺寸还是配置项 ——
## 所以尺寸需要一个能被检查器序列化的字段（rect 是运行时拼出来的，编辑器改不了）。
## 这也是「你摆位置、我管几何」这条分工在数据上的落点。
@export var rect_size: Vector2 = Vector2(60, 60)

## 是否让代码**自动生成**碰撞盒。
##
## 【关掉它 = 碰撞盒完全归你管】你在这个节点下自己加 `CollisionShape2D`
## 子节点摆好，代码只负责**读**你摆的，不再生成也不再清理。
##
## 【为什么默认开启】它是**兜底**：你还没想好碰撞盒时也能跑起来，
## 不至于摆完家具发现「走不过去也点不到」。想精确控制时关掉即可。
##
## 【双保险】即使你忘了关这个开关，只要身上已经有碰撞形状，
## 代码也会当成「你已经摆了」而不重复生成 —— 避免两套碰撞盒叠在一起。
## 那种叠加的表现是「寻路莫名其妙绕远」，非常难查。
@export var auto_generate_shapes: bool = true
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
	rect_size = p_rect.size
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


# ── 编辑器摆放：自绑定 ─────────────────────────────────────────────
##
## 【这一节是「你摆、我绑」的落点】
## 家具不再由 Level 按 layout.json 生成，而是你在编辑器里摆好、挂在 World 下。
## 你摆出来的是**位置**（节点坐标）和**尺寸**（导出的 rect_size 等），
## 而「碰撞盒怎么算、站位点在哪、座位在哪」这些几何推导仍由脚本负责 ——
## 也就是这里。于是玩法逻辑完全不需要知道坐标是从 JSON 来的还是你拖出来的。

## 由子类覆盖：碰撞盒在**局部坐标**里应该是什么。
##
## 【为什么碰撞盒不让编辑器直接摆，而要脚本算】
## 碰撞盒和视觉矩形**故意不一样大**（桌子只盖下面 3/4、柜台只盖上面 72%，
## 见各自的注释）。这个差值是被验证过的几何：它同时决定「座位可达性」
## 「服务员不压桌面」「能站到柜台下缘取餐」。让编辑器直接摆碰撞盒，
## 就等于把这批已验证行为暴露给手滑 —— 而它们是本工程被咬过最多的地方。
## 所以：**尺寸跟着贴图自动走，碰撞盒按比例自动算**。要改比例再改脚本。
func collision_box_local() -> Rect2:
	return Rect2(Vector2.ZERO, rect_size)


## 按贴图尺寸自动填 rect_size。返回是否成功。
##
## 【为什么不用你在检查器里手填】贴图的尺寸**代码本来就能读出来**
## （AtlasTexture 的 Region 尺寸，或普通贴图的整图尺寸），
## 让你把同一个数字再抄进 rect_size 是纯重复劳动 —— 而且两份数字一定会漂移：
## 你换了贴图却忘了改 rect_size，表现就是「点击范围/碰撞盒和画面对不上」，
## 极难排查（画面看着好好的，就是点不到、或者服务员走过去碰不着）。
## 所以以**贴图为唯一真相来源**，每次自绑定都同步一次。
##
## 【什么时候会失败】还没加 Sprite2D、或它没设贴图。
## 这时保留你在检查器里填的值，不覆盖 —— 免得把手工调好的尺寸清成 0。
func fit_rect_size_to_sprite() -> bool:
	for c in get_children():
		if not (c is Sprite2D):
			continue
		var sp := c as Sprite2D
		if sp.texture == null:
			continue
		# 【用 get_size 而不是 get_width/get_height】
		# AtlasTexture.get_size() 返回的正是 Region 的尺寸；
		# 普通 Texture2D 返回整图尺寸。两种都对，于是这里不用分支。
		var s := sp.texture.get_size()
		if s.x > 0.0 and s.y > 0.0:
			rect_size = s
			return true
	return false


## 有贴图就别再画占位色块：自动把 `draw_placeholder` 关掉。
##
## 【解决什么问题】`draw_placeholder` 默认开着时，代码画的色块会和你的
## Sprite2D **重叠叠画**，画面发脏。而这个毛病**编辑器里看不出来** ——
## `_draw()` 在编辑器走参考线分支，只有 F5 之后才暴露。
## 于是很容易误判成「代码又生成了什么东西」。
##
## 【为什么自动而不是让你逐个关】椅子是每张桌两个、以后还会更多，
## "记得关"这件事必然会被忘。让**贴图存在**这个事实本身决定开关，
## 就不需要任何人记住任何事。
##
## 【为什么只认直接子节点的 Sprite2D】家具的贴图约定就是挂在节点自己下面一层
## （见 README 的结构图）。更深层的可能是别人的装饰，不该由它来决定开关。
func auto_disable_placeholder_if_sprite() -> void:
	# 【怎么判断"这个节点有没有 draw_placeholder"】
	# `get()` 对**不存在的属性**返回 null，而属性本身是 bool ——
	# 所以 `typeof(v) != TYPE_BOOL` 就等价于"这家具没有占位开关"（比如 Door）。
	# 不用 `"x" in self`：那种写法依赖 `in` 对 Object 的具体语义，不够直白。
	var v: Variant = get("draw_placeholder")
	if typeof(v) != TYPE_BOOL:
		return
	if not bool(v):
		return                      # 已经是关的，不用管
	for c in get_children():
		if c is Sprite2D and (c as Sprite2D).texture != null:
			set("draw_placeholder", false)
			queue_redraw()
			return


## 编辑器摆放后的自绑定入口。Level 在 _build_world() 里对 World 的每个子节点调用。
##
## 【为什么叫这个名字】`EDITOR_SETUP` 常量在 level.gd 里，两处必须一致。
## 拼错的后果是**静默**退回 JSON 生成（你摆的东西不生效、还不报错），
## 所以名字集中在一个常量里。
##
## 【为什么先清掉已有碰撞盒】这个函数可能被调用多次（重开一局会重跑搭建流程）。
## 不清就会越积越多：碰撞盒叠一层，寻路网格就多一层障碍，
## 表现是「隔着老远就绕路」这种莫名其妙的路径问题。
func setup_from_editor() -> void:
	auto_disable_placeholder_if_sprite()
	_apply_geometry()


## 统一处理「几何来自哪」：你自己摆了碰撞盒就用你的，没摆才自动生成。
##
## 【为什么要支持手动摆碰撞盒】
## 自动按比例算（桌子取下部 75% 之类）是**兜底**，不是**规定**：
## 它让你「还没想好碰撞盒」时也能跑起来。但一旦你想要精确控制
## （比如门只挡中间一截、柜台只挡台面），自动算就成了阻碍。
## 所以：**你摆了就听你的，没摆就用兜底**——这个判据是全自动的，
## 不需要你记得打开某个开关，也不会出现「忘了开开关所以没生效」。
func _apply_geometry() -> void:
	fit_rect_size_to_sprite()
	if auto_generate_shapes and not has_manual_shapes():
		_clear_body_shapes()
		setup_shape(Rect2(Vector2.ZERO, rect_size), collision_box_local())
		return
	# 碰撞盒归你管：不清理、不重建 —— 只把视觉矩形的尺寸同步一下
	# （点击范围 click_rect() 用 rect.size，所以它仍然跟着贴图走）。
	rect = Rect2(Vector2.ZERO, rect_size)
	queue_redraw()


## 自己身上有没有**手动摆放**的碰撞形状？
##
## 【判据是「直接的碰撞形状子节点」】物理体可以挂任意多个碰撞形状，
## 而且形状**必须**是直接子节点（Godot 的物理体只收集直属的 CollisionShape2D，
## 不会往更深层找）。
##
## 【为什么要把 Chair 排除掉】桌子下面挂着 Chair（椅子现在是 StaticBody2D），
## 那些 Chair 是**独立家具、有自己的碰撞盒**，不是桌子的一部分。
## 不排除的话，桌子一看到「有个 PhysicsBody2D 子节点」就以为你已经摆了
## 桌子的碰撞盒，于是不再生成 —— 桌面就完全不挡人了。
func has_manual_shapes() -> bool:
	for c in get_children():
		if c is CollisionShape2D or c is CollisionPolygon2D:
			return true
	return false


## 把你摆的碰撞形状读成一个矩形（**局部坐标**）。
##
## 【为什么要合并成一个矩形】`touch_box()` 只收一个矩形，用来算
## 「服务员碰到它了没有」。多个形状时取**外接矩形**：对绝大多数家具
## （一个碰撞盒）结果精确；对由多块拼成的家具，外接矩形偏保守
## （判定范围略大），比"漏判导致点不动"安全得多。
## 寻路那边不走这里 —— 它由 collision_shapes_global() 逐个形状取，保持精确。
func _manual_shapes() -> Rect2:
	var box := Rect2()
	var first := true
	for c in get_children():
		if not (c is CollisionShape2D):
			continue
		var cs: CollisionShape2D = c
		if not (cs.shape is RectangleShape2D):
			continue
		var r := cs.shape as RectangleShape2D
		var local := Rect2(cs.position - r.size * 0.5, r.size)
		box = local if first else box.merge(local)
		first = false
	return box if not first else Rect2(Vector2.ZERO, rect_size)


## 删掉自己身上已有的碰撞体（子节点），避免重复调用时叠加。
func _clear_body_shapes() -> void:
	for c in get_children():
		if c is CollisionShape2D:
			remove_child(c)
			c.queue_free()


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
	# 【编辑器里不画占位色块】本脚本是 @tool，_draw() 在编辑器视口也会跑。
	# 编辑器里只画「几何参考线」（见 _draw_gizmo），否则家具色块会盖在
	# 你自己贴的 Sprite2D 上、看不清在摆什么。
	if Engine.is_editor_hint():
		_draw_editor_guides()
		return
	var r := Rect2(Vector2.ZERO, rect.size)
	draw_rect(r, body_color * _tint, true)
	draw_rect(r, Color(0, 0, 0, 0.45), false, 2.0)
	if hovered:
		draw_rect(r, Color(1, 1, 1, 0.5), false, 3.0)
	if label != "":
		_draw_label(label, r)


# ── 编辑器可视化（@tool）────────────────────────────────────────────
##
## 【解决什么问题】`setup_from_editor()` 只在**运行时**跑，所以碰撞盒在编辑器里
## 看不见 —— 你摆家具时完全不知道自己摆出来的东西「能不能走过去」「点不点得到」，
## 只能每次按 F5 猜。这一节把那些几何直接画在编辑器视口里，做到所见即所得。
##
## 【颜色约定】
##   蓝框 = 碰撞盒（会挡住服务员）        绿十字 = 站位点（服务员该站哪）
##   黄框 = 点击范围（鼠标能点到的区域）  红圈   = 座位（客人坐哪）
##   红箭头 = 客人面朝方向（背离椅背）    青色   = 站位点相对家具原点的偏移量
##
## 【为什么用 _draw 而不是画 gizmo】2D 节点没有 3D 那种 gizmo API；
## 而 @tool + _draw 就能在编辑器视口渲染，且随节点变换自动跟随。

## 编辑器里画几何参考线。
func _draw_editor_guides() -> void:
	var col := collision_box_local()
	if col.size.x > 0.0 and col.size.y > 0.0:
		_draw_gizmo_box(col, Color(0.25, 0.6, 1.0, 0.18), Color(0.35, 0.7, 1.0, 0.95))
	# 点击范围（默认等于视觉矩形，门口有覆盖）
	var cr := click_rect()
	if cr.size.x > 0.0 and cr.size.y > 0.0:
		_draw_gizmo_box(cr, Color(1.0, 0.9, 0.2, 0.06), Color(1.0, 0.9, 0.2, 0.7))


## 画一个带边框的半透明矩形。
func _draw_gizmo_box(r: Rect2, fill: Color, line: Color, width: float = 1.5) -> void:
	draw_rect(r, fill, true)
	draw_rect(r, line, false, width)


## 画十字准星。
func _draw_gizmo_cross(p: Vector2, col: Color, size: float = 7.0) -> void:
	draw_line(p - Vector2(size, 0.0), p + Vector2(size, 0.0), col, 2.0)
	draw_line(p - Vector2(0.0, size), p + Vector2(0.0, size), col, 2.0)


## 画「站位点」参考：一个实心圆 + 从家具原点到它的连线。
##
## 【为什么连一条线】站位点存的是**相对家具原点的偏移**（`walk_offset`）。
## 只画一个点的话，你把它拖远之后不好判断它是相对谁的；
## 画一条连线，就能一眼看出「这个点是挂在这件家具上的、距离多少」。
func _draw_gizmo_walk(offset: Vector2) -> void:
	_draw_gizmo_cross(offset, Color(0.4, 1.0, 0.45, 0.95))
	draw_arc(offset, 5.0, 0.0, TAU, 16, Color(0.4, 1.0, 0.45, 0.95), 1.5)
	draw_line(Vector2.ZERO, offset, Color(0.4, 1.0, 0.45, 0.35), 1.0)


## 画「座位」参考：椅子占位框 + 客人身体位置 + 面朝方向箭头。
##
## 【为什么要画三样而不是一个点】座位几何里「椅子本体」和「客人身体」
## 是两个不同的位置（差半个靠背），而且客人还有朝向。
## 只画一个点的话，你没法判断「客人会不会看起来浮在椅子前缘」。
func _draw_gizmo_seat(body_pos: Vector2, chair_rect: Rect2, back_dir: Vector2) -> void:
	_draw_gizmo_box(chair_rect, Color(1.0, 0.35, 0.35, 0.15), Color(1.0, 0.45, 0.45, 0.9))
	draw_circle(body_pos, 4.0, Color(1.0, 0.4, 0.4, 0.95))
	# 面朝方向 = 背离椅背的方向
	if back_dir != Vector2.ZERO:
		draw_line(body_pos, body_pos - back_dir * 14.0,
			Color(1.0, 0.8, 0.3, 0.95), 2.0)


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
