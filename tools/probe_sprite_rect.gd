extends SceneTree
## 实测 Sprite2D.get_rect() 在 centered/scale 不同组合下的返回值。
##
## 目的：确认「贴图视觉左上角」到底在哪个局部坐标，
## 这样柜台食物的节点位置 + rect_size 才能和视觉精确对齐。
##
## `get_rect()` 返回的是**考虑了 texture / centered / offset / scale 之后**
## 精灵在局部坐标里占据的矩形，正是我们要的那个东西。


func _initialize() -> void:
	var tex: Variant = load("res://assets/50sdiner_set_withshadow.png")
	if tex == null:
		print("✗ 大图加载失败")
		quit(1)
		return
	print("大图尺寸 = %s" % str((tex as Texture2D).get_size()))

	# 用一个小区域模拟食物切片
	var at := AtlasTexture.new()
	at.atlas = tex
	at.region = Rect2(273, 416, 15, 14)
	print("切片尺寸 = %s\n" % str(at.get_size()))

	_case(1, at, false, Vector2(0, 0), Vector2(1, 1),   "centered=false scale=1")
	_case(2, at, false, Vector2(0, 0), Vector2(1.3, 1.3), "centered=false scale=1.3")
	_case(3, at, true,  Vector2(0, 0), Vector2(1, 1),   "centered=true  scale=1")
	_case(4, at, true,  Vector2(0, 0), Vector2(1.3, 1.3), "centered=true  scale=1.3")

	print("\n=== 结论 ===")
	print("如果第 1/2 行的 rect.position 都是 (0,0) 且 position+size 随 scale 变化，")
	print("说明：centered=false 时「贴图左上角 = 节点原点」，缩放只让尺寸变大。")
	quit(0)


func _case(n: int, tex: Texture2D, centered: bool, off: Vector2, scl: Vector2, label: String) -> void:
	var sp := Sprite2D.new()
	sp.texture = tex
	sp.centered = centered
	sp.offset = off
	sp.scale = scl
	var r: Rect2 = sp.get_rect()
	print("[%d] %-28s → get_rect() pos=%s size=%s   (右下角=%s)"
		% [n, label, str(r.position), str(r.size), str(r.position + r.size)])
	sp.free()
