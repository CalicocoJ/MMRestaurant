extends Node
## 比较同一区域在两张 PNG 里的像素均值，用来判断「遮罩有没有盖住这一块」。
##
## 用法：
##   godot --headless --path <project> res://tools/compare_pixels.tscn -- a.png b.png x y w h
##
## 【为什么需要它】
## 弹窗遮罩是 55% 半透明黑，肉眼看截图很容易骗自己：
## 「看起来好像暗了」和「确实被盖住了」是两回事。
## 直接比像素均值，能立刻区分“遮罩没画上去”和“画上去了但对比度不够”。

func _ready() -> void:
	var argv := OS.get_cmdline_user_args()
	if argv.size() < 6:
		print("用法: -- <a.png> <b.png> <x> <y> <w> <h>")
		get_tree().quit(1)
		return

	var a := _load(String(argv[0]))
	var b := _load(String(argv[1]))
	if a == null or b == null:
		print("读图失败")
		get_tree().quit(1)
		return

	var x := int(argv[2])
	var y := int(argv[3])
	var w := int(argv[4])
	var h := int(argv[5])

	var ma := _mean(a, x, y, w, h)
	var mb := _mean(b, x, y, w, h)
	print("区域 (%d,%d) %dx%d" % [x, y, w, h])
	print("  A = %s  亮度均值 %.1f" % [str(ma), (ma.r + ma.g + ma.b) / 3.0 * 255.0])
	print("  B = %s  亮度均值 %.1f" % [str(mb), (mb.r + mb.g + mb.b) / 3.0 * 255.0])
	var ratio := 0.0
	if (ma.r + ma.g + ma.b) > 0.001:
		ratio = (mb.r + mb.g + mb.b) / (ma.r + ma.g + ma.b)
	print("  B/A 亮度比 = %.3f（遮罩 55%% 黑 → 期望约 0.45；≈1.0 说明没盖住）" % ratio)
	get_tree().quit(0)


func _load(path: String) -> Image:
	var img := Image.new()
	if img.load(path) != OK:
		# 试试 res:// 与绝对路径
		var abs_path := ProjectSettings.globalize_path(path)
		if img.load(abs_path) != OK:
			return null
	return img


func _mean(img: Image, x: int, y: int, w: int, h: int) -> Color:
	var sum := Vector3.ZERO
	var n := 0
	for px in range(x, mini(x + w, img.get_width())):
		for py in range(y, mini(y + h, img.get_height())):
			var c := img.get_pixel(px, py)
			sum += Vector3(c.r, c.g, c.b)
			n += 1
	if n == 0:
		return Color(0, 0, 0, 1)
	sum /= float(n)
	return Color(sum.x, sum.y, sum.z, 1.0)
