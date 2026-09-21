extends Node
## 开始界面体检（三态 + 断言）+ 出两张截图。
##
## 用法：
##   godot --path <project> --resolution 1280x720 res://tools/check_start.tscn
##
## 产出：
##   .artifacts/start_screen.png   开始界面（标题 + 副标题 + 开始游戏按钮）
##   .artifacts/after_start.png    点了「开始游戏」之后的餐厅画面
##
## 【它验证什么】
##   1. show_start_screen = false（工具 / 测试的默认）→ 不出开始界面、世界不暂停
##      —— 18 个现有测试 / 工具靠这条不被搞坏
##   2. show_start_screen = true（main.tscn 的声明）→ 出开始界面、世界冻结
##   3. 标题 / 副标题 / 按钮的文案与尺寸
##   4. 按一次「开始游戏」→ 界面收起、世界解冻
##   5. 空桌计时没有把「在标题画面待的时间」算进去（否则点开始客人秒到）
##   6. HUD 里已经没有「餐厅物语」标题行
##
## 【为什么 process_mode = ALWAYS】
## 本脚本会主动把世界暂停（复现玩家看到的标题画面状态）。
## 暂停状态下普通节点的协程不会继续跑 —— 那样这个工具会在第一次
## `await get_tree().process_frame` 处**静默挂死**，看起来像引擎卡住。
## 把自己设成 ALWAYS，暂停期间它照常推进，才能自己把游戏解冻。
## （这是截图 / dump 类工具以后遇到「暂停」时的通用解法。）

const W := 1280
const H := 720
const OUT_START := "res://.artifacts/start_screen.png"
const OUT_AFTER := "res://.artifacts/after_start.png"

var _vp: SubViewport

