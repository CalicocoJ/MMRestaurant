extends CharacterBody2D
## 服务员。
##
## 【职责】
## 只会做一件事：朝一个目标点走；到了以后执行一个「到达动作」（Callable）。
## 「走」由本脚本管，「到了以后干什么」由 ClickRouter 决定。
##
## 【为什么不用 NavigationAgent2D】
## 场景里只有 7 件家具、都摆在开阔处，直线 + 贴边滑动就够了。
## 但「够用」不等于「不会卡」：家具的碰撞盒如果正好盖住目标点，
## 服务员会顶着它原地抖到天荒地老 —— 表现为「点了鼠标没反应」。
## 所以这里有两道保险：
##   1. 每个可交互物件自己声明 walk_to()（玩家该站在哪），而不是让玩家走到物件中心；
##   2. 卡住超过 stuck_timeout 秒就主动放弃并飘字，绝不会永久僵死。

signal arrived
signal command_started(desc: String)
signal command_cancelled(reason: String)

const RADIUS := 16.0

## 到达判定半径。
##
## 【为什么不能用 speed * delta 当到达阈值】
## 最初写的是「这一帧的步长够大就算到了」（当年 speed=260，260 * 1/60 ≈ 4.3px；
## 现在 speed=290 → 约 4.8px）。
## 但 move_and_slide 会把圆形碰撞体从家具盒子里**推出来**：
## 目标点即使算得再准，人也可能被顶到 4.7px 外，
## 于是 dist(4.74) > stop_at(4.33) 永远不成立 ——
## 服务员顶着桌子原地抖到 stuck 超时，玩家看到的就是「点了没反应」。
## 所以到达判定必须用**固定半径**（且明显大于单帧位移与挤出偏移）；
## 真正到不了的情况由 stuck 看门狗兜底。
##
## 【为什么现在是 6 而不是 10】
## 有了寻路以后，这个半径还要兼职判断「到没到当前拐点」。
## 10px 太粗：拐点间距小时会被一路误判成「已到达」，于是整条路径被跳过、
## 退回直线走，等于寻路白做。6px 既能容忍挤出偏移，又不会误判拐点。
const ARRIVE_EPS := 6.0

## 「已经站在这个拐点上」的判定（比 ARRIVE_EPS 严格得多）。
## 只有到这么近才把位置对齐到拐点；6px 那一档只算「走过」，不做位移 ——
## 见 `_next_step()` 里关于「吸附会把连点变成左右横跳」的说明。
const SNAP_EPS := 1.5

## 走路速度（px/s）。**可以直接在检查器里调**。
##
## 【两种来源，检查器优先】
##   检查器里留 `0`  → 用 `data/config.json` 的 `waiter_speed`（默认 290）
##   检查器里填正数  → 以检查器为准，**config.json 那份被忽略**
## 于是「只调数值不碰代码」这条既有约定不变（改 config.json 仍然生效），
## 同时你选中 `Waiter` 节点就能在检查器里试手感，不用重启、不用改 JSON。
##
## 【为什么用 0 当哨兵，而不是默认就填 290】填死 290 的话，改 config.json
## 就再也不会生效了 —— 而那边才是「数值的唯一出处」这个约定的落点。
## 0 是安全的哨兵：速度不可能为 0（那样服务员永远走不到目的地）。
##
## ⚠️ 这个值在 `_ready()` 里被解析一次；**想在运行中改**得用
## `waiter.speed = xxx`（比如调试时热改），改检查器只对**下一次 F5** 生效。
@export var speed: float = 0.0
var stuck_timeout: float = 2.0

## 当前指令
var _target := Vector2.ZERO
## 当前指令的描述（给调试记录用）
var _desc := ""
var _on_arrive: Callable = Callable()
var _active := false
## 「碰到它就算到」的目标物件（null = 用坐标判定，见 ARRIVE_EPS）
var _touch_target: Node = null

## 本次指令的落脚点。
##
## 【为什么要有它，而不是每帧重算「最近可碰点」】
## 每帧重算会让寻路终点一直漂移（A* 每帧算出不同路径），
## 更糟的是「可碰点」贴在障碍表面，A* 把终点吸附到空格子后，
## 最后一个拐点可能仍在家具里 —— 服务员永远走不到，卡在最后一步。
## 所以在**指令开始时**定一次落脚点，整条指令都用它；
## 它由 touch_point 往自己这边让出服务员半径得到，保证落在空地上。
var _goal_pt: Vector2 = Vector2.ZERO
## 寻路：待走的拐点列表（空 = 直接朝目标走）
var _waypoints: Array = []
## 已经在这条指令上重算过几次路径（防止「绕不出去 → 无限重算」）
var _repath_count: int = 0
const MAX_REPATH := 4

## 「没走出去」判定：本帧真实位移 < 期望步长 × 这个比例 → 认为撞住了。
##
## 【为什么这个信号必须有，而不是只靠 _stuck_clock】
## 原来只有一条判据：位移 < 1.5px 才算卡。可是**擦到椅子时
## move_and_slide 会沿椅面滑**，一帧还能滑 3~4px —— 于是永远判不了卡，
## 路径也不会重算。等它真的滑不动了，人已经贴死在椅角上，
## 玩家必须**再点一次**才会改道（玩家报的就是这个）。
## 有这条比例判据以后，游戏自己在半帧内就做出「玩家再点一次」那个动作。
const BLOCKED_MOVE_RATIO := 0.6
## 相邻两次「撞住重算」的最小间隔（秒）。防抖：路径一变就整条重算会走成锯齿
const BLOCKED_REPATH_COOLDOWN := 0.3
## 撞住重算的独立预算，比 MAX_REPATH 宽松些 —— 撞椅子是常态操作，不该几次就用完
const MAX_BLOCKED_REPATH := 6
## 连续走顺多久，就把一次撞住预算还回来（保证预算能被恢复，不会用光后永久失效）
const BLOCKED_BUDGET_RECOVER := 1.0

## 撞住重算已用次数
var _blocked_repath_count: int = 0
## 距离上次撞住重算过了多久
var _blocked_cooldown: float = 0.0
## 连续顺畅移动了多久（用于回收撞住预算）
var _progress_clock: float = 0.0

## 沿障碍面滑行的方向（单位向量）。
##
## 【为什么不能只靠 move_and_slide】
## 它解决了「撞墙后沿墙走」，但**速度方向不变**：一帧里沿墙的分量
## 只占速度的一部分，撞得越正、走得越慢，看起来就是「顶着椅子卡一下」。
## 把速度按碰撞面的切向偏过去，绕行就成了连续动作，而不是「顶住 → 突然改道」。
## 只在真的发生碰撞时才有值；没有碰撞时每帧衰减回 0（避免残留方向把人带歪）。
var _slide_dir := Vector2.ZERO

## 沿面滑行的**最大偏转角**（度）。实际偏转 = 这个值 × |sin(入射角)|：
##   |cross| 就是 sin(入射角)，所以正撞（朝向面，sin=1）与 45° 迎面斜撞
##   （sin=1）都是 18°；擦角（贴着面滑，sin≈0）几乎不偏。
## 【为什么用「角度」而不是混合系数】角度是玩家能直接感觉到的东西
## （18° 的转向看不出来，45° 就很明显），调起来有依据；
## 而且它必须是**真的旋转**：混合再归一化会悄悄改变夹角（实测差 3 倍）。
const MAX_SLIDE_DEG := 18.0
## 没有新碰撞时，滑行方向的衰减速度（每秒）。避免旧的切向残留把人带歪。
const SLIDE_FADE := 6.0

## 新指令的落脚点与当前落脚点相差在这个范围内，就认为「玩家点的是同一个地方」，
## 保留现有路线不重算。见 command_move 里的说明（连点抖动的根因）。
const SAME_GOAL_EPS := 12.0

## 「同一物件的另一侧」容忍范围：新落脚点在这个距离内、但比现在的更远时，
## 仍然保留现有落脚点（不为了一次点击横穿整张桌子绕到另一面）。
const SIDE_KEEP_EPS := 140.0

