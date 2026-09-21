extends RefCounted
class_name TableRules
## 桌子状态与「能不能坐 / 能不能收拾」的纯规则。
##
## 抽出来的理由和 OrderLines 一样：这些判断是文档里最容易互相打架的
## 地方（脏桌算不算空桌？气走的客人留不留脏桌？），放在纯函数里能直接测。


enum State {
	CLEAN_EMPTY, ## 干净且无人 —— 客人可以坐
	DIRTY,       ## 脏且无人 —— 必须先收拾
	OCCUPIED,    ## 有人 —— 不论脏净
}


## 「空桌」= 干净且无人（文档第三节）。
static func is_available(state: int) -> bool:
	return state == State.CLEAN_EMPTY


## 玩家可以点它来收拾吗？
static func is_cleanable(state: int) -> bool:
	return state == State.DIRTY


# ── 「这张桌正在被收拾」──────────────────────────────────────────
##
## 【为什么需要单独记这件事】
## 收拾进度存在**服务员**身上（`waiter.cleaning_table`），桌子自己仍然是 `DIRTY`。
## 于是「这张桌能不能坐人」如果只问 `state`，答案是「不能」（DIRTY 不可坐）；
## 但玩家点下去的**那一瞬间**桌子还是 CLEAN_EMPTY，选座发生在更早的时刻 ——
## 结果是：**清洁途中新客人直接落座了**，然后 `finish_clean()` 又把桌子
## 无条件设回 CLEAN_EMPTY，状态彻底错乱（玩家实测报的 bug）。
##
## 所以「正在被收拾」必须是一个**跨模块可见**的标记，由 waiter 在
## 开始/结束收拾时登记，选座与 HUD 统一读这里，避免各写各的。
static var _cleaning_ids: Dictionary = {}


static func set_cleaning(table: Node, on: bool) -> void:
	if table == null or not is_instance_valid(table):
		return
	var key := table.get_instance_id()
	if on:
		_cleaning_ids[key] = true
	else:
		_cleaning_ids.erase(key)


## 清空整张「正在收拾」登记表。
##
## 【为什么需要】登记只应该由「开始收拾 / 结束收拾」成对维护，但任何一次
## 漏掉解除（异常路径、场景重建）都会让那张桌**永久不可坐**，而且不报错。
## 开一局时是「世界重置」的天然时机 —— 此时不可能有桌子真在处理中，
## 所以在这里无条件清一遍，把可能的残留一次性抹掉。
static func clear_all_cleaning() -> void:
	_cleaning_ids.clear()


static func cleaning_count() -> int:
	return _cleaning_ids.size()


static func is_cleaning(table: Node) -> bool:
	if table == null or not is_instance_valid(table):
		return false
	return _cleaning_ids.has(table.get_instance_id())


## 这张桌现在能安排客人坐吗？
##
## 【唯一入口】选座、HUD 空桌数、生成器全都走这一个判断 ——
## 「正在收拾」和「脏」两种不可坐的原因都在这里收口，
## 以后再加「预订中」这类状态也只需要改这一处。
static func is_seatable(table: Node) -> bool:
	if table == null or not is_instance_valid(table):
		return false
	if is_cleaning(table):
		return false
	return is_available(int(table.get("state")))
