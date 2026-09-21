extends Node
class_name Pathfinder
## 网格 A* 寻路。
##
## 【为什么是 Node 而不是 RefCounted】
## 它要挂进场景树、被服务员用 `get_first_node_in_group("pathfinder")` 找到。
## 踩过的坑：`extends RefCounted` 的脚本用 set_script() 挂到 Node 上会**静默失败**
## （基类不兼容），于是方法全都不存在、寻路完全没生效 ——
## 而报错信息只是 "Nonexistent function 'find_path' in base 'Node'"，
## 看上去像调用写错了，实际是类型不匹配。
##
## 【为什么必须有它】
## 服务员原本是**直线移动**：朝目标一直走，撞上东西就顶着。
## 座位分散到桌子两侧以后，「从右边去桌子左边的座位」这种路线必然被桌子挡住，
## 顶着不动直到卡住看门狗取消 —— 玩家看到的是「点了客人完全没反应」。
## 全局扫描实测：48 条路线里 8~9 条走不到。
##
## 【为什么不用 Godot 的 NavigationRegion2D】
## 已与用户确认选网格 A*。判断依据是**可测性和可调试性**：
##   - 这个网格是纯数据，可以在无头测试里直接断言「A 到 B 有没有路」；
##     导航网格必须跑引擎导航系统，只能间接试走。
##   - 家具变化时重建网格即可；导航网格要重新烘焙，时序问题很隐蔽。
##   - 这个项目已经反复被「隐式几何导致走不到」咬过（坑 1/2/8），
##     所以要的是**显式、可打印、可断言**的几何，而不是更隐式的。
##
## 【代价与取舍】
## 格子固定 20px。餐厅 1280×720 → 64×36 格，很小的数组，
## 每次寻路都是毫秒级。格子太粗会贴着家具边卡住，太细则数组变大；
## 20px 介于服务员半径(16)和家具尺寸(40~240)之间，够用。

const CELL := 20.0
const VIEW := Vector2(1280, 720)

## 障碍网格：1 = 不可通行
var _blocked: PackedByteArray = PackedByteArray()
## 客人用的网格（外扩更小，见 build 里的说明）
var _blocked2: PackedByteArray = PackedByteArray()
## 客人网格的外扩量
const CUSTOMER_INFLATE := 8.0
var _cols: int = 0
var _rows: int = 0


## 按世界里所有家具（含椅子）的碰撞盒重建障碍网格。
##
## inflate = 额外外扩多少。**这个值必须小**，只用来补偿「格子是方的」这点误差。
##
## 【为什么不能把服务员半径(16)整个算进去】
## 一开始我传了 46（服务员半径 + 余量），结果是 A* **把本来走得通的走廊
## 判成堵死**：椅子与屏幕边只留 30px，服务员圆心其实能过，
## 但网格按「圆心必须离障碍 46px」来算就无路可走，于是退回直线 + 卡住。
## 网格只负责给出「大致绕行折线」，贴边的微调交给 move_and_slide
## （它本来就会把人从家具里推出来）。所以外扩取半个格子即可。
func build(obstacles: Array, inflate: float = 6.0) -> void:
	_cols = int(ceil(VIEW.x / CELL))
	_rows = int(ceil(VIEW.y / CELL))
	# ① 服务员用的网格（外扩 ≥ 他的身体半径）
	_blocked = _make_grid(obstacles, inflate)
	# ② 客人用的网格（外扩小一些）
	#
	# 【为什么客人要单独一份】
	# 服务员的外扩是 18px，会把**椅子所在的格子也封死**。
	# 于是「走到座位」这个目标点对客人来说落在障碍里，
	# A* 只能把它吸附到旁边 —— 客人永远走不到自己座位。
	# 客人半径 15px，本来就该坐在椅子上（和椅子重叠是正常的），
	# 用 8px 外扩：椅子那格可达，**桌子那几格仍然封着**，
	# 而「不能从桌子上走过去」（玩家报的 bug）正是靠挡住桌子实现的。
	_blocked2 = _make_grid(obstacles, CUSTOMER_INFLATE)


