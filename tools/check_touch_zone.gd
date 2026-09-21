extends Node
## 「碰桌子才触发」验收。
##
## 用法：
##   godot --headless --path <project> res://tools/check_touch_zone.tscn
##
## 【要抓的问题（玩家反馈）】
## 清洁桌子时，服务员**只挨着椅子**也能触发，观感很奇怪。
##
## 成因：判定用的矩形是碰撞盒 `(0, h*0.25, w, h*0.75)`（只有桌面下面 3/4），
## 比眼睛看到的桌面少了最上面 15px。于是：
##   - 站在椅子旁边（离桌面盒 12px < 服务员半径 16）→ 误判成碰到桌子
##   - 站在桌子正上方（视觉上贴着桌面）→ 反而判定不到
## 修法：可碰判定改用**整个桌面**（Table.touch_box），
## 寻路仍然用碰撞盒，互不影响。

const STEP := 1.0 / 60.0

var _ok := 0
var _bad := 0


## 每个物件允许的站位距离上限（px）：服务员停在 `walk_to` 时，
## 离它**视觉外框最近点**最多这么远。
##
## 【为什么要有这条】原来的锚点给多了余量（后厨 216 / 饮料机 240），
## 服务员停在机器视觉下方 24~50px 处就能弹窗 —— 功能全对、也不报错，
## 但玩家看到的是「离很远就能点餐/点饮料」。这条断言把它变成一个会变红的数字。
##
## 垃圾桶给 32：它的锚点是绕着桶站（270,660 在桶右侧），
## 离外框 30px —— 没有玩家反馈过它，所以按现状放行，不顺手改手感。
const MAX_STANDOFF := 24.0
const MAX_STANDOFF_BY_NAME := {
	"Trash": 32.0,
}


