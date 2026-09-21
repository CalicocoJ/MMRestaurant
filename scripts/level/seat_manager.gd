extends Node
class_name SeatManager
## 座位管理器：负责「谁该坐哪」。
##
## 【为什么单独一个脚本，而不是写在 Table 或 Customer 里】
##   1. 座位是**跨桌**的资源：选座要看全店（哪张桌空、哪张桌已经有人），
##      放在单张桌子里就必然要反过来遍历其他桌子；
##   2. 生成客人、判断空桌、HUD 统计空位，全都要问「有没有空位」；
##   3. 以后要扩到每桌 4 座、或者加「吧台位」这种非桌座位，
##      改的只有这一个文件。
##
## 【选座策略：先坐满空桌，再拼桌】
## 优先级是「这张桌一个人都没有」优先于「已经有人的桌」——
## 这样客人会先把空桌占掉，而不是两张桌各坐一个、剩下两张全空。
## 好处是玩家面对的待收拾桌更集中，压力曲线也更可预期。
## 同一优先级内按桌号、座位号排序，保证结果稳定可测（不依赖字典顺序）。


## 所有「可以坐」的座位：[{table, seat, seat_index}]，已按优先级排序
static func seats_for_arrival(allow_share: bool = false) -> Array:
	var empty_tables: Array = []   ## 一个客人都没有、而且没挂订单的桌
	var busy_tables: Array = []    ## 已经有人（或已挂单）的桌

	for t in Game.tables:
		# 【必须用 is_seatable 而不是 is_available(t.state)】
		# 只问 state 会漏掉「正在被收拾」的桌子 —— 那张桌从玩家点下去到
		# 收拾完的这几秒里，state 已经不是 DIRTY，客人会直接落座（实测 bug）。
		if not TableRules.is_seatable(t):
			continue
		if t.order != null:
			continue          # 桌上还有未结的共享订单，不要再塞人
		var free: Array = t.free_seats()
		if free.is_empty():
			continue
		var has_customer: bool = t.seat_count() > free.size()
		if has_customer:
			if allow_share:
				busy_tables.append(t)
		else:
			empty_tables.append(t)

	var out: Array = []
	for group in [empty_tables, busy_tables]:
		for t in group:
			for s in t.free_seats():
				out.append({"table": t, "seat": s, "seat_index": t.seats.find(s)})
	return out


## 全店空位数（HUD 用）
static func free_seat_count() -> int:
	var n := 0
	for t in Game.tables:
		if TableRules.is_seatable(t):
			n += t.free_seats().size()
	return n


## 还有空位吗
static func has_free_seat() -> bool:
	return not seats_for_arrival().is_empty()


## 挑一个座位。返回 {table, seat, seat_index} 或空字典。
static func pick_seat(allow_share: bool = false) -> Dictionary:
	var options := seats_for_arrival(allow_share)
	if options.is_empty():
		return {}
	return options[0]


# ── 按「一组客人」分配（一组 1~2 人，整组必须同一张桌）────────────

## 给 n 人组找一张能容纳整组的桌子。
## 返回 {table, seats: Array, seat_indices: Array}，找不到返回 {}。
##
## 【为什么整组必须同桌、而且不拆】
## 已与用户确认：现实中一起来的客人不会分开坐两张桌子。
## 拆开还会把「一组一张共享订单」这个语义搞坏 —— 那两个人会变成两桌两票。
## 所以宁可让他们在门口等（耐心照掉、会气走），也不拆。
static func pick_group(n: int) -> Dictionary:
	if n <= 0:
		return {}
	for group in [_empty_tables(), _crowded_tables()]:
		for t in group:
			var free: Array = t.free_seats()
			if free.size() < n:
				continue
			var taken: Array = []
			var idx: Array = []
			for i in n:
				taken.append(free[i])
				idx.append(t.seats.find(free[i]))
			return {"table": t, "seats": taken, "seat_indices": idx}
	return {}


## 一张客人都没有、且没挂订单的桌（优先安排整组坐这种）
static func _empty_tables() -> Array:
	var out: Array = []
	for t in Game.tables:
		if not TableRules.is_seatable(t):
			continue
		if t.order != null:
			continue
		if t.occupied_seats().is_empty():
			out.append(t)
	return out


## 已经有人、但还有空位的桌（只有空桌塞不下整组时才会用到）
static func _crowded_tables() -> Array:
	var out: Array = []
	for t in Game.tables:
		if not TableRules.is_seatable(t):
			continue
		if t.order != null:
			continue
		if not t.occupied_seats().is_empty() and not t.free_seats().is_empty():
			out.append(t)
	return out


## 现在能坐下 n 人组吗
static func can_seat_group(n: int) -> bool:
	return not pick_group(n).is_empty()