## 不可取消的指令（收拾桌子进行中）
var _locked := false
var _stuck_clock := 0.0
var _last_pos := Vector2.ZERO

## 正在收拾的桌子与进度（0~1）
var cleaning_table: Node = null
var clean_progress: float = 0.0

## 手上端着的餐品（可能不止一份，最多由 config 的 hand_capacity 决定）
var carried: Array[String] = []


func _ready() -> void:
	# 检查器里填了正数就以检查器为准；留 0 才回落到 config.json。
	# （0 是哨兵值，见 speed 的说明——速度不可能是 0。）
	if speed <= 0.0:
		speed = Config.num("waiter_speed")
	stuck_timeout = Config.num("stuck_timeout")
	collision_layer = 1 << 1   # waiter
	collision_mask = 1 << 0    # world

	_ensure_body_shape()
	_setup_char_sprite()


## 保证身上有且只有一个「半径 RADIUS 的圆形碰撞体」。
##
## 【为什么先找再建】你在场景里给 Waiter 摆好 CollisionShape2D 之后，
## 原来那种「无条件 add_child 一个圆」会**再叠一个**：同一个物理体挂两个
## 圆形碰撞体，尺寸还不一定一样 —— 表现是「贴着桌子时被推开得莫名其妙」
## 或者「明明看着没碰到却过不去」，而且**不报错**。
## 现在：场景里摆了就听你的（一个都不加），没摆才自动补一个。
func _ensure_body_shape() -> void:
	for c in get_children():
		if c is CollisionShape2D:
			return
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = RADIUS
	shape.shape = circle
	add_child(shape)


# ── 4 方向角色动画 ──────────────────────────────────────────────────
##
## 【为什么用 AnimatedSprite2D 而不是给这个节点换 Sprite2D】
## 本节点是 CharacterBody2D，`_draw()` 里画的**影子**要留着自己画
## （贴图里没有影子，也不该由贴图管）。角色贴图挂成子节点 AnimatedSprite2D，
## 影子仍然画在身体中心 —— 于是「换美术」和「影子」互不干扰。
##
## 【动画名约定（8 个）】由你在编辑器里的 SpriteFrames 里建：
##   idle_front / walk_front   正面（朝下，面向镜头）
##   idle_back  / walk_back    背面（朝上，背对镜头）
##   idle_left  / walk_left    朝左
##   idle_right / walk_right   朝右
##
## 【为什么是 front/back 而不是 down/up】屏幕上的「上/下」和角色自己的
## 「前/后」是两套语义：走路朝上时人是**背对**镜头，叫 `back` 不会有人理解错；
## 叫 `up` 就容易和「往上抬头」混起来。已与用户确认改成 front/back。
##
## 【左右是两套独立贴图，**不用 flip_h**】已与用户确认：左右各画一套。
## 于是这里一行镜像代码都没有 —— 少一个开关，也少一类
## 「镜像之后肩上图标跑到反侧」的坑。
##
## 【缺动画时怎么办】不能写死「必须有 8 个」：美术是一张一张补的，
## 少一个就崩（或静默不动）都不行。所以这里逐级退化：
##   ① 精确名（walk_left）→ ② 相反方向同名动画 → ③ 已确认存在的任意动画
##   → ④ 什么都没有：停在第一帧、不报错。
## 这样你**先摆一套正面的帧**就能立刻看到效果，其余方向慢慢补。

## 角色贴图节点（你在编辑器里挂在 Waiter 下面的 AnimatedSprite2D）
var _char: AnimatedSprite2D = null

## 当前朝向：front / back / left / right
##
## 【为什么用字符串而不是枚举】动画名就是 `walk_left` 这种拼出来的，
## 用枚举还要写一张「枚举 → 后缀」的映射表，多一处能拼错的地方。
##
## 【常量值和动画名后缀**故意保持一致**】`DIR_FRONT` 的值就是 `"front"`，
## 于是 `"walk_" + _facing` 直接就是动画名。要是这里写 `"down"`、
## 动画名却叫 `front`，就得再维护一张映射表 —— 那正是最容易拼错的地方。
const DIR_FRONT := "front"
const DIR_BACK := "back"
const DIR_LEFT := "left"
const DIR_RIGHT := "right"

var _facing: String = DIR_FRONT
var _anim_state: String = ""
## 这一帧身体是不是真的在移动（由 _walk 每帧更新）
var _anim_moving: bool = false
## 「一个可用动画都没有」的告警只报前几次，避免刷屏
var _frame_warn_count: int = 0
const FRAME_WARN_MAX := 3


## 找到（并接好）角色贴图节点；没有就整个动画系统静默停用，退回画圆。
func _setup_char_sprite() -> void:
	for c in get_children():
		if c is AnimatedSprite2D:
			_char = c as AnimatedSprite2D
			break
	if _char == null:
		return
	if _char.sprite_frames == null:
		# 有节点没帧：当作没贴图，继续画圆（免得出现一个空白小人）
		_char = null
		return

	# 【z_index 必须在代码里再兜一层】同一节点的 `_draw()` 画在**所有**子节点
	# **下面**，而影子就在 `_draw()` 里 —— 所以贴图得排到影子之后、
	# 又要排在拿菜的图标之前。取 -1：在影子（更负的层）之上、图标之下。
	# 你在编辑器里忘了设也不会挡住肩上的餐品图标。
	_char.z_index = -1
	# 【信号名是 sprite_frames_changed】（AnimatedSprite2D 上的那个）。
	# 写成 animation_frames_changed 会当场抛
	# `Invalid access to property or key ... on a base object of type AnimatedSprite2D`
	# 并且**让 _ready() 从这里中断** —— 后面的朝向、flip_h、默认动画全都不会接上。
	_char.sprite_frames_changed.connect(_on_frames_changed)
	_anim_state = ""
	_apply_facing_visual()
	_update_animation()
	# 【把实际动画名列一遍】排版对不上时（名字拼错、少个下划线、大小写不同）
	# 这里一行就能看出来，不用去翻 SpriteFrames 面板。
	print("[服务员] SpriteFrames 里的动画：%s"
		% ", ".join(_char.sprite_frames.get_animation_names()))
	queue_redraw()


## 你在编辑器里改了 SpriteFrames（加动画 / 改帧）时重挑一次
func _on_frames_changed() -> void:
	_anim_state = ""
	_apply_facing_visual()
	_update_animation()


## 没有角色贴图时画代码圆形
func has_char_sprite() -> bool:
	return _char != null


## 脚底那个代码画的落地影子要不要画（**检查器里可调**）。
##
## 【默认 false：有角色贴图就不画】
## 影子是按 `RADIUS = 16` 算的圆（约 30px 宽），而角色贴图只有 32×32、
## 人形比画布窄 —— 于是影子会**从贴图的透明边里露出来**，看着就是一个
## 多余的深色圆（用户报的就是这个）。所以有贴图时默认不画。
##
## 【为什么不是直接删掉】没贴图的兜底模式（纯灰圆服务员）仍然需要影子，
## 否则小人像浮在空中。而且你这份美术要是**本身就带影子**（很多
## 32×32 角色素材帧里就画了），那更不该叠第二个。
##
## 【什么时候想打开】贴图里没有影子、又觉得小人飘着 —— 勾上它，
## 然后按需调 `shadow_radius` / `shadow_offset` 让它贴合你的美术。
@export var draw_shadow: bool = false

## 影子的圆心（相对身体中心）与半径。默认值 = 原来那个「按 RADIUS 算」的圆。
const SHADOW_OFFSET := Vector2(0.0, RADIUS * 0.55)
const SHADOW_RADIUS := RADIUS * 0.95


