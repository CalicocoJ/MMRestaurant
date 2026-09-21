extends Control
## 一颗五角星（结算界面的星级用）。
##
## 【为什么不直接画在结算面板的 _draw 里】
## 抽成独立控件有三个好处：
##   ① 位置交给容器（HBoxContainer）排，不用手算 N 颗星的间距；
##   ② 「亮/暗」变成 `lit` 一个属性，面板那边只写 `star.lit = i < n`；
##   ③ 以后想换成贴图（美术替换阶段）只改这一个文件。
##
## 【为什么用多边形画而不是字符 ★】
## 项目里所有画面都是代码画的（矩形 / 圆），没有贴图资源；
## 而 ★/☆ 依赖字体 —— 这个工程的默认字体连汉字都要回退到系统 CJK 字体，
## 用字符风险太大（可能变成方块或大小不一）。多边形则完全可控。
##
## 【为什么留描边】深色背景上，白色（未获得）的星星如果没有描边，
## 会糊成一团分不出形状；描边让"空心"读起来清楚。

## 亮 = 已获得的星（金黄实心）；暗 = 未获得的星（只有白色描边）
var lit: bool = false:
	set(v):
		lit = v
		queue_redraw()

## 单颗星的外接尺寸
const SIZE := 34.0
## 内外半径比。0.42 是常见比例，星角够尖、中心又不会太瘦
const INNER_RATIO := 0.42

const COLOR_LIT := Constants.COLOR_MONEY       ## 复用"钱"的金黄，风格统一
const COLOR_DIM := Color(1, 1, 1, 0.85)


func _init() -> void:
	custom_minimum_size = Vector2(SIZE, SIZE)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## 五角星的 10 个顶点（外角 / 内角交替）。
##
## 【为什么要从 -90° 起算】角度 0° 在 Godot 里是"正右方"，
## 直接用它画出来的星星是**歪的**（一个尖朝右）。从 -90°（正上方）起算，
## 第一个顶点落在正上方，星星才是"一个尖朝上"的正常样子。
static func star_points(centre: Vector2, radius: float, inner_ratio: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 10:
		var r := radius if i % 2 == 0 else radius * inner_ratio
		var a := -PI * 0.5 + PI * float(i) / 5.0
		pts.append(centre + Vector2(cos(a), sin(a)) * r)
	return pts


func _draw() -> void:
	var centre := size * 0.5
	var radius := minf(size.x, size.y) * 0.5 - 1.0
	var pts := star_points(centre, radius, INNER_RATIO)
	if lit:
		draw_colored_polygon(pts, COLOR_LIT)
		# 描一圈深色边，避免金黄在浅色背景上糊掉
		var outline := pts.duplicate()
		outline.append(pts[0])
		draw_polyline(outline, Color(0, 0, 0, 0.45), 1.5, true)
	else:
		# 未获得：只画白色描边（空心）
		var ring := pts.duplicate()
		ring.append(pts[0])
		draw_polyline(ring, COLOR_DIM, 2.0, true)
