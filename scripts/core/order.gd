extends RefCounted
class_name Order
## 一张桌子的订单。
##
## 对应文档第二节的 Order 结构体：
##   table_id / items / delivered / state / patience / patience_max
##
## 【为什么 delivered 用「有序编号」而不是字典计数】
## 文档要求：不同菜显示「汉堡、可乐」，重复菜显示「汉堡×2」；
## 送了一份重复菜要变成「汉堡×1」。
## 用一个等长的 bool 数组逐份标记，两种显示都能算出来，
## 而且天然支持「送一份」这种部分完成。

var table_id: int = 0
var items: Array[String] = []
var delivered: Array[bool] = []


func _init(p_table_id: int, p_items: Array[String]) -> void:
	table_id = p_table_id
	items = p_items.duplicate()
	delivered.resize(items.size())
	delivered.fill(false)


func size() -> int:
	return items.size()


func all_delivered() -> bool:
	for d in delivered:
		if not d:
			return false
	return true


## 手上这份能送给这张桌吗？（该菜品还有没送的那一份）
func wants(item_id: String) -> bool:
	for i in items.size():
		if items[i] == item_id and not delivered[i]:
			return true
	return false


## 标记一份已送达。返回是否成功。
func deliver(item_id: String) -> bool:
	for i in items.size():
		if items[i] == item_id and not delivered[i]:
			delivered[i] = true
			return true
	return false


## 还有几份没送
func remaining_count() -> int:
	var n := 0
	for d in delivered:
		if not d:
			n += 1
	return n


## 总价
func total_price() -> int:
	return Config.total_price(items)


## 订单栏文字。
## 不同菜品 → 「汉堡、可乐」；重复菜品 → 「汉堡×2」。
## 已送达的部分：不同菜品划红线由 UI 负责，这里只给结构化信息。
func lines() -> Array[Dictionary]:
	return OrderLines.build(items, delivered)


## 供 UI 使用的极简文本（不带标记，方便测试断言）。
## 重复菜品要带上「×N」—— 即使只剩 1 份也要带，
## 否则「汉堡×2 → 送一份 → 汉堡」会让玩家以为订单变了。
func plain_text() -> String:
	var parts: PackedStringArray = []
	for line in lines():
		var name := String(line["name"])
		if int(line["total"]) > 1:
			parts.append("%s×%d" % [name, maxi(int(line["left"]), 0)])
		else:
			parts.append(name)
	return "、".join(parts)
