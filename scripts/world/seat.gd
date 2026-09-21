extends RefCounted
class_name Seat
## 一个座位。
##
## 【为什么需要这一层】
## 早先「座位」只是桌子上的一个坐标点 `table.seat_point`，加上桌子级的
## `occupant` / `order`。这带来两个后果：
##   1. 换真实美术时客人是「站着吃饭」—— 根本没有椅子这件东西；
##   2. 想做多座位就必须把订单模型整个推翻（文档第二十节自己写了这条）。
##
## 【订单归属：桌级共享，座位只记「我拿到了什么」】
## 已与用户确认采用**同桌共享订单**：
##   - 一张票 = 同桌所有客人的菜合并（更符合现实：服务员不知道谁点的是哪份）
##   - 耐心是**客人级**的：每个客人各自等、各自气走
##   - 上菜送到桌边，由 Table 自动分配给「还没拿到这道菜」的客人
## 所以 Seat 只记 pos（坐哪）、facing（朝哪）、occupant（谁坐）、
## pending（这个客人自己点的那几样）与 got（他已经拿到了哪几样）。
## 「这桌点了什么」放在 Table.order 上，不在这里。
##
## 【为什么不是 Node】
## 座位要能挡路（椅子是家具）。但做成节点会形成
## Table → Seat → Table 的循环引用（和当年 WorldObject ↔ ClickRouter 同一个坑）。
## 所以座位是可点击物件的**数据**，由 Table 统一负责画椅子和做碰撞盒。

## 座位中心在桌子局部坐标里的位置
var pos: Vector2 = Vector2.ZERO
## 椅子尺寸
var size: Vector2 = Vector2(40, 30)
## 朝向：客人面朝桌子的方向（-1 = 朝右，+1 = 朝左，0 = 朝上/下）
var facing: int = 0

## 坐在这个座位上的客人（null = 空）
var occupant: Node = null
## 这个客人自己点的那几样（用于「谁的菜」的视觉归属）
var pending: Array[String] = []
## 这个客人已经拿到了哪几样（与 pending 等长）
var got: Array[bool] = []


func _init(p_pos: Vector2, p_size: Vector2 = Vector2(40, 30), p_facing: int = 0) -> void:
	pos = p_pos
	size = p_size
	facing = p_facing


## 座位上有没有人
func is_free() -> bool:
	return occupant == null or not is_instance_valid(occupant)


func take(c: Node) -> void:
	occupant = c


func release() -> void:
	occupant = null
	pending = []
	got = []


## 记下这位客人自己要的菜
func set_pending(items: Array[String]) -> void:
	pending = items.duplicate()
	got.resize(pending.size())
	got.fill(false)


## 这个客人还缺这道菜吗
func wants(item_id: String) -> bool:
	for i in pending.size():
		if pending[i] == item_id and not got[i]:
			return true
	return false


## 标记这位客人拿到了这道菜
func mark_got(item_id: String) -> bool:
	for i in pending.size():
		if pending[i] == item_id and not got[i]:
			got[i] = true
			return true
	return false


## 这位客人全拿到了吗（空单视为已齐）
func all_got() -> bool:
	for g in got:
		if not g:
			return false
	return true


func remaining() -> int:
	var n := 0
	for g in got:
		if not g:
			n += 1
	return n


## 椅子矩形（桌子局部坐标）
func chair_rect() -> Rect2:
	return Rect2(pos - size * 0.5, size)


## 客人坐的位置（桌子局部坐标）。
##
## 【为什么只往桌子方向偏 4px，而不是半个椅子】
## 椅子是实体、会挡路，所以服务员最多只能走到椅子**外沿**。
## 如果客人偏向桌子那一侧坐着（原来偏了 10px），
## 从外面量到客人的距离会超过「算碰到」的半径，
## 结果是服务员贴着椅子却永远接不了单 —— 表现为点了客人没反应。
## 让客人基本坐在椅子正中，只朝桌子微偏 4px（看起来仍在面向桌子），
## 外面就够得着了。
func sit_offset() -> Vector2:
	return pos + Vector2(float(-facing) * 4.0, 0.0)