## 按「在不在走 + 朝哪边」选动画。
## 停下时**保持最后朝向**（播 idle_<朝向>）—— 已与用户确认。
func _update_animation() -> void:
	if _char == null:
		return
	var want := "%s_%s" % ["walk" if _anim_moving else "idle", _facing]
	if want == _anim_state:
		return
	_anim_state = want
	_apply_facing_visual()
	var picked := _resolve_animation(want)
	if picked == "":
		# 【什么都不播，而不是硬塞一个不存在的名字】
		# 给 `animation` 设一个 SpriteFrames 里没有的名字，Godot 会按「资源加载
		# 失败」处理并报错（实测还会连带影响 frame / sprite_frames 的取值）。
		# 宁可让小人静止一帧，也不去设一个不存在的名字。
		if _frame_warn_count < FRAME_WARN_MAX:
			_frame_warn_count += 1
			push_warning("[服务员] SpriteFrames 里没有可用动画（想播 \"%s\"）—— 小人会静止不动。" % want)
		return
	_char.animation = picked
	_char.play()


## 左右镜像：4 套贴图只画了 right 时，往左走是最右那套的镜像。
##
## 【为什么不镜像其他方向】front / back 是正面背面，左右镜像没有意义
## （镜像一个正面小人，贴图不会变成侧面）。所以只在 left/right 之间翻。
func _apply_facing_visual() -> void:
	if _char == null:
		return
	_char.flip_h = _facing == DIR_LEFT


## 从「想要的动画名」逐级退化成「真实存在的名字」；都没有则返回 ""。
##
## 【降级顺序：先借镜像方向，再借相反状态】
## 这个顺序是刻意的：**朝向比"在不在走"重要**。
##   往左走却没有 walk_left → 借 walk_right + flip_h ✓ 看着完全对
##   要是先借 idle_left，人会一边平移一边站定不动 ✗
## 所以链条是：精确名 → 镜像名(left↔right) → 当前朝向的相反状态 → 任意动画。
func _resolve_animation(want: String) -> String:
	var frames := _char.sprite_frames
	if frames.has_animation(want):
		return want

	var state := "walk" if _anim_moving else "idle"
	var other := "idle" if _anim_moving else "walk"
	var mirror := _mirror_dir(_facing)

	# ① 同状态、镜像方向（left 缺帧时借 right，反之亦然）
	var by_mirror := "%s_%s" % [state, mirror]
	if mirror != _facing and frames.has_animation(by_mirror):
		return by_mirror
	# ② 同朝向、相反状态（还没有 walk 帧时，先拿 idle 顶一下，至少不是静止）
	var by_other := "%s_%s" % [other, _facing]
	if frames.has_animation(by_other):
		return by_other
	# ③ 镜像方向 + 相反状态
	var by_both := "%s_%s" % [other, mirror]
	if mirror != _facing and frames.has_animation(by_both):
		return by_both
	# ④ 最后才随便挑一个（宁可朝向不对，也不要整个人僵住）
	var names := frames.get_animation_names()
	return String(names[0]) if names.size() > 0 else ""


## 左右互为镜像方向；front/back 没有镜像，原样返回。
func _mirror_dir(d: String) -> String:
	if d == DIR_LEFT:
		return DIR_RIGHT
	if d == DIR_RIGHT:
		return DIR_LEFT
	return d


## 按本帧的移动方向刷新朝向。
##
## 【为什么横竖分开判】斜着走（比如 (1, 1)）时两个分量一样大，
## 「谁大听谁的」会变成随机抖；这里定死**横向优先**：
## 斜着走看起来就是朝侧面走，符合像素游戏的观感。
func _update_facing(dir: Vector2) -> void:
	if dir.length_squared() < 0.0001:
		return
	var f := _facing
	if absf(dir.x) >= absf(dir.y):
		f = DIR_RIGHT if dir.x > 0.0 else DIR_LEFT
	else:
		f = DIR_FRONT if dir.y > 0.0 else DIR_BACK
	if f == _facing:
		return
	_facing = f
	# 朝向一变，上下台阶就要重画；拿菜图标也可能换肩
	queue_redraw()


# ── 指令接口 ───────────────────────────────────────────────────────

func is_busy() -> bool:
	return _active


func is_locked() -> bool:
	return _locked


## 下一条指令。
##
## touch_target 不为 null 时，到达判定改成「身体碰到这个物件」，
## 而且目标点每帧按「离我最近的可碰位置」重算 ——
## 于是从哪一侧过去就从哪一侧贴上，不会先绕到固定的那一面。
func command_move(walk_point: Vector2, on_arrive: Callable = Callable(),
		desc: String = "", touch_target: Node = null) -> bool:
	if _locked:
		DebugTrace.note_cmd("**被拒绝**：_locked=true（正在清洁） desc=%s" % desc)
		return false
	DebugTrace.note_cmd("接受：desc=%s 目标=%s" % [desc, _v(walk_point)])

	# 【顺序很重要：先更新本次指令的目标，再算落脚点】
	#
	# 曾经的写法是「先 `_compute_goal()`、后赋值 _target/_touch_target」——
	# 于是 `_compute_goal()` 读到的是**上一条指令**的目标，算出上一个落脚点，
	# 新指令一上来就把那个旧落脚点当成自己的落脚点：服务员还在桌子那边
	# （离旧落脚点 4.3px），同帧就判「到了」→ 立刻回调 →
	# **离饮料机/点餐台还有半个屏幕就把 UI 弹出来了**（玩家报的 bug）。
	# 现在把「保留路径」的判断拆成两步：命中条件只看旧值，赋值统一在后面。
	var prev_goal := _goal_pt
	var prev_touch := _touch_target
	var was_active := _active
	var had_path := _repath_count > 0

	_target = walk_point
	_touch_target = touch_target
	_on_arrive = on_arrive
	_desc = desc
	_active = true
	_stuck_clock = 0.0
	_last_pos = global_position
	_repath_count = 0
	# 撞住预算 / 滑行方向都要按指令重置，否则上一条指令的残留会带进新路线
	_blocked_repath_count = 0
	_blocked_cooldown = 0.0
	_progress_clock = 0.0
	_slide_dir = Vector2.ZERO
	# 【每次新指令都要重置】否则第二次点击时到达原因不会被记录
	_arrival_logged = false
	var new_goal := _compute_goal()

	# 判据：新指令的落脚点与当前落脚点几乎相同（同一张桌子的最近可碰点本来就一样）
	# 且目标物件没变 → 保留正在走的路线，只更新「到了以后做什么」。
	# 这样连点变成「无感刷新」，而不是「重新规划 → 瞬移」。
	#
	# 【为什么要有这条】玩家连点会看到「小人左右横跳」：每次点击都重算路径，
	# 而新路径的**第一个拐点常常在当前身后**（A* 从格子中心出发，起点格与当前点差
	# 几像素），于是人被瞬移回那个拐点 → 下一帧再走回来（实测 18px 一帧的来回）。
	var keep_path := false
	var same_target := touch_target == prev_touch
	if was_active and same_target and had_path \
			and new_goal.distance_to(prev_goal) <= SAME_GOAL_EPS:
		keep_path = true
		DebugTrace.note_cmd("  点到同一目标：保留现有路线（避免重算后瞬移回来）")
	elif was_active and touch_target == null and prev_touch == null and had_path \
			and new_goal.distance_to(prev_goal) <= SAME_GOAL_EPS:
		# 【点空地也一样】玩家在同一个位置附近点两下（鼠标抖、连点没对准），
		# 每一下都重算路径，就会出现「新路径首拐点在身后 → 一步掉头」的来回。
		# 相差不到 12px 就当作同一次点击：继续走现在的路线。
		keep_path = true
		DebugTrace.note_cmd("  点空地且落脚点几乎相同：保留现有路线")
	elif was_active and same_target and had_path and touch_target != null \
			and new_goal.distance_to(prev_goal) <= SIDE_KEEP_EPS \
			and new_goal.distance_to(global_position) > prev_goal.distance_to(global_position):
		# 【别为了换一侧而绕路】玩家点左右两半时，最近可碰点会从桌子左边跳到右边。
		# 如果新落脚点比原来的更远，说明现下正在走的那一侧更省事 ——
		# 保留它，别掉头（实测「左右交替点」会造成 36 次/秒的真掉头）。
		keep_path = true
		DebugTrace.note_cmd("  点到同一物件的另一侧：保留现有落脚点（%s，不绕路）" % _v(prev_goal))

	if keep_path:
		# 路径继续走；落脚点仍用原来的那一个（新的那个几乎相同）
		_goal_pt = prev_goal
	else:
		_waypoints.clear()
		_goal_pt = new_goal
	command_started.emit(desc)
	return true


