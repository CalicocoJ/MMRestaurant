extends RefCounted
class_name ItemArt
## 餐品的「图」。**预留贴图接口**：有图用图，没图退回落色块。
##
## 【为什么要有这一层】
## 票上、出餐口、客人手上都要画「这道菜长什么样」。
## 现在全是占位色块，但玩家明确要求：**以后这些小色块要能换成食物 sprite**。
## 所以所有画餐品的地方都统一问这个模块要图，而不是各自去画色块 ——
## 换美术时只放图片，代码一行都不用动。
##
## 【怎么换成真美术】把图片按餐品 id 命名，放进 assets/items/：
##     assets/items/burger.png
##     assets/items/fries.png
##     assets/items/cola.png
## 放进去就自动生效（找不到图就退回 menu.json 里的 color 色块），
## 可以一张一张慢慢换。也支持代码里显式指定：
##     ItemArt.override = { "burger": preload("res://art/burger.png") }

## 图片查找目录
const DIR := "res://assets/items/"

## 显式指定表（优先级高于自动查找）
static var override: Dictionary = {}

## 缓存，避免每帧查文件
static var _cache: Dictionary = {}
static var _miss: Dictionary = {}


## 这道菜有没有贴图
static func has_texture(id: String) -> bool:
	return texture_for(id) != null


## 取贴图；没有则 null
static func texture_for(id: String) -> Texture2D:
	if override.has(id):
		return override[id]
	if _cache.has(id):
		return _cache[id]
	if _miss.has(id):
		return null
	# 约定优于配置：assets/items/<id>.png
	var exts: Array[String] = [".png", ".webp", ".jpg"]
	for ext: String in exts:
		var path: String = DIR + id + ext
		if ResourceLoader.exists(path):
			var tex: Texture2D = load(path)
			if tex != null:
				_cache[id] = tex
				return tex
	_miss[id] = true
	return null


## 这道菜的代表色（没贴图时用它）
static func color_for(id: String) -> Color:
	return Config.item_color(id)


## 在 r 里画这道菜的小图（贴图或色块），供各处的 _draw() 直接调用。
## border 为真时描一圈边，保证在浅色底（票）和深色底（场景）上都看得清。
static func draw_swatch(canvas: CanvasItem, r: Rect2, id: String, border: bool = true) -> void:
	var tex := texture_for(id)
	if tex != null:
		canvas.draw_texture_rect(tex, r, false)
	else:
		canvas.draw_rect(r, color_for(id), true)
	if border:
		canvas.draw_rect(r, Color(0, 0, 0, 0.45), false, 1.0)


## 给 Control（用 ColorRect / TextureRect 的地方，比如后厨 UI 的按钮）做一个图。
## 有贴图就给 TextureRect，没有就给 ColorRect —— 调用方不用管区别。
static func make_node(id: String, box: Vector2) -> Control:
	var tex := texture_for(id)
	if tex != null:
		var tr := TextureRect.new()
		tr.texture = tex
		tr.custom_minimum_size = box
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		return tr
	var cr := ColorRect.new()
	cr.color = color_for(id)
	cr.custom_minimum_size = box
	return cr