## 按指定外扩量生成障碍网格
func _make_grid(obstacles: Array, inflate: float) -> PackedByteArray:
	var grid := PackedByteArray()
	grid.resize(_cols * _rows)
	grid.fill(0)
	for ob in obstacles:
		var box: Rect2 = ob
		var grown := box.grow(inflate)
		var c0 := clampi(int(floor(grown.position.x / CELL)), 0, _cols - 1)
		var c1 := clampi(int(ceil(grown.end.x / CELL)), 0, _cols - 1)
		var r0 := clampi(int(floor(grown.position.y / CELL)), 0, _rows - 1)
		var r1 := clampi(int(ceil(grown.end.y / CELL)), 0, _rows - 1)
		for r in range(r0, r1 + 1):
			for c in range(c0, c1 + 1):
				grid[r * _cols + c] = 1
	return grid

	# 2) 不用再做「窄缝填充」了。
	#
	# 【为什么删掉了这一步】
	# 之前桌子碰撞盒和椅子碰撞盒之间会留 8px 缝，网格把它当成可通行的格子，
	# 于是路径沿着缝走，服务员撞在椅子边上。当时的补丁是「宽度 < 24px 的缝
	# 直接填成障碍」。
	# 现在 Level 喂进来的是 EntityBase.nav_rect_global()（桌子 + 所有椅子
	# 并成一件家具），缝在数据层面就不存在了；再加上外扩 ≥ 服务员半径，
	# 那些缝早被外扩吃掉。留着只是多余代码，所以清掉。


func is_blocked(c: int, r: int) -> bool:
	return _is_blocked_in(_blocked, c, r)


## 客人网格里这格能不能走
func is_blocked_for_customer(c: int, r: int) -> bool:
	return _is_blocked_in(_blocked2, c, r)


func _is_blocked_in(grid: PackedByteArray, c: int, r: int) -> bool:
	if c < 0 or r < 0 or c >= _cols or r >= _rows:
		return true
	return grid[r * _cols + c] == 1


func cell_of(p: Vector2) -> Vector2i:
	return Vector2i(
		clampi(int(floor(p.x / CELL)), 0, _cols - 1),
		clampi(int(floor(p.y / CELL)), 0, _rows - 1))


func center_of(c: int, r: int) -> Vector2:
	return Vector2((float(c) + 0.5) * CELL, (float(r) + 0.5) * CELL)


## 找一个离 p 最近的可通行格子。起点/终点刚好落在障碍里时要用它兜底。
func nearest_free(p: Vector2, max_ring: int = 6) -> Vector2i:
	return _nearest_free_in(_blocked, p, max_ring)


func _nearest_free_in(grid: PackedByteArray, p: Vector2, max_ring: int = 6) -> Vector2i:
	var start := cell_of(p)
	if not _is_blocked_in(grid, start.x, start.y):
		return start
	for ring in range(1, max_ring + 1):
		for dr in range(-ring, ring + 1):
			for dc in range(-ring, ring + 1):
				# 只看这一圈的边
				if absi(dr) != ring and absi(dc) != ring:
					continue
				var c := start.x + dc
				var r := start.y + dr
				if not _is_blocked_in(grid, c, r):
					return Vector2i(c, r)
	return start


## 求一条从 from 到 to 的路径（世界坐标），返回**拐点列表**。
## 起点和终点会尽量保留原始坐标，中间用格子中心。
## 无路可走时返回空数组。用**服务员**的网格。
func find_path(from: Vector2, to: Vector2) -> Array:
	return _find_path_in(_blocked, from, to)


## 同上，但用**客人**的网格（外扩更小，能走到自己座位）。
## 客人走向座位时用这个 —— 否则座位那格被椅子占成障碍，他走不到。
func find_path_for_customer(from: Vector2, to: Vector2) -> Array:
	return _find_path_in(_blocked2, from, to)