## 落脚点：本次指令走到哪一点算完成。
##
## 【为什么点空地也必须算出落脚点】
## 早先只有「目标是家具」时才设落脚点，而点空地走的是另一条入口
## （walk_to_only，没有目标物件）—— 于是**点空地完全不寻路**，
## 服务员朝那个点走直线，撞上桌子就杵在那儿。玩家反馈的
## 「撞到桌子不会自己绕开」就是这个。
## 现在落脚点一律算出，寻路对所有指令统一生效。
##
## 【为什么必须退到「整团家具之外」，而不是退开碰撞盒表面】
## 曾经按目标物件的 collision_rect（椅子）退 18px，落点算出来是 (150,410)——
## 而它正好**在左椅子自己的范围里**（椅子 x132..172 y395..425）。
## 于是「寻路目标在障碍内部」，A* 只能给斜线，而且服务员走不到。
## 【注意：外接矩形只是第一步，最后必须过 `_clear_of_obstacles()`】
## 外接矩形比真实碰撞盒**大一圈**（它把椅子也算进桌子的范围），
## 所以按它退出来的点**不保证身体放得下** —— 实测会压进桌体 4.4px，
## 造成「碰到桌子一直抖」。真正的净空由 `_clear_of_obstacles()` 在
## **真实碰撞盒**上做，见那里的说明。
func _compute_goal() -> Vector2:
	if _touch_target == null or not is_instance_valid(_touch_target):
		# 点空地：就是那个点本身，但**同样要做净空**：
		# 玩家点在桌沿上（视觉上是空地/桌边）时，那个点在碰撞盒里，
		# 人走过去会一直站在桌子里被每帧挤出来 —— 实测就是「x 在 1.8px 内
		# 以 60Hz 左右摆动」的常驻抖动（点空地的分支原先没有这道处理）。
		return _clear_of_obstacles(_target)

	# 整团家具的范围（有 nav_rect_global 就用它，否则退回碰撞盒）
	var box: Rect2
	if _touch_target.has_method("nav_rect_global"):
		box = _touch_target.call("nav_rect_global")
	else:
		box = Rect2(_target, Vector2.ZERO)

	var raw: Vector2 = _touch_target.call("touch_point", global_position)
	# 从「整团家具的外接范围」推最近的边界点，再往外退身体半径
	if box.size.x > 0.0 and box.size.y > 0.0:
		raw = EntityBase.nearest_point_on_rect(box, global_position)

	var away := global_position - raw
	if away.length() < 1.0:
		away = Vector2(0, 1)
	# 【注意】这里**不加 standoff**。
	# 曾经把「退开量」加在这里，结果落脚点被推到网格的障碍格里，
	# A* 把它吸附到别处 —— 服务员绕到桌子上面去了（截图确认过）。
	# 落脚点只负责「走到不碰家具的空地」，退让放在到达判定里做。
	return _clear_of_obstacles(raw + away.normalized() * (RADIUS + 4.0))


## 把落脚点推到「身体放得下」的位置：离所有家具的碰撞盒至少 RADIUS 远。
##
## 【为什么必须做，而且必须用碰撞盒（不是外接矩形）】
## 上面用的是「整团家具的外接矩形」，它比真实碰撞盒**大一圈**：
##   桌1 外接矩形 x 190..350 / y 395..500（左椅把左边界拉到 190），
##   而桌体碰撞盒只有 x 253..347 / y 425..500。
## 从桌子下方点桌子时，外接矩形下边 = 桌体碰撞盒下边 = y500，退 20px 得 y480 ——
## 但「可碰区」是**整个桌面**（y400..460），于是 y480 离碰撞盒其实只有 12px，
## 身体（半径 16）**压进桌子 4px**。
##
## 后果不是「走不到」，而是**持续抖动**：人一直想压进去、每帧被 move_and_slide
## 挤出来，叠加沿面滑行给的横向分量，就变成稳定的左右摆动
## —— 实测 x 在 343.6↔344.8 之间以 60Hz 来回，玩家看到的就是「碰到桌子在抖」。
##
## 【推出去多少：略小于 RADIUS，给自己留余量】
## 落脚点同时也是「到了没有」的判据：带触碰目标的指令要求身体真的贴上
## （`touches_from`，容差 RADIUS + 1 = 17px）。如果落脚点的余量取成整 RADIUS，
## 就只剩 1px 余量 —— 到位后可能「判定没碰到 → 再走一步 → 压进桌子 3px →
## 被 move_and_slide 推回来」，形成 60Hz 的循环（实测 x 上下来回 1.8px 的抖动）。
## 取 RADIUS + 1 = 17px：触碰判定（容差 RADIUS + 1）刚好成立、稳定贴住；
## 身体最多压进 1px，不会触发「压进去—被挤出」的挤压抖动。
const GOAL_CLEARANCE := RADIUS + 1.0


func _clear_of_obstacles(p: Vector2) -> Vector2:
	var out := p
	for i in 3:                       # 最多迭代几次：推开后可能又靠近另一件家具
		var worst := -1.0
		var away := Vector2.ZERO
		for box in _obstacle_boxes():
			var near := EntityBase.nearest_point_on_rect(box, out)
			var d := out.distance_to(near)
			if d < GOAL_CLEARANCE and d > worst:
				worst = d
				away = out - near
		if worst < 0.0:
			break
		if away.length() < 0.001:
			away = Vector2(0, 1)      # 正好压在盒内：随便挑一个方向推出去
		out = out + away.normalized() * GOAL_CLEARANCE
	return out


## 所有家具的碰撞盒（世界坐标）。桌子会连同每个椅子一起给出。
## 数量很少（3 桌 × 3 盒），而且只在落脚点计算时用，不必缓存。
func _obstacle_boxes() -> Array:
	var out: Array = []
	for t in Game.tables:
		for box in t.call("collision_shapes_global"):
			out.append(box)
	return out


func cancel_command(reason: String = "") -> void:
	if not _active:
		return
	_active = false
	_on_arrive = Callable()
	_touch_target = null
	_waypoints.clear()
	# 【必须解除「正在收拾」的登记】原来这里直接把 cleaning_table 置空，
	# 而登记还留在 TableRules 里 → 那张桌子**永久不可坐**
	# （选座永远跳过它），而且不报任何错。
	# 关卡模式里「重开一局」会走到这条路径，所以这个坑一定会被踩到。
	TableRules.set_cleaning(cleaning_table, false)
	cleaning_table = null
	clean_progress = 0.0
	_locked = false
	command_cancelled.emit(reason)


# ── 每帧 ───────────────────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	_anim_moving = false
	if _active:
		_walk(delta)
	elif cleaning_table != null:
		_advance_cleaning(delta)

	_update_animation()
	queue_redraw()


