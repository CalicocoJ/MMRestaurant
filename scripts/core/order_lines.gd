extends RefCounted
class_name OrderLines
## 把「订单 items + 送达情况 delivered」折成订单栏要显示的行。
##
## 【它是纯函数，不碰节点】
## 订单栏怎么显示是这份文档里最容易出错、又最值得测试的一段逻辑
## （划红线 / 减数量 / 票什么时候消失），所以单独抽出来，
## 交给 headless 测试直接断言。


## 返回若干行，每行：
##   { id, name, total, delivered, left, done }
## 顺序 = 该菜品第一次出现在订单里的顺序。
##
## 不同菜品：每样一行。
## 重复菜品：合并成一行，total = 份数。
static func build(items: Array, delivered: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var index: Dictionary = {}   # id -> 在 out 里的下标

	for i in items.size():
		var id := String(items[i])
		var got: bool = i < delivered.size() and bool(delivered[i])
		if index.has(id):
			var row: Dictionary = out[int(index[id])]
			row["total"] = int(row["total"]) + 1
			row["delivered"] = int(row["delivered"]) + (1 if got else 0)
		else:
			index[id] = out.size()
			out.append({
				"id": id,
				"name": Config.item_name(id),
				"total": 1,
				"delivered": (1 if got else 0),
			})

	for row in out:
		var total := int(row["total"])
		var got := int(row["delivered"])
		row["left"] = total - got
		row["done"] = got >= total
	return out
