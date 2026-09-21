extends Node
## 走路调试记录（autoload 名 = DebugTrace）。
##
## 【怎么用】
## 在工程目录建一个空文件：
##     C:\DS\restaurant-v2\DEBUG_WALK
## 然后正常进游戏点几下（尤其是你说会出斜线的那种「靠近桌椅」的点击），
## 控制台就会打印每次寻路的结果和实际经过的点。
## 把我打印出来的内容发我就行。删掉那个文件即可关闭。
##
## 【为什么用「文件是否存在」当开关，而不是快捷键或改代码】
## 快捷方式要改代码、要记按键；而这个开关不改任何逻辑、不改手感，
## 你放个文件就开、删掉就关，我也能保证关掉时零开销。

const MARKER := "res://DEBUG_WALK"

var _on := false


func _ready() -> void:
	_on = FileAccess.file_exists(MARKER)
	if _on:
		print("[DebugTrace] 走路调试已开启（删除 %s 可关闭）" % MARKER)


func enabled() -> bool:
	return _on


## 服务员每次算出路径时调用
func note_path(desc: String, from: Vector2, goal: Vector2, raw: Array, final: Array) -> void:
	if not _on:
		return
	print("[walk] %s" % desc)
	print("       起点 %s → 落脚点 %s" % [_v(from), _v(goal)])
	print("       A*原始 %d 点: %s" % [raw.size(), _pts(raw)])
	print("       整理后 %d 点: %s" % [final.size(), _pts(final)])
	# 标出哪一段是斜的（本不该出现）
	for i in range(1, final.size()):
		var a: Vector2 = final[i - 1]
		var b: Vector2 = final[i]
		var dx: float = absf(a.x - b.x)
		var dy: float = absf(a.y - b.y)
		if dx > 1.0 and dy > 1.0:
			print("       !! 斜线段：%s → %s（横 %.1f 竖 %.1f）" % [_v(a), _v(b), dx, dy])


## 一步走完时调用，记录实际经过的轨迹（每 10 帧一个采样）
func note_step(pos: Vector2) -> void:
	if not _on:
		return
	print("       · %s" % _v(pos))


func note_done(desc: String, pos: Vector2) -> void:
	if not _on:
		return
	print("[walk] %s 结束于 %s" % [desc, _v(pos)])


func _v(p: Vector2) -> String:
	return "(%.0f,%.0f)" % [p.x, p.y]


## 客人踩到桌面时的现场记录（只报一次每人，避免刷屏）
var _reported: Dictionary = {}


func note_intrusion(c: Node, table_label: String, pos: Vector2,
		waypoints: Array, seat_target: Vector2, table: Node) -> void:
	if not _on:
		return
	var key := c.get_instance_id()
	if _reported.has(key):
		return
	_reported[key] = true
	print("[customer] **踩到桌面** %s @ %s" % [table_label, _v(pos)])
	print("           座位目标 %s" % _v(seat_target))
	print("           剩余拐点 %s" % _pts(waypoints))
	if table != null and is_instance_valid(table):
		var shapes: Array = table.call("collision_shapes_global")
		if not shapes.is_empty():
			print("           该桌桌面矩形 %s" % str(shapes[0]))


## 记录「这次算到达」的原因 + 卡住累计时长。
##
## 【为什么要卡住时长】玩家反馈「撞上椅子卡了 1 秒才绕开」。
## 卡住多久只能实测，所以这里把本次指令累计卡住的时间一并打出来。
func note_arrival_reason(desc: String, reason: String, pos: Vector2, goal: Vector2,
		eps: float, box: Rect2, dist_to_box: float, stuck_sec: float) -> void:
	if not _on:
		return
	print("[arrive] %s → 因为「%s」算到达" % [desc, reason])
	print("         位置 %s  落脚点 %s（相距 %.1f / 阈值 %.1f）" % [
		_v(pos), _v(goal), pos.distance_to(goal), eps])
	if box.size.x > 0.0:
		print("         判定区 %s  实际离它 %.1f（<=%.0f 才算碰到）" % [
			str(box), dist_to_box, 17.0])
	print("         本次指令累计卡住 %.2f 秒" % stuck_sec)


## 记录一条新指令是否被接受
func note_cmd(msg: String) -> void:
	if not _on:
		return
	print("[cmd] %s" % msg)


## 记录一次「指令结束」
func note_finish(desc: String, pos: Vector2, goal: Vector2, wps: Array) -> void:
	if not _on:
		return
	print("[finish] %s  位置 %s  落脚点 %s（相距 %.1f）  剩余拐点 %s" % [
		desc, _v(pos), _v(goal), pos.distance_to(goal), _pts(wps)])


func note_retarget(desc: String, goal: Vector2, box: Rect2) -> void:
	if not _on:
		return
	print("[retarget] %s：原落脚点够不到目标，改到 %s（判定区 %s）" % [
		desc, _v(goal), str(box)])


func note_retarget_fail(desc: String, box: Rect2, touch_cands: int, path_ok: int,
		reason: String) -> void:
	if not _on:
		return
	print("[retarget] %s：**没找到**能碰到目标的落脚点" % desc)
	print("           判定区 %s" % str(box))
	print("           身体能碰到目标的候选取点 %d 个，其中 A* 能走到的 %d 个" % [
		touch_cands, path_ok])
	if reason != "":
		print("           最后一次失败原因：%s" % reason)


func _pts(arr: Array) -> String:
	var parts: PackedStringArray = []
	for p in arr:
		parts.append(_v(p))
	return " → ".join(parts) if parts.size() > 0 else "(空！未走寻路，退回直线)"


## 记录「清洁开始时」的现场。
##
## 【为什么要在动作真正执行的那一刻抓】
## 玩家两次反馈「站在椅子旁边也能清洁」。我按代码算判定区是整个桌面、
## 椅子离它 24px，怎么都不该触发 —— 测量和现象冲突，说明我对
## 哪条判据让它通过的判断有盲点。
## 这条日志把「动作执行瞬间」的坐标、判定区、两条判据的结果全打出来，
## 玩一次就能定论，不用再推断。
func note_clean_start(table: Node, waiter: Node) -> void:
	if not _on:
		return
	if table == null or waiter == null or not is_instance_valid(waiter):
		return
	var tname := String(table.name)
	var pos: Vector2 = waiter.global_position
	var box: Rect2 = table.call("touch_box")
	var phys: Rect2 = table.call("collision_rect_global")
	var d_box: float = pos.distance_to(EntityBase.nearest_point_on_rect(box, pos))
	var d_phys: float = pos.distance_to(EntityBase.nearest_point_on_rect(phys, pos))
	print("========== 清洁开始：%s ==========" % tname)
	print("  服务员位置 %s" % _v(pos))
	print("  可碰区(整个桌面) %s  → 距离 %.1f  碰到? %s（阈值 身体半径16+1）" % [
		str(box), d_box, str(d_box <= 17.0)])
	print("  碰撞盒(寻路用)   %s  → 距离 %.1f" % [str(phys), d_phys])
	print("  落脚点 %s   与当前位置相距 %.1f" % [
		_v(waiter.get("_goal_pt")), pos.distance_to(waiter.get("_goal_pt"))])
	print("  → 结论：这次算到达是因为 **%s**" % (
		"碰到了桌子" if d_box <= 17.0 else "走到了落脚点（注意：这一条不看是否碰到桌子）"))