func _walk(delta: float) -> void:
	# 到达判定
	if _arrived_now():
		_finish()
		return

	# 该朝哪走：先用寻路求拐点，再朝当前那个拐点走。
	var step_target := _next_step()
	var to_step := step_target - global_position
	var dist := to_step.length()
	if dist <= 0.001:
		if _waypoints.is_empty():
			_finish()
		else:
			_waypoints.pop_front()
		return

	var want_dir := to_step / dist
	# 【A】上一帧没走出去（撞在椅子上）→ 先改道，再走这一帧。
	# 这一步等于把玩家手动「再点一次」做的事交给游戏自己做，
	# 而且是在**刚开始贴住**（半帧内）就做，不是等到贴死。
	if _blocked_no_progress(delta) and _try_blocked_repath():
		# 路线换了，方向也要重取：否则这一帧仍朝旧的、撞住的拐点走
		step_target = _next_step()
		to_step = step_target - global_position
		dist = to_step.length()
		if dist <= 0.001:
			return
		want_dir = to_step / dist

	velocity = _slide_steer(want_dir) * speed
	# 【动画朝向用的是 velocity，不是 to_step】
	# 沿障碍面滑行（_slide_steer）会让实际走向和「朝拐点方向」差最多 18°，
	# 而角色看着走的是**实际**方向 —— 拿实际速度判朝向才不会出现
	# 「贴墙时人往右走、贴图却朝上」。
	_update_facing(velocity)
	_anim_moving = velocity.length_squared() > 1.0
	move_and_slide()
	_update_slide_dir(delta)
	if _arrived_now():
		_finish()
		return
	_check_stuck(delta)


## 【A】这一帧是不是「想走却没走出去」。
##
## 判据是**真实位移 / 期望步长**，不是绝对位移：擦着椅子滑行时位移仍有
## 3~4px，旧判据（< 1.5px）看不见，但只有期望步长的四成 —— 那正是
## 「贴着椅子磨」的状态，必须立刻改道。
func _blocked_no_progress(delta: float) -> bool:
	var want := speed * delta
	if want <= 0.01:
		return false
	# 位移**正好为 0** = 这一帧压根没走过（指令刚下达），不是「撞住了」。
	# 不加这道判断，指令第一帧就会白算一次路径。
	var got := global_position.distance_to(_last_pos)
	if got <= 0.0:
		return false
	return got < want * BLOCKED_MOVE_RATIO


## 【A】撞住后的重算（带冷却与独立预算）。
## 返回 true = 路径已换新，调用方要用新方向走。
func _try_blocked_repath() -> bool:
	if _blocked_cooldown > 0.0:
		return false
	if _blocked_repath_count >= MAX_BLOCKED_REPATH:
		return false
	if not _try_repath():
		return false
	_blocked_repath_count += 1
	_blocked_cooldown = BLOCKED_REPATH_COOLDOWN
	return true


## 【C】把「朝 to_dir 走」修正成「朝 to_dir 走，但沿障碍面偏过去」。
##
## 偏转角的来源是**真实的碰撞面法线**（move_and_slide 的记录），
## 所以正撞时几乎整个速度都转到切向（顺着家具滑走，不再顶着），
## 侧擦时只偏一点（路线基本不变，不会为了避让绕远路）。
func _slide_steer(to_dir: Vector2) -> Vector2:
	# 【_slide_dir 是**上一帧**的碰撞法线】所以它可能已经过期：这一帧人可能
	# 正在侧擦（与面平行甚至正在离开），旧法线就不再代表「前面挡着的面」。
	# 用它算切向会把方向算反 —— 实测侧擦时人被往**回头**方向推（偏 18° 且反向）。
	# 所以先筛一层：只有法线与前进方向明显对抗（cos < -0.2）才算「还压着这个面」。
	var pressing := _slide_dir != Vector2.ZERO and to_dir.dot(_slide_dir) < -0.2
	if not pressing:
		return to_dir
	# 1) 先算出「贴着这个面走」的方向。
	var tangent := _slide_dir - to_dir * _slide_dir.dot(to_dir)
	var degenerate := tangent.length() < 0.05
	if degenerate:
		# 正撞：方向与法线共线，垂直分量为 0，纯几何上没有「沿哪边滑」的答案。
		# 【不要用「挑一侧的垂线」】那样会凭空给出一个横向分量：实测贴上桌子
		# 底面时人就在 x 343.6↔344.8 之间以 60Hz 左右摆动（玩家看到的抖动）。
		# 正确做法是给**与行进方向同向**的切向 → 正撞时偏转退化为 0，
		# 人不再横向乱动，改道交给重算路径（A 条）去做。
		tangent = Vector2(-_slide_dir.y, _slide_dir.x)
		if tangent.dot(to_dir) < 0.0:
			tangent = -tangent
	tangent = tangent.normalized()
	# 【切向方向必须与前进方向一致】垂直分量只保证「垂直于最近接近线」，
	# 它可能与前进方向相反（实测斜撞时会取到反的那一侧），
	# 按它偏就变成「往回退」。点积为负说明取反了。
	if tangent.dot(to_dir) < 0.0:
		tangent = -tangent
	# 3) 偏多少要**看撞得多正**：|cross| = sin(入射角)。
	#    侧擦（≈0）→ 几乎不偏，路线不为了避让拐出多余的弯；
	#    斜撞 → 偏一半；正撞（sin=1）→ 偏满（18°）。
	#
	# 【完全正撞（degenerate）时偏转必须是 0】那种情况切向垂直于行进方向，
	# 按它偏只会得到一个凭空出现的横向分量 —— 实测就是贴着桌子
	# 以 60Hz 左右摆动。所以退化时直接用满权重，而 tangent 与 to_dir 垂直，
	# 旋转 18° 后横向分量仍为 0（等价于不偏），人不再乱抖。
	#
	# 【4) **显式按角度旋转**】不要用 lerp/slerp 混合：
	#    lerp 混合再归一化会改变夹角（用叉积反算 23°，真实却只有 7°），
	#    调参时看到的是假数据；slerp 的 t 又是「离起点多远」（写 0.75 只转 22.5°），
	#    同样反直觉。这里直接定死「最多偏 MAX_SLIDE_DEG 度」，量多少就是多少。
	var max_deg := MAX_SLIDE_DEG * (1.0 if degenerate else absf(to_dir.cross(_slide_dir)))
	# 转入障碍的那一侧 = 需要**逆时针**（负角度）转过去的方向：
	# 实测 cross(d, n) > 0 时按 +18° 转反而更贴住障碍（Godot 里 rotated 的
	# 正角度是顺时针，与数学惯例相反）。所以这里取反，并用体检脚本按
	# 「偏转后到障碍面的距离是否变大」验证方向。
	var turn := -max_deg if to_dir.cross(_slide_dir) > 0.0 else max_deg
	return to_dir.rotated(deg_to_rad(turn))


## 【C】按本帧的真实碰撞面刷新滑行方向；没撞就把旧方向衰减掉。
##
## 【为什么用「所有碰撞法线之和」】
## 卡在桌角（两面同时挡）时，单看第一条碰撞会让人沿一面滑、
## 下一帧又撞上另一面，来回抖。把法线相加得到的是「合力的反方向」，
## 沿它的切向走正好能从角里切出去。
func _update_slide_dir(delta: float) -> void:
	var n := Vector2.ZERO
	for i in get_slide_collision_count():
		var col := get_slide_collision(i)
		if col != null:
			n += col.get_normal()
	if n.length() > 0.01:
		_slide_dir = n.normalized()
	elif _slide_dir != Vector2.ZERO:
		_slide_dir = _slide_dir.lerp(Vector2.ZERO, clampf(SLIDE_FADE * delta, 0.0, 1.0))
		if _slide_dir.length() < 0.02:
			_slide_dir = Vector2.ZERO