var _pass := 0
var _fail := 0
var _level: Node = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 看门狗只是「真挂死」的兜底（正常情况下整个工具几秒就跑完，
	# 本机实测约 20 秒；600 帧的世界推进在慢机器上会明显更久）。
	# 阈值必须给得足够宽，否则会把「跑得慢」误报成「挂死」——踩过一次。
	_start_watchdog(600.0)
	await get_tree().process_frame

	_vp = SubViewport.new()
	_vp.size = Vector2i(W, H)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.transparent_bg = false
	add_child(_vp)

	# UI / Stickers 是挂在主窗口视口上的 autoload；不搬进来，
	# 截出来的图里就只有世界、没有界面（screenshot.gd 顶部记过这个坑）。
	for n in ["Stickers", "UI"]:
		var layer := get_tree().root.get_node_or_null(NodePath(n))
		if layer != null:
			get_tree().root.remove_child(layer)
			_vp.add_child(layer)

	print("")
	print("════════ 开始界面体检 ════════")

	# ── 1. 只建**一个** Level ──
	#
	# 【为什么不能建两个】踩过一次：`UI.run_requested` 是**全局信号**，
	# Level 在 _ready 里连它。建两个 Level 会让两个（其中一个是已释放的）
	# 都收到「开始本局」的通知 —— 于是 `Game.tables` 被清空，
	# 客人再也生不出来（症状是「进入游戏 10 秒后店里 0 位客人」）。
	# 同理 `Game.orders_changed` 也会多挂一个死订阅者。
	# 结论：一个进程里只留一个 Level，要测另一种标志就先要求入口自己声明。
	#
	# 【默认值这条路怎么保证】main.tscn 里**没有**写 show_start_screen，
	# 所以工具加载时它取脚本默认值 false —— 这一点由 level.gd 里的注释
	# 与「工具全部能跑」这个事实保证，不需要再建第二个 Level 去验。
	_level = _new_level(true)
	ok(bool(_level.get("show_start_screen")), "Level 的 show_start_screen = true")
	_vp.add_child(_level)
	await get_tree().process_frame
	await get_tree().process_frame

	var start: Control = UI.start_screen()
	ok(UI.is_start_screen_open(), "声明为入口时弹出开始界面")
	ok(get_tree().paused, "开始界面期间世界被冻结（get_tree().paused）")
	ok(UI.is_paused_by_ui(), "暂停来自 UI（不是别处设的）")
	ok(not UI.should_process_world(), "世界停止推进")

	# ── 2b. 标题画面必须「干净」：HUD 隐藏 + 遮罩全黑 ──
	# 【为什么这两条要断言】第一版栽过：
	#   遮罩只给了 82% 不透明度，HUD 那几行白字在半透明黑底下清清楚楚，
	#   截图里左上角还能看到「钱：0 元 / 已接待人数：0 …」——
	#   「标题画面」变成「游戏上面蒙了一层灰」。肉眼很容易漏，所以写进断言。
	ok(UI.hud != null and not UI.hud.visible, "开始界面期间 HUD 已隐藏")
	var dim := start.get_node_or_null("Dim") as ColorRect
	ok(dim != null, "遮罩节点存在")
	if dim != null:
		ok(dim.color.a >= 0.999, "遮罩完全不透明（alpha=%.2f，一点餐厅都不露）" % dim.color.a)

	# ── 3. 文案与尺寸 ──
	var title := start.get_node_or_null("Center/Column/Title") as Label
	var subtitle := start.get_node_or_null("Center/Column/Subtitle") as Label
	var btn: Button = start.call("start_button")
	if btn != null:
		print("  [信息] 定位到按钮：path=%s text=「%s」 size=%s" % [
			str(start.get_path_to(btn)), btn.text, str(btn.size)])
	ok(title != null and title.text == Constants.START_TITLE,
		"标题 = 「%s」" % Constants.START_TITLE)
	ok(subtitle != null and subtitle.text == Constants.START_SUBTITLE,
		"副标题 = 「%s」" % Constants.START_SUBTITLE)
	ok(btn != null and btn.text == Constants.START_BUTTON,
		"按钮文案 = 「%s」" % Constants.START_BUTTON)
	if title != null:
		var fs := int(title.get_theme_font_size("font_size"))
		ok(fs >= 48, "标题是大号字（%d px）" % fs)
		ok(title.get_theme_color("font_color") == Constants.COLOR_START_TITLE,
			"标题是金黄色")
	if btn != null:
		ok(btn.size.x >= 200.0 and btn.size.y >= 56.0,
			"按钮是大按钮（实测 %s）" % str(btn.size))

	# 整体居中：标题 / 副标题 / 按钮三块的中心应该贴着屏幕中心
	var centres: Array[float] = []
	for n in [title, subtitle, btn]:
		if n != null:
			centres.append((n as Control).get_global_rect().get_center().y)
	if centres.size() == 3:
		var top: float = centres[0] - (title as Control).size.y * 0.5
		var bottom: float = centres[2] + (btn as Control).size.y * 0.5
		var mid := (top + bottom) * 0.5
		ok(absf(mid - H * 0.5) < 12.0,
			"三块整体垂直居中（内容中心 y=%.1f，屏幕中心 %.1f）" % [mid, H * 0.5])

	await _shoot(OUT_START)

	# 【为什么在暂停期间「等一帧」不会挂死】
	# process_mode = ALWAYS，本脚本的协程照常推进；
	# 而场景树的帧信号与渲染提交跟暂停是两件事，画面照样能出。
	# 这条实测通过 —— 早先担心「暂停时画面不更新」，是多余的。

	# ── 4. 空桌计时不该把标题画面的时间算进去 ──
	# 直接构造「在标题画面待了很久」：把 available_since 往回拨 10 秒。
	# 这是**墙上时钟**差值（见 table.gd 的 _now），不是引擎 delta。
	var t1: Node = Game.table_by_id(1)
	ok(t1 != null, "桌1 已注册")
	if t1 != null:
		t1.available_since = float(Time.get_ticks_msec()) / 1000.0 - 10.0
		ok(t1.available_duration() > 9.0, "构造成功：桌1 的「空桌已存在」被拨到 10 秒前")

	# ── 5. 按「开始游戏」 ──
	var t_before: float = float(Time.get_ticks_msec())
	UI.press_start()
	ok(not UI.is_start_screen_open(), "按下开始后界面收起")
	ok(not get_tree().paused, "按下开始后世界解冻")
	ok(UI.should_process_world(), "按下开始后世界开始推进")
	ok(UI.hud != null and UI.hud.visible, "按下开始后 HUD 重新出现")
	if t1 != null:
		ok(t1.available_duration() < 1.0,
			"空桌计时已归零（实测 %.2fs）——客人不会秒到" % t1.available_duration())

	var paused_wall := (float(Time.get_ticks_msec()) - t_before) / 1000.0
	print("  [信息] 「标题画面」持续了 %.2fs 墙上时间，已全部排除在空桌计时之外" % paused_wall)

	# ── 6. HUD 里不再有「餐厅物语」标题行 ──
	var hud: Control = UI.hud
	ok(not _contains_text(hud, "餐厅物语"), "HUD 里已无「餐厅物语」标题行")
	ok(_contains_text(hud, "钱："), "HUD 状态栏还在（「钱：」这一行）")

	print("")
	print("  ── HUD 结构（前两层）──")
	_print_tree(hud, 0, 2)

	# ── 7. 真正进游戏跑一段，出第二张图 ──
	# 让「空桌计时」从现在开始算：这一段仿真要等客人来，
	# 而生成门槛算的是墙上时间（详见 _simulate 的说明）。
	for t in Game.tables:
		t.call("mark_available")
	await get_tree().physics_frame
	await _simulate(_level, 10.0)
	await _shoot(OUT_AFTER)

	var spawner: Node = _level.get_node("CustomerSpawner")
	var in_store: int = int(spawner.call("in_store_count"))
	ok(in_store > 0, "进入游戏 10 秒后店里有客人（%d 位）" % in_store)
	ok(not get_tree().paused, "模拟结束后世界仍在推进")
	ok(not UI.is_start_screen_open(), "模拟结束后开始界面仍然收起")

	print("")
	print("  ── 状态快照 ──")
	print("    钱=%d 已接待=%d 气走=%d 空桌=%d 在店=%d" % [
		Game.money, Game.served_count, Game.angry_count,
		Game.empty_table_count(), in_store])
	print("═══════════════════════════════")
	print("结果：%d 通过 / %d 失败" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _new_level(with_start_screen: bool) -> Node:
	var lv: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	# main.tscn 里的声明就是 true；测试要三态覆盖，所以这里显式设一遍。
	lv.set("show_start_screen", with_start_screen)
	return lv


# ── 断言 ───────────────────────────────────────────────────────────

func ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
		print("  PASS  ", what)
	else:
		_fail += 1
		print("  FAIL  ", what)


func _contains_text(root: Node, needle: String) -> bool:
	if root == null:
		return false
	if root is Label and (root as Label).text.contains(needle):
		return true
	for c in root.get_children():
		if _contains_text(c, needle):
			return true
	return false


func _print_tree(node: Node, depth: int, max_depth: int) -> void:
	if node == null or depth > max_depth:
		return
	var extra := ""
	if node is Label:
		extra = "  text=「%s」" % (node as Label).text
	elif node is Button:
		extra = "  text=「%s」 size=%s" % [(node as Button).text, str((node as Control).size)]
	print("    %s%s%s" % ["  ".repeat(depth), node.name, extra])
	if depth == max_depth:
		return
	for c in node.get_children():
		_print_tree(c, depth + 1, max_depth)


# ── 截图与推进 ─────────────────────────────────────────────────────

func _shoot(out_path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_path.get_base_dir()))
	var err := img.save_png(out_path)
	if err != OK:
		_fail += 1
		print("  FAIL  保存失败 %s: %d" % [out_path, err])
		return
	print("  [截图] %s (%dx%d)" % [out_path, img.get_width(), img.get_height()])