func _find_path_in(grid: PackedByteArray, from: Vector2, to: Vector2) -> Array:
	var out: Array = []
	if _cols == 0 or _rows == 0:
		return out

	var start := _nearest_free_in(grid, from)
	var goal := _nearest_free_in(grid, to)
	# 起终点几乎重合，直接给终点
	if start == goal:
		out.append(to)
		return out

	# A*。用格子下标做键，g/f 分数放字典。
	var open: Array[Vector2i] = [start]
	var came: Dictionary = {}
	var g: Dictionary = {start: 0.0}
	var f: Dictionary = {start: float(_h(start, goal))}
	var closed: Dictionary = {}

	var guard := 0
	var limit := _cols * _rows * 4
	while not open.is_empty() and guard < limit:
		guard += 1
		# 取 f 最小的（格数不多，线性扫足够）
		var best_i := 0
		for i in open.size():
			if float(f.get(open[i], INF)) < float(f.get(open[best_i], INF)):
				best_i = i
		var current: Vector2i = open[best_i]
		open.remove_at(best_i)
		if current == goal:
			return _reconstruct(came, current, from, to)
		closed[current] = true

		for d in _DIRS:
			var nb := current + d
			if _is_blocked_in(grid, nb.x, nb.y) or closed.has(nb):
				continue
			# 斜向要保证两侧都不挡，避免从家具角缝里穿过去
			if d.x != 0 and d.y != 0:
				if _is_blocked_in(grid, current.x + d.x, current.y) or _is_blocked_in(grid, current.x, current.y + d.y):
					continue
			var step := 1.4142 if (d.x != 0 and d.y != 0) else 1.0
			var tentative := float(g.get(current, INF)) + step
			if tentative < float(g.get(nb, INF)):
				came[nb] = current
				g[nb] = tentative
				f[nb] = tentative + float(_h(nb, goal))
				if not open.has(nb):
					open.append(nb)
	return out


## 只走上下左右四个方向，**不走斜线**。
##
## 【为什么不走斜线（已与用户确认这个方向）】
## 斜向移动在拐角处会拼出又长又斜的段，穿过家具之间的窄缝时
## 经常「看着能过、实际过不去」—— 服务员拿着这条线撞上去就停。
## 实测过一条失败路线：路径本身是绕开的，斜向拼出来的长直线
## 被平滑逻辑当成可直达，结果撞在桌子上。
##
## 纯四方向的额外好处（用户提出的）：
##   - 路径全是横向/纵向段，天然不会出现「擦着家具角斜穿」；
##   - 平滑时可以放心用「直线通不通」来判断，判断结果稳定；
##   - 经典像素/像素风游戏就是这么做的，观感也一致。
## 代价是路径里程略长（至多 1.41 倍），在 1280×720 的小场景里无所谓。
const _DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]


func _h(a: Vector2i, b: Vector2i) -> float:
	# 四方向移动用曼哈顿距离（正好等于真实步数，启发式最准，扩张格子最少）
	return float(absi(a.x - b.x) + absi(a.y - b.y))


func _reconstruct(came: Dictionary, current: Vector2i, from: Vector2, to: Vector2) -> Array:
	var cells: Array[Vector2i] = [current]
	while came.has(current):
		current = came[current]
		cells.append(current)
	cells.reverse()

	# 压掉共线的中间点，只留拐点，减少服务员转向次数
	var pts: Array = []
	for i in cells.size():
		if i == 0:
			continue
		if i == cells.size() - 1:
			break
		var prev: Vector2i = cells[i - 1]
		var nxt: Vector2i = cells[i + 1]
		var d1 := cells[i] - prev
		var d2 := nxt - cells[i]
		var straight := (signi(d1.x) == signi(d2.x)) and (signi(d1.y) == signi(d2.y))
		if not straight:
			pts.append(center_of(cells[i].x, cells[i].y))

	# 首尾用真实坐标：先走到第一个拐点，最后走到真正的目标
	pts.append(to)
	return pts


## 调试用：把网格画成文字，看看障碍标得对不对
func dump_ascii() -> String:
	var lines: PackedStringArray = []
	for r in _rows:
		var row := ""
		for c in _cols:
			row += "#" if is_blocked(c, r) else "."
		lines.append(row)
	return "\n".join(lines)


## 调试用：只打印某个矩形区域内的网格（家具附近的墙有没有标错，看这个最快）
func dump_region(from: Vector2, to: Vector2) -> String:
	var c0 := clampi(int(floor(from.x / CELL)), 0, _cols - 1)
	var c1 := clampi(int(ceil(to.x / CELL)), 0, _cols - 1)
	var r0 := clampi(int(floor(from.y / CELL)), 0, _rows - 1)
	var r1 := clampi(int(ceil(to.y / CELL)), 0, _rows - 1)
	var lines: PackedStringArray = []
	lines.append("x %d..%d, y %d..%d（# = 不可通行）" % [c0, c1, r0, r1])
	for r in range(r0, r1 + 1):
		var row := "%3d " % r
		for c in range(c0, c1 + 1):
			row += "#" if is_blocked(c, r) else "."
		lines.append(row)
	return "\n".join(lines)