## 下一个要走的点。没路可走时退回落脚点。
##
## 【为什么必须丢掉「离自己太近」的拐点】
## A* 的路径起点是**格子中心**，而自己站在格子里的任意位置，
## 所以第一个拐点常常只离自己十几像素。这点距离小于「到达判定半径」
## 加上碰撞挤出的偏移 —— 服务员会被家具滑开、永远判定不到「已到达拐点1」，
## 于是整条路径卡死在第一步。丢掉它们以后，剩下的拐点间距都够大，判定稳定。
## 丢掉「在身后、并且走一步就到」的首个拐点，改成直奔落脚点。
##
## 【为什么必须丢】A* 的路径以**格子中心**为首点，重算路径时（玩家连点、
## 撞住改道、落脚点换点）经常会算出一个**在当前身后**的首拐点。
## 按它走就是一帧掉头、下一帧再掉回来 —— 实测每帧 4.33px、
## 19 次/秒的左右横跳，玩家看到的就是「碰到桌子在抖」。
##
## 【为什么只丢「近」的】拐点离得远说明确实要绕回去（比如刚走过头），
## 这时掉头是对的，不能丢。所以加距离上限：只处理「一步就能到」的那种。
func _drop_backward_first_step() -> void:
	if _waypoints.size() < 2:
		return
	var to_first: Vector2 = _waypoints[0] - global_position
	if to_first.length() < 0.001:
		return
	var to_goal: Vector2 = _goal_pt - global_position
	if to_first.normalized().dot(to_goal.normalized()) >= -0.2:
		return
	var step := speed * (1.0 / 60.0)
	# ① 一步就能到的身后拐点：直接丢（严格来说走它也无害，但它就是那一下掉头）
	var near := to_first.length() <= step * 2.0
	# ② 身后的拐点，但**直线走向落脚点没被家具挡住**：也可以丢 ——
	#    实测「从桌子下方点桌子」时，首拐点常是身后 30~60px 的起点格，
	#    人先掉头走一步再转回来，玩家看到的就是碰桌子时抖一下。
	#    用射线验一下直线，挡住就老老实实走拐点（那才是绕家具必需的）。
	var straight_ok := not _line_blocked(global_position, _goal_pt)
	if near or straight_ok:
		DebugTrace.note_cmd("  丢掉身后的首拐点 %s（%s，改直奔落脚点）" % [
			_v(_waypoints[0]), "太近" if near else "直线可达"])
		_waypoints.pop_front()


func _next_step() -> Vector2:
	# 一次寻路算出一串拐点，之后逐个走完 —— 不必每帧重算
	if _waypoints.is_empty() and _repath_count < MAX_REPATH:
		_build_path()
	# 【身后那个首拐点直接丢掉】见 _drop_backward_first_step()：
	# 它是「走一步就掉头」的抖动来源（玩家连点桌子时实测 19 次/秒）。
	_drop_backward_first_step()
	if not _waypoints.is_empty():
		var wp: Vector2 = _waypoints[0]
		var d := global_position.distance_to(wp)
		# 【吸附只在「真的站在上面」时做】d 小于 1.5px 才是「已经到位」，
		# 这时把位置对齐到精确的格子中心，保证后续线段是干净直角。
		#
		# 【为什么不能按 ARRIVE_EPS(6px) 吸附】那是一个**瞬移**：
		# 会在任意方向上把人硬拽最多 6px。玩家连点桌子时每 0.15s 就重算一次
		# 路径，而新路径的首拐点常常落在**身后**（A* 从格子中心出发），
		# 于是人一帧被拽回去、下一帧又走回来 —— 实测就是「沿一条线左右横跳」
		# （每帧 4.33px、19 次/秒），玩家看到的就是抖动。
		# 现在改成「进入 6px 就算走过这个拐点」：不再瞬移，最多差几像素地
		# 直奔下一个拐点，肉眼看不出来，也不会来回跳。
		if d <= ARRIVE_EPS:
			if d <= SNAP_EPS:
				global_position = wp
			_waypoints.pop_front()
			_last_pos = global_position
			_stuck_clock = 0.0
			if _waypoints.is_empty():
				return _goal_pt
			return _waypoints[0]
		return wp
	return _goal_pt


## 算一条到目标的折线。到不了就留空（于是退回直线走 + 卡住看门狗兜底）。
##
## 【为什么给终点留一段余量】
## 目标常常紧贴家具（比如「桌子底面往下 12px」）。如果直接把它当归宿点，
## A* 的终点会吸附到最近空格子，最后那个拐点可能仍在家具里 ——
## 服务员永远走不到，卡在最后一步。
## 所以把终点沿「从目标指向自己」的方向往外挪一点，落回空地，
## 剩下的最后一小段交给「碰到就到达」判定。
func _build_path() -> void:
	_repath_count += 1
	var pf := get_tree().get_first_node_in_group("pathfinder")
	if pf == null:
		return
	# 重新算一次落脚点（身体可能已经移动了不少），再寻路到它
	_goal_pt = _compute_goal()
	var pts: Array = pf.call("find_path", global_position, _goal_pt)
	_waypoints = _prune_waypoints(pts)
	# 落脚点够不到目标（被椅子挡住）→ 换一个能碰到的落脚点
	_retarget_for_touch()
	# 调试记录（只有工程目录放了 DEBUG_WALK 文件时才打印）
	DebugTrace.note_path(_desc, global_position, _goal_pt, pts, _waypoints)


## 判定「已经够得着目标」的容差
const GOAL_TOLERANCE := RADIUS + 3.0


## 换一个「站上去身体真能碰到目标」的落脚点。
##
## 【为什么需要】从被椅子挡住的那一侧点桌子时，落脚点会落在椅子外侧
## （实测离桌面 58~68px）。服务员身体根本够不到桌子，却因为
## 「走到落脚点也算到达」而开始清洁 —— 玩家看到的就是
## 「没碰到桌子就清洁了」。
##
## 已与用户确认的处理：**绕到够得着的那一侧**。
## 做法：在目标周围一圈圈找「A* 走得到、且站上去能碰到目标」的格子，
## 找到就把落脚点和路径都换过去。
## 找不到就保持原样（宁可让他停在原地，也不要卡死）。
func _retarget_for_touch() -> void:
	if _touch_target == null or not is_instance_valid(_touch_target):
		return
	if not _touch_target.has_method("touch_box"):
		return
	var box: Rect2 = _touch_target.call("touch_box")
	if box.size.x <= 0.0:
		return
	# 现在这个落脚点已经够得着目标 → 不用换
	if _goal_pt.distance_to(EntityBase.nearest_point_on_rect(box, _goal_pt)) <= GOAL_TOLERANCE:
		return
	var pf := get_tree().get_first_node_in_group("pathfinder")
	if pf == null:
		return

	var base: Vector2 = box.get_center()
	var count := 16
	var tried := 0
	var reached_touch := 0
	var path_ok := 0
	var last_reason := ""
	for i in count:
		var ang := TAU * float(i) / float(count)
		for off in [RADIUS + 2.0, RADIUS + 10.0]:
			var cand: Vector2 = base + Vector2(cos(ang), sin(ang)) * float(off)
			# 站在这儿身体能碰到目标吗
			if cand.distance_to(EntityBase.nearest_point_on_rect(box, cand)) > RADIUS + 1.0:
				continue
			reached_touch += 1
			tried += 1
			# A* 能走到它吗（终点不会被吸附到别处）
			var path: Array = pf.call("find_path", global_position, cand)
			if path.is_empty():
				last_reason = "A* 无路径"
				continue
			var endp: Vector2 = path[path.size() - 1]
			if endp.distance_to(cand) > 1.0:
				last_reason = "终点被吸附到 %s（目标 %s）" % [str(endp.round()), str(cand.round())]
				continue
			path_ok += 1
			_goal_pt = cand
			_waypoints = _prune_waypoints(path)
			DebugTrace.note_retarget(_desc, cand, box)
			return
	DebugTrace.note_retarget_fail(_desc, box, reached_touch, path_ok, last_reason)