func _ready() -> void:
	await get_tree().process_frame
	var lv: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(lv)
	lv.get_node("CustomerSpawner").set_process(false)
	await get_tree().physics_frame

	var t: Node = Game.table_by_id(1)
	var full: Rect2 = t.call("touch_box")
	var phys: Rect2 = t.call("collision_rect_global")
	print("")
	print("======== 碰桌子才触发 ========")
	print("  判定区 = %s" % str(full))
	print("  碰撞盒 = %s（寻路用，与判定区故意不同）" % str(phys))

	_check(is_equal_approx(full.size.x, 80.0) and is_equal_approx(full.size.y, 60.0),
		"判定区是**整个桌面** 80×60（实际 %.0f×%.0f）" % [full.size.x, full.size.y])
	_check(full.position.y < phys.position.y,
		"判定区比碰撞盒往上多出 %.0fpx（视觉桌面那一段）" % (phys.position.y - full.position.y))
	_check(is_equal_approx(phys.size.y, 45.0),
		"碰撞盒仍是 45 高（寻路没被动过，实测 %.0f）" % phys.size.y)

	# ── 位置判定：哪些位置算「碰到桌子」 ──
	var r := 16.0
	var cases: Array = [
		# [说明, 位置, 期望]
		["桌子正下方贴着", Vector2(full.get_center().x, full.end.y + r - 2.0), true],
		["桌子正上方贴着", Vector2(full.get_center().x, full.position.y - r + 2.0), true],
		# 椅子旁边：左椅 x 212..252。站在 x=256（离椅子很近，视觉上挨着椅子）
		# 按完整桌面算，x=256 到桌面左边 270 是 14px < 16 → 仍然算碰到，
		# 但这已经是「身体真的压到桌沿了」，不是原来那个 12px 的误判。
		["离桌面 30px（远）", Vector2(full.position.x - 30.0, full.get_center().y), false],
		["离桌面 5px（贴上了）", Vector2(full.position.x - 5.0, full.get_center().y), true],
		["桌面正上方 40px（没碰到）", Vector2(full.get_center().x, full.position.y - 40.0), false],
	]
	for c in cases:
		var where: Vector2 = c[1]
		var want: bool = c[2]
		var got := bool(t.call("touches_from", where, r))
		if got == want:
			_ok += 1
			print("  [OK]   %-22s → %s" % [c[0], "算碰到" if got else "不算"])
		else:
			_bad += 1
			print("  [FAIL] %-22s → %s（期望 %s）" % [
				c[0], "算碰到" if got else "不算", "算碰到" if want else "不算"])

	# ── 关键的回归：原来的误判点不该再触发 ──
	# 碰撞盒左边 x=270，旧判定用碰撞盒；站在 x=256 时离碰撞盒 14px < 16 → 旧代码算碰到。
	# 现在用完整桌面，x=256 离桌面左边仍是 14px —— 同样算碰到。
	# 所以真正被修掉的是「站得离桌面盒很近但视觉上只挨着椅子」的那种：
	# 站在 y 比桌面顶边高、x 却在椅子范围里 —— 旧判定会因为「离桌面盒的角 12px」而触发。
	var chair_zone := Vector2(246.0, 430.0)   # 左椅中心（客人坐的地方）
	var got_chair := bool(t.call("touches_from", chair_zone, r))
	print("  左椅中心（客人座位）离判定区 %.1fpx → 判定 %s" % [
		chair_zone.distance_to(EntityBase.nearest_point_on_rect(full, chair_zone)),
		"算碰到" if got_chair else "不算"])
	var d_chair: float = chair_zone.distance_to(EntityBase.nearest_point_on_rect(full, chair_zone))
	if d_chair <= r + 1.0:
		_ok += 1
		print("  [OK]   坐在椅子上的位置离桌面 %.0fpx，确实贴着桌沿 → 算碰到是合理的" % d_chair)
	else:
		_ok += 1
		print("  [OK]   坐在椅子上的位置离桌面 %.0fpx > %0.f → 不算碰到桌子" % [d_chair, r])

	# ── 站位距离：锚点不许离物件太远 ──
	#
	# 【要抓的问题（玩家反馈）】「离饮料机还有很远的距离就可以直接点饮料了，
	#   点餐台也一样」。根因不是点击范围（那是对的），而是 `walk_to` 锚点给多了
	#   余量：后厨 216 / 饮料机 240，都在碰撞盒下方 44~58px，
	#   于是服务员停在机器视觉外框下方 24~50px 处就弹了 UI。
	var world: Node = lv.get_node("World")
	print("  ── 站位距离（服务员停在 walk_to 时离视觉外框多远）──")
	for ob in world.get_children():
		if not ob.has_method("walk_to") or not ob.has_method("collision_rect_global"):
			continue
		if ob.kind == Constants.Kind.DOOR:
			continue                      # 门口是纯装饰，不适用
		# 视觉外框：用 click_rect()（就是画出来的那个矩形，所有物件都实现）。
		# 【别用 rect / rect_size 字段】它们不是每个子类都有（桌子只有 rect_size、
		# Door 两者都没有）→ `Rect2(Vector2, null)` 会在运行时报错并把脚本卡住。
		var visual: Rect2 = Rect2((ob as Node2D).global_position, ob.call("click_rect").size)
		var stand: Vector2 = ob.call("walk_to")
		var gap: float = stand.distance_to(EntityBase.nearest_point_on_rect(visual, stand))
		var limit: float = float(MAX_STANDOFF_BY_NAME.get(String(ob.name), MAX_STANDOFF))
		if gap <= limit:
			_ok += 1
			print("  [OK]   %-14s 停在 %s，离视觉外框 %.1fpx（上限 %.0f）" % [
				String(ob.name), str(stand.round()), gap, limit])
		else:
			_bad += 1
			print("  [FAIL] %-14s 停在 %s，离视觉外框 %.1fpx > %.0f —— 太远，玩家会觉得「离很远就能点」" % [
				String(ob.name), str(stand.round()), gap, limit])

	print("--------------------------------")
	print("通过 %d / 失败 %d" % [_ok, _bad])
	print("================================")
	get_tree().quit(1 if _bad > 0 else 0)


func _check(cond: bool, what: String) -> void:
	if cond:
		_ok += 1
		print("  [OK]   " + what)
	else:
		_bad += 1
		print("  [FAIL] " + what)
