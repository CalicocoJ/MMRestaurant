extends Node2D
## 地板与墙的占位美术。
##
## 单独一个文件是为了让「换美术」这件事有唯一的落点：
## 以后有真素材了，把这个节点的脚本换成一张 Sprite2D 就行，
## level.gd 里只要删掉 add_child 那一行。

const VIEW := Vector2(1280, 720)
const WALL_H := 96.0


func _ready() -> void:
	z_index = -100


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, VIEW), Constants.COLOR_FLOOR, true)
	# 顶部墙
	draw_rect(Rect2(0, 0, VIEW.x, WALL_H), Constants.COLOR_WALL, true)
	draw_line(Vector2(0, WALL_H), Vector2(VIEW.x, WALL_H), Color(0, 0, 0, 0.35), 2.0)

	# 地砖网格
	var step := 80.0
	var x := 0.0
	while x <= VIEW.x:
		draw_line(Vector2(x, WALL_H), Vector2(x, VIEW.y), Color(1, 1, 1, 0.035), 1.0)
		x += step
	var y := WALL_H
	while y <= VIEW.y:
		draw_line(Vector2(0, y), Vector2(VIEW.x, y), Color(1, 1, 1, 0.035), 1.0)
		y += step