## 拐点整理：只做「共线合并」，保证走出来是纯直角折线。
##
## 【为什么不能再丢「太近的拐点」】
## 之前有两条按距离丢点的规则，两条都在破坏直角结构：
##   a) 丢「离自己 < 26px」的首个拐点 —— 实测起点到第一个拐点只差 14px，
##      被丢掉后唯一的点就剩终点，服务员直接走斜线；
##   b) 按视线丢点 —— 斜线刚好没碰到家具就留下一条自由斜线。
## 近拐点不但无害，反而有用：段更短，而且走完会**吸附**到拐点上，
## 位置精确，后面的段就是标准直角。所以现在只丢「已经站在上面」的点（<1px）。
##
## 【为什么只合并共线段】
## 方向相同的连续段，中间点纯属多余，去掉不影响形状；
## 方向一变（直角转折）就保留 —— 于是路径永远轴对齐。
func _prune_waypoints(pts: Array) -> Array:
	var keep: Array = []
	# 1) 丢掉已经站在上面的点（否则会「原地追一个 0 距离的目标」）
	for p in pts:
		if global_position.distance_to(p) >= 1.0:
			keep.append(p)
	if keep.is_empty():
		return pts

	# 2) 合并共线的连续段
	if keep.size() >= 3:
		var out: Array = [keep[0]]
		for i in range(1, keep.size() - 1):
			var prev: Vector2 = out[out.size() - 1]
			var cur: Vector2 = keep[i]
			var nxt: Vector2 = keep[i + 1]
			var d1: Vector2 = cur - prev
			var d2: Vector2 = nxt - cur
			if d1.length() < 0.01 or d2.length() < 0.01:
				continue
			# 方向一致（同向或反向都算同一条直线）→ 中间点多余
			if absf(d1.normalized().dot(d2.normalized())) <= 0.99:
				out.append(cur)
		out.append(keep[keep.size() - 1])
		keep = out

	# 3) 强制轴对齐：每段必须是横或竖
	return _orthogonalize(keep)


## 把路径强制变成「横竖交替」的直角折线。
##
## 【为什么这一步是必需的】
## A* 给的是**格子中心**。终点为了贴住家具会偏几像素
## （实测：本该 (600,240)，实际 (610,220)），于是出现一条
## 「几乎竖直、只斜了 4°」的段。上一步的共线合并按方向相近判断，
## 会把它和真正的竖直段合并成一条**斜线** ——
## 这就是玩家看到的「一靠近桌椅就出现斜线」。
##
## 做法：对每一段，插入一个直角拐角，把这一小段拆成「先横后竖」或「先竖后横」。
## 两种拆法都用**真实家具碰撞盒**验证，哪条不碰就用哪条；
## 两条都碰（理论上极少）才保留原样，宁可不好看也不能穿家具。
func _orthogonalize(pts: Array) -> Array:
	if pts.size() < 2:
		return pts
	var out: Array = [pts[0]]
	for i in range(1, pts.size()):
		var a: Vector2 = out[out.size() - 1]
		var b: Vector2 = pts[i]
		# 已经轴对齐就不用管
		if absf(a.x - b.x) < 0.5 or absf(a.y - b.y) < 0.5:
			out.append(b)
			continue
		# 先横后竖 或 先竖后横，哪个不碰家具用哪个
		var corner_h := Vector2(b.x, a.y)
		var corner_v := Vector2(a.x, b.y)
		var bh := _line_blocked(a, corner_h) or _line_blocked(corner_h, b)
		var bv := _line_blocked(a, corner_v) or _line_blocked(corner_v, b)
		if not bh:
			out.append(corner_h)
			out.append(b)
		elif not bv:
			out.append(corner_v)
			out.append(b)
		else:
			out.append(b)
	return out


func _v(p: Vector2) -> String:
	return "(%.0f,%.0f)" % [p.x, p.y]


## 从 a 到 b 这条直线有没有被家具挡住
func _line_blocked(a: Vector2, b: Vector2) -> bool:
	if a.distance_to(b) < 0.5:
		return false
	var space := get_world_2d().direct_space_state
	var q := PhysicsRayQueryParameters2D.create(a, b)
	q.collision_mask = 1 << 0          # 只看 world 层（家具）
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	return not hit.is_empty()


## 撞住了就重算一次路径（绕不过去时最多重算 MAX_REPATH 次）
func _try_repath() -> bool:
	if _repath_count >= MAX_REPATH:
		return false
	_waypoints.clear()
	_build_path()
	return not _waypoints.is_empty()


func _arrived_now() -> bool:
	# 1) 碰到目标物件（或走到它要求的退让距离内）→ 算到
	if _touch_target != null:
		if not is_instance_valid(_touch_target):
			return false
		# 退让量：目标可以要求服务员再站远一点，避免身体重叠。
		# 放在**到达判定**里而不是落脚点里 —— 落脚点必须落在空地上，
		# 加退让会让它掉进障碍格，服务员就会绕到奇怪的位置去。
		var extra := 0.0
		if _touch_target.has_method("standoff"):
			extra = float(_touch_target.call("standoff"))
		# 【容差：已经贴上、但被挤在 1~2px 之外时也算到达】
		#
		# 否则会出现一种常驻抖动（实测）：桌子碰撞盒底边 y=460、可碰判定要
		# 距离 ≤ 17，而身体半径 16 只能压到距离 16.1 ——
		# 那 1px 的夹缝里「判定没碰到」→ 继续朝目标走 → 被 move_and_slide
		# 挡住 → 每帧在原地顶，叠加沿面滑行给的横向分量，就是
		# x 在 1.8px 内、60Hz 的左右摆动（玩家看到的「碰到桌子在抖」）。
		# 给 2px 容差后：贴上去就判定到达，停在原地不再顶。
		var hit := bool(_touch_target.call("touches_from", global_position, RADIUS + extra + 2.0))
		if hit:
			_trace_arrival("碰到物件")
			return true
		# 【要求触碰的指令：不再用「走到落脚点」兜底】
		#
		# 原来下面那条「走到落脚点也算到达」是无条件生效的，本意是应付
		# 家具的「挤出偏移」（身体被挡住，差几像素碰不上）。
		# 但玩家反馈：从被椅子挡住的一侧点桌子时，落脚点落在椅子外侧
		# （离桌面 68px），他走到那儿就算"到达"→ **没碰到桌子就开始清洁**。
		#
		# 现在只要指令带了触碰目标，就必须真的碰到才算到达。
		# 够不到时由 _check_stuck 的「够不着就放弃」兜底（会飘字说明原因），
		# 而不是靠走到一个够不到的落脚点来假装到达。
		return false
	# 没有触碰目标的普通移动（去后厨、倒垃圾…）才允许「走到点就算到」
	if global_position.distance_to(_goal_pt) <= ARRIVE_EPS:
		_trace_arrival("走到落脚点")
		return true
	return false


## 到达原因记录（每条指令只记一次）
var _arrival_logged := false


func _trace_arrival(reason: String) -> void:
	if _arrival_logged or not DebugTrace.enabled():
		return
	_arrival_logged = true
	var box := Rect2()
	var d := -1.0
	if _touch_target != null and is_instance_valid(_touch_target) \
			and _touch_target.has_method("touch_box"):
		box = _touch_target.call("touch_box")
		d = global_position.distance_to(EntityBase.nearest_point_on_rect(box, global_position))
	DebugTrace.note_arrival_reason(_desc, reason, global_position, _goal_pt,
		ARRIVE_EPS, box, d, _stuck_clock)


func _check_stuck(delta: float) -> void:
	# 【阈值为什么是 1.5 而不是更小】
	# 一帧正常位移约 4.3px，撞住时接近 0。早先阈值取 0.6 太敏感：
	# 被家具轻轻挤一下（位移 0.8px）就被判成「卡住」，于是频繁重算路径，
	# 路径一变整条路线就成了锯齿 —— 玩家看到的就是「走得歪歪扭扭」。
	# 现在只有位移小到几乎没动才算卡，路径一旦定下就不会被反复改写。
	#
	# 【注】这里管的是「彻底不动 → 放弃」这条最后的兜底。
	# 「擦着椅子磨」由 _blocked_no_progress() 在更早的时刻接住（见 _walk），
	# 两者分工：前者判死，后者救活。
	if _blocked_cooldown > 0.0:
		_blocked_cooldown -= delta

	if global_position.distance_to(_last_pos) < 1.5:
		_stuck_clock += delta
		# 彻底不动时把「没走出去」的计时也一起推进：
		# 这样既使 move_and_slide 完全没产生位移，A 那条判据也照样能触发重算
		_progress_clock = 0.0
		if _try_blocked_repath():
			_stuck_clock = 0.0
			return
		if _stuck_clock >= stuck_timeout:
			cancel_command(Constants.MSG_UNREACHABLE)
			return
	else:
		_stuck_clock = 0.0
		_last_pos = global_position
		# 【预算回收】连续走顺一段时间，就把一次撞住重算还回来。
		# 没有这一步，玩家在一局里多撞几次椅子就会把预算用光，
		# 之后又退回「必须再点一次」的旧行为。
		if not _blocked_no_progress(delta):
			_progress_clock += delta
			if _progress_clock >= BLOCKED_BUDGET_RECOVER:
				_progress_clock = 0.0
				if _blocked_repath_count > 0:
					_blocked_repath_count -= 1


