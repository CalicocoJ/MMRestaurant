extends RefCounted
class_name PopupLayout
## 弹窗定位工具（后厨 UI / 饮料机 UI 共用）。
##
## 【为什么不能只写一句 set_anchors_preset(PRESET_CENTER)】
## 这一步只设锚点，真正的矩形要等**容器算出最小尺寸之后**才确定。
## 而 build() 是在 _ready 里跑的，此时子节点的最小尺寸还没算出来 ——
## 于是 PanelContainer 的矩形还是 0 尺寸，grow_* 方向一叠加，
## 面板就被推到了 x = -210（屏幕左侧外面）。
## 它不报错、不警告，只是你永远看不到它。
##
## 正确做法：等容器真正 resize 之后再居中一次，
## 并且每次尺寸变化都重新居中（内容是动态生成的，尺寸会变）。

## 把 panel 在 parent 里水平垂直居中。
## parent 必须是全屏的 Control（通常是弹窗根节点）。
static func center_in_parent(panel: Control, parent: Control) -> void:
	# 容器尺寸确定后会发 resized；同样要防重复连接
	var cb := func() -> void: _place(panel, parent)
	if not panel.resized.is_connected(cb):
		panel.resized.connect(cb)
	# 第一帧还没布局，延后一次做首次居中
	_first_place(panel, parent)


static func _first_place(panel: Control, parent: Control) -> void:
	var tree := panel.get_tree()
	if tree == null:
		return
	await tree.process_frame
	_place(panel, parent)


static func _place(panel: Control, parent: Control) -> void:
	if panel == null or not is_instance_valid(panel):
		return
	if parent == null or not is_instance_valid(parent):
		return
	var psize := _usable_parent_size(parent)
	if psize.x <= 0.0 or psize.y <= 0.0:
		return
	var need := panel.get_combined_minimum_size()
	# 只在尺寸真的变了的时候改，避免 resized -> 改尺寸 -> resized 死循环
	if not panel.size.is_equal_approx(need):
		panel.size = need
	panel.position = ((psize - panel.size) * 0.5).round()


## 找一个有真实尺寸的参照物。
## 【为什么不能直接用 parent.size】
## 弹窗根节点是手动赋 size 的 Control；如果哪一步它还是 0（布局还没跑），
## 居中就会算成 (0,0)，面板被扔到左上角 —— 不报错，就是位置不对。
## 所以这里沿父链往上找第一个有尺寸的祖先，再不行就退回视口尺寸。
static func _usable_parent_size(parent: Control) -> Vector2:
	var node: Node = parent
	var guard := 0
	while node != null and guard < 16:
		guard += 1
		if node is Control:
			var r: Vector2 = (node as Control).size
			if r.x > 0.0 and r.y > 0.0:
				return r
		node = node.get_parent()
	var vp := parent.get_viewport()
	if vp != null:
		var vr := vp.get_visible_rect().size
		if vr.x > 0.0 and vr.y > 0.0:
			return vr
	return Vector2(1280, 720)