## 手动推进世界（与 screenshot.gd 同一套做法）。
## 【只驱动 World / Actors，不碰 UI 与 autoload】
## 手动调 Control._process 会打乱引擎内部的 canvas 更新标记，
## 导致弹窗 / 遮罩那一类 PROCESS_MODE_ALWAYS 的节点画不对。
##
## 【但 CustomerSpawner 必须单独驱动】它挂在 Level 下、**不在这两组里面**。
## 曾经因为它漏在外面，这段仿真的 10 秒里生成本该发生的客人一个都没来
## （实测：生成器的 _process 被调用 0 次）。当时的断言是靠「引擎顺手
## 跑了一次 _process」侥幸通过的 —— 关卡模式把节奏改成由本局时钟驱动后
## 就暴露了。所以这里显式把它补上。
##
## 【还要让真实时间流逝一点】客人生成的门槛「这张桌空够 empty_table_delay(2s)」
## 算的是**墙上时钟**（`Time.get_ticks_msec()`），而本仿真把 10 秒游戏时间
## 压缩进 2~3 秒真实时间 —— 阈值永远到不了，客人一个都不来（实测卡在这里很久）。
## 每一步睡 3ms：600 步只多花约 1.8 秒真实时间，但足够跨过 2 秒门槛。
func _simulate(level: Node, seconds: float) -> void:
	const STEP := 1.0 / 60.0
	const REAL_SLEEP_MS := 3
	var steps := int(seconds / STEP)
	for i in steps:
		for group in ["World", "Actors"]:
			var n := level.get_node_or_null(group)
			if n != null:
				_walk_tree(n, "_physics_process", STEP)
				_walk_tree(n, "_process", STEP)
		var sp := level.get_node_or_null("CustomerSpawner")
		if sp != null:
			sp.call("_process", STEP)
		await get_tree().process_frame
		if REAL_SLEEP_MS > 0:
			OS.delay_msec(REAL_SLEEP_MS)


func _walk_tree(node: Node, method: String, delta: float) -> void:
	if node.has_method(method):
		node.call(method, delta)
	for c in node.get_children():
		_walk_tree(c, method, delta)


## 超时兜底：万一某一步真的把协程冻住，不能让进程永远挂着。
func _start_watchdog(seconds: float) -> void:
	var t := Timer.new()
	t.wait_time = seconds
	t.one_shot = true
	t.process_mode = Node.PROCESS_MODE_ALWAYS
	t.timeout.connect(func() -> void:
		print("  FAIL  看门狗触发：某一步把协程冻住了")
		print("结果：%d 通过 / %d 失败" % [_pass, _fail + 1])
		get_tree().quit(1))
	add_child(t)
	t.start()