func _finish() -> void:
	DebugTrace.note_finish(_desc, global_position, _goal_pt, _waypoints)
	_active = false
	velocity = Vector2.ZERO
	var cb := _on_arrive
	_on_arrive = Callable()
	arrived.emit()
	if cb.is_valid():
		cb.call()


# ── 收拾桌子（3s，不可取消）─────────────────────────────────────────

## 开始收拾；期间任何新指令都会被拒绝。
##
## 【必须在这里登记「这张桌正在被收拾」】
## 收拾进度只存在服务员身上，桌子自己一直是 DIRTY，而**选座是在更早的时刻
## 用 state 判断的** —— 玩家点下去那一瞬间桌子还是 CLEAN_EMPTY，
## 于是收拾途中的两秒里新客人可以直接落座（玩家实测报的 bug：
## 清洁中客人坐下 → 收拾完成后 finish_clean 又把桌子设回干净 → 状态错乱）。
## 登记之后，选座 / HUD 空桌数统一走 TableRules.is_seatable，都会把它排除掉。
func begin_clean(table: Node, duration: float) -> void:
	cleaning_table = table
	TableRules.set_cleaning(table, true)
	clean_progress = 0.0
	_locked = true
	command_started.emit("收拾 " + str(table.name))


func _advance_cleaning(delta: float) -> void:
	if cleaning_table == null or not is_instance_valid(cleaning_table):
		_end_clean()
		return
	var duration := maxf(0.01, Config.num("clean_time"))
	clean_progress += delta / duration
	if clean_progress >= 1.0:
		clean_progress = 1.0
		if cleaning_table.has_method("finish_clean"):
			cleaning_table.finish_clean()
		_end_clean()


func _end_clean() -> void:
	# 与 begin_clean 的登记配对解除。放在这里而不是 finish_clean 之后，
	# 是为了「中途被打断 / 桌子被释放」这些路径也能解掉，不会留下永久标记
	# （留着的后果是那张桌再也坐不了人 —— 比原 bug 更难查）。
	TableRules.set_cleaning(cleaning_table, false)
	cleaning_table = null
	clean_progress = 0.0
	_locked = false


## 更新手上的餐品（可能多份）。由 ClickRouter 在手上变化时调用。
func set_carried_list(items: Array) -> void:
	carried.clear()
	for it in items:
		carried.append(String(it))
	queue_redraw()


## 兼容旧名：只拿一份
func set_carried(item_id: String) -> void:
	carried.clear()
	if item_id != "":
		carried.append(item_id)
	queue_redraw()


# ── 表现（占位圆形 + 手上餐品方块）─────────────────────────────────

## 餐品标记贴图接口。
##
## 现在全部是代码画的色块。等你有美术素材了，只要给这个字典填上
## 餐品 id → Texture2D，标记就会自动换成贴图，**代码一行都不用改**：
##
##     carried_textures = { "burger": preload("res://art/burger.png") }
##
## 没配到的餐品继续退回「餐品颜色方块」，所以可以一张一张慢慢换。
@export var carried_textures: Dictionary = {}

## 餐品标记的边长（正方形）
const MARKER_SIZE := 18.0
## 标记贴在服务员右上角：中心相对身体中心的偏移
const MARKER_OFFSET := Vector2(15.0, -13.0)
## 第 2 份标记相对第 1 份再偏多少（斜着叠一点，像一摞）
const MARKER_STEP := 13.0


func _draw() -> void:
	# 影子：**有角色贴图时默认不画**（见 draw_shadow 的说明）。
	# 它是按 RADIUS 算的圆（约 30px 宽），而 32×32 的角色贴图人形比画布窄，
	# 于是影子会从贴图的透明边里露出来 —— 看着就是个多余的深色圆。
	if _char == null or draw_shadow:
		# 影子画在身体中心，所以它不会被 AnimatedSprite2D（z_index = -1）盖住
		draw_circle(SHADOW_OFFSET, SHADOW_RADIUS, Color(0, 0, 0, 0.22))

	# 身体占位圆：**只在还没有角色贴图时画**。
	# 【为什么不画】挂了 AnimatedSprite2D 之后，这个灰圆会压在角色贴图上
	# （影子可以压，因为它是半透明的落地阴影；一个实心圆就是画错了）。
	if _char == null:
		draw_circle(Vector2.ZERO, RADIUS, Constants.COLOR_WAITER)
		draw_arc(Vector2.ZERO, RADIUS, 0, TAU, 48, Color("2b3038"), 2.0)

	if not carried.is_empty():
		_draw_carried_markers()

	if cleaning_table != null:
		var w := 46.0
		var h := 7.0
		var org := Vector2(-w * 0.5, -RADIUS - 22)
		draw_rect(Rect2(org, Vector2(w, h)), Constants.COLOR_PROGRESS_BG)
		draw_rect(Rect2(org, Vector2(w * clampf(clean_progress, 0.0, 1.0), h)),
			Constants.COLOR_PROGRESS_FG)


## 右上角的餐品标记：有贴图用贴图，没有就用餐品颜色的正方形。
## 正方形而不是圆形，是为了和「服务员是圆的」区分开 ——
## 玩家扫一眼就知道哪个是「东西」、哪个是「人」。
##
## 【多份怎么画】手上最多 2 份：**左肩一个、右肩一个**（已与用户确认对称摆法）。
## 第 1 份在右肩、第 2 份在左肩，以身体为轴左右对称、等高。
##
## 【朝向会决定哪边是"画的右边"】贴图分 4 套之后，「右肩」只在面朝
## front/right 时才在画面右侧；面朝 left/back 时身体左右已经调过来了。
## 所以这里按 `_facing` 决定镜像，让两个方块**始终贴在身体实际的左右两侧上方**。
func _draw_carried_markers() -> void:
	# 注意：这里的镜像条件要**包含 back**（背对镜头时角色的右手在画面左边），
	# 而 `_apply_facing_visual()` 里的 flip_h 只翻 left/right —— 两者的条件
	# **故意不同**，别顺手合并成一个变量。
	var mirror := _facing == DIR_LEFT or _facing == DIR_BACK
	var first := Vector2(-MARKER_OFFSET.x, MARKER_OFFSET.y) if mirror else MARKER_OFFSET
	if carried.size() >= 1:
		_draw_one_marker(first, carried[0])
	if carried.size() >= 2:
		# 第 2 份：把第 1 份的偏移沿竖直中轴镜像
		_draw_one_marker(Vector2(-first.x, first.y), carried[1])
	# 万一以后容量超过 2，多出来的继续往右上排（不至于不画）
	for i in range(2, carried.size()):
		_draw_one_marker(first + Vector2(MARKER_STEP * float(i - 1), 0.0), carried[i])


func _draw_one_marker(centre: Vector2, item_id: String) -> void:
	var half := MARKER_SIZE * 0.5
	var box := Rect2(centre - Vector2(half, half), Vector2(MARKER_SIZE, MARKER_SIZE))

	# 白底：即使餐品颜色和背景接近，也能看清有个东西在手上
	draw_rect(box.grow(2.0), Color(1, 1, 1, 0.92), true)

	var tex: Texture2D = carried_textures.get(item_id)
	if tex == null:
		tex = ItemArt.texture_for(item_id)
	if tex != null:
		draw_texture_rect(tex, box, false)
	else:
		draw_rect(box, ItemArt.color_for(item_id), true)

	draw_rect(box.grow(2.0), Color("2b3038"), false, 1.5)
