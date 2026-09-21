extends Control
## 订单栏（文档第七节 + 第十四节）。
##
## 每张未结清的订单一张票：
##   桌1：汉堡、可乐         ← 不同菜品
##   桌1：~~汉堡~~、可乐      ← 送掉的部分划红线
##   桌1：汉堡×2             ← 重复菜品合并显示
##   桌1：汉堡×1             ← 送掉一份后减数量
##   全部送完 → 票消失
##
## 【为什么显示逻辑不在这里】
## 「怎么折行、划几条红线」是纯计算，放在 OrderLines 里，
## 这样它能被 headless 测试直接断言，不用真的开一个窗口。

const TICKET_W := 168.0
const PAD := 8.0
const LINE_H := 21.0
const HEAD_H := 22.0

var _tickets: Array = []   ## [{order: Order, table_label: String, y: float}]


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## 每当订单变化时由 HUD 调用
func refresh(orders: Array) -> void:
	_tickets.clear()
	var y := 0.0
	for o in orders:
		_tickets.append({
			"order": o,
			"table_label": "桌%d" % o.table_id,
			"y": y,
		})
		y += HEAD_H + maxf(1.0, float(o.lines().size())) * LINE_H + PAD * 2.0 + 6.0
	custom_minimum_size = Vector2(TICKET_W, maxf(y, 10.0))
	queue_redraw()


func _font() -> Font:
	return UiFont.get_font()


func _draw() -> void:
	var f := _font()
	if f == null:
		return

	for t in _tickets:
		var o: Order = t["order"]
		var y := float(t["y"])
		var lines := o.lines()
		var h := HEAD_H + maxf(1.0, float(lines.size())) * LINE_H + PAD * 2.0

		# 票据底
		draw_rect(Rect2(0, y, TICKET_W, h), Color(0.96, 0.95, 0.90, 0.95), true)
		draw_rect(Rect2(0, y, TICKET_W, h), Color(0, 0, 0, 0.5), false, 1.5)
		# 票头
		draw_rect(Rect2(0, y, TICKET_W, HEAD_H), Color(0.85, 0.83, 0.76), true)
		draw_string(f, Vector2(PAD, y + HEAD_H - 6.0), String(t["table_label"]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("2b2b2b"))

		var ly := y + HEAD_H + PAD - 4.0
		for line in lines:
			var name := String(line["name"])
			var total := int(line["total"])
			var left := int(line["left"])
			var done := bool(line["done"])

			# 文本：重复菜品显示 ×N（剩余份数），不同菜品直接显示名字
			var text := name
			if total > 1:
				text = "%s×%d" % [name, maxi(left, 0)]
			elif done:
				text = name

			var color := Color("2b2b2b")
			if done:
				color = Color("9a9a9a")
			elif total > 1 and left < total:
				color = Color("8a6a20")

			# 菜品小图（有 sprite 用 sprite，没有就是色块 —— 见 ItemArt）。
			# 菜名多了以后光看文字不好扫，前面放个图一眼就能对上。
			var sw := Rect2(PAD, ly + 3.0, 11.0, 11.0)
			ItemArt.draw_swatch(self, sw, String(line["id"]))

			draw_string(f, Vector2(PAD + 16.0, ly + 14.0), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 14, color)

			# 划红线：**只有整道菜全部送完**才划。
			#
			# 【玩家报过的 bug】曾经写成
			#     if done or (total > 1 and left < total)
			# 于是「点 3 杯可乐、只上了 1 杯」也会立刻划掉 ——
			# 把「已经送完」和「送了一部分」混为一谈了。
			# 文档第七节只要求「已送达的菜划红线」，部分送达的正确表现是
			# **减数量**（可乐×3 → 可乐×2），不是划掉。
			if done:
				var size := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14)
				draw_line(Vector2(PAD + 16.0, ly + 9.0), Vector2(PAD + 16.0 + size.x, ly + 9.0),
					Constants.COLOR_STRIKE, 2.0)
			# 还没送完的重复菜品：把剩余份数标出来，比纯文本更醒目
			if not done and total > 1:
				draw_string(f, Vector2(TICKET_W - PAD - 28.0, ly + 14.0), "还差%d" % left,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("8a5a20"))
			ly += LINE_H
